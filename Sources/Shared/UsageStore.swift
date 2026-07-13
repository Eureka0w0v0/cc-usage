import Foundation
import SQLite3

// cc-switch 用量数据层：只读 ~/.cc-switch/cc-switch.db，聚合出「区间摘要 / 走势 / 累计」。
// 口径逐字对齐 cc-switch 的 usage_stats.rs（get_usage_summary / get_usage_summary_by_app /
// get_daily_trends）——「近期明细」proxy_request_logs 与「历史日聚合」usage_daily_rollups
// 两表合并：
//   Tokens Processed = fresh_input + output + cache_creation + cache_read
//   fresh_input      = codex/gemini 的 input 含 cache_read → 减去；其余原样（sql_helpers.rs）
//   Cache Hit Rate   = cache_read / (fresh_input + cache_creation + cache_read)
//   summary(区间)    = logs 部分(created_at∈区间) + rollups 部分(r.date∈边界对齐后的整日区间)
//   trend ≤24h       = 小时桶，仅 proxy_request_logs（近期都在明细表）
//   trend >24h       = 天桶，本地日；proxy_request_logs(明细) 按 localtime 日 + usage_daily_rollups(历史) 合并，空桶补 0
//   防重叠           = rollups 只取「完全落在区间内的整本地日」(compute_rollup_date_bounds)，
//                      边界不足整日的那天交给 logs（按精确 created_at）——同一天不双算。
//   跨源去重         = effective_usage_log_filter：session 行若已有匹配 proxy 行则剔除。
//                      本机无 'proxy' 行，此过滤恒为 no-op（已验证），但忠实照搬。

// MARK: - 数据模型

public struct UsageSummary: Sendable {
    public var requests: Int = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var creation: Int64 = 0
    public var hit: Int64 = 0
    public var cost: Double = 0

    public var tokensProcessed: Int64 { input + output + creation + hit }
    public var cacheHitRate: Double {
        let denom = Double(input + creation + hit)
        return denom > 0 ? Double(hit) / denom : 0
    }
}

public struct TrendBucket: Sendable {
    public var startTs: Int64
    public var requestCount: Int = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var creation: Int64 = 0
    public var hit: Int64 = 0
    public var cost: Double = 0
    public var tokens: Int64 { input + output + creation + hit }
}

public struct UsageSnapshot: Sendable {
    public var today: UsageSummary
    public var cumulative: UsageSummary
    public var trend: [TrendBucket]
    public var generatedAt: Date
    public var lastEventAt: Date?
}

public enum UsageStoreError: Error, CustomStringConvertible {
    case open(Int32)
    case prepare(String)
    public var description: String {
        switch self {
        case .open(let rc): return "cannot open database (sqlite rc=\(rc))"
        case .prepare(let sql): return "failed to prepare SQL: \(sql)"
        }
    }
}

// MARK: - 数据仓库

/// 查询过滤条件：时间窗 + 来源(app) + 模型。
public struct UsageFilter: Sendable {
    public var start: Int64?
    public var end: Int64?
    public var appType: String?   // nil = 全部；已折叠值，如 "claude"
    public var model: String?     // nil = 全部
    public init(start: Int64? = nil, end: Int64? = nil, appType: String? = nil, model: String? = nil) {
        self.start = start; self.end = end; self.appType = appType; self.model = model
    }
}

// MARK: - Tabs 数据模型（对齐 cc-switch types/usage.ts，字段名 = camelCase 的 snake→camel 源）

/// 请求日志 / Provider 统计 / 模型统计 三个 Tab 共用的查询过滤条件。
/// 口径对齐 usage_stats.rs：appType 折叠 claude-desktop→claude，providerName 按展示名
/// 精确匹配（含 "Claude (Session)" 等会话占位名），model 按「有效计价模型」匹配。
public struct LogQueryFilter: Sendable {
    public var start: Int64?
    public var end: Int64?
    public var appType: String?
    public var providerName: String?
    public var model: String?
    public var statusCode: Int?     // 仅 requestLogs 用
    public init(start: Int64? = nil, end: Int64? = nil, appType: String? = nil,
                providerName: String? = nil, model: String? = nil, statusCode: Int? = nil) {
        self.start = start; self.end = end; self.appType = appType
        self.providerName = providerName; self.model = model; self.statusCode = statusCode
    }
}

/// 对齐 RequestLogDetail（usage_stats.rs）→ RequestLog（types/usage.ts）。
public struct RequestLogRow: Sendable {
    public var requestId: String
    public var providerId: String
    public var providerName: String
    public var appType: String
    public var model: String
    public var requestModel: String?
    public var pricingModel: String?
    public var costMultiplier: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreationTokens: Int64
    public var inputCostUsd: String
    public var outputCostUsd: String
    public var cacheReadCostUsd: String
    public var cacheCreationCostUsd: String
    public var totalCostUsd: String
    public var isStreaming: Bool
    public var latencyMs: Int64
    public var firstTokenMs: Int64?
    public var durationMs: Int64?
    public var statusCode: Int
    public var errorMessage: String?
    public var createdAt: Int64
    public var dataSource: String?
}

public struct RequestLogPage: Sendable {
    public var rows: [RequestLogRow]
    public var total: Int
}

/// 对齐 ProviderStats（types/usage.ts）。
public struct ProviderStatRow: Sendable {
    public var providerId: String
    public var providerName: String
    public var requestCount: Int64
    public var totalTokens: Int64
    public var totalCost: Double
    public var successRate: Double
    public var avgLatencyMs: Int64
}

/// 对齐 ModelStats（types/usage.ts）。
public struct ModelStatRow: Sendable {
    public var model: String
    public var requestCount: Int64
    public var totalTokens: Int64
    public var totalCost: Double
    public var avgCostPerRequest: Double
}

// SQLite 绑定文本时用（拷贝字符串，安全）
let SQLITE_TRANSIENT_DEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 线程安全：自身状态只有两个不可变引用（path / overlay），每次查询独立开只读连接，
/// SessionOverlay 内部有锁——可安全从任意线程调用（后台 reload / 桥接队列都依赖这点）。
public final class UsageStore: @unchecked Sendable {
    public static let defaultPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".cc-switch/cc-switch.db")

    private let path: String
    private let overlay: SessionOverlay
    /// overlay 可注入：测试用独立实例（空 projectsDir）隔离真实会话日志，生产默认共享单例。
    public init(path: String = UsageStore.defaultPath, overlay: SessionOverlay = .shared) {
        self.path = path
        self.overlay = overlay
    }

    // 只读打开（mode=ro，尊重 WAL，绝不写库）
    private func openRO() throws -> OpaquePointer {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            throw UsageStoreError.open(rc)
        }
        sqlite3_busy_timeout(handle, 2000)
        return handle
    }

    // MARK: - 未入库增量叠加（SessionOverlay）
    //
    // cc-switch 不在运行时,新用量只存在于会话 JSONL 里(session_log_sync 行偏移
    // 之后)。SessionOverlay 只读解析这批行,这里把它们合并进各查询结果,让
    // 菜单栏/面板在 cc-switch 关闭时照样实时。cc-switch 入库后 overlay 自动清空,
    // 数字无缝交接(request_id 精确去重),不双算。

    /// 取符合过滤条件的未入库增量行。app 恒为 claude;overlay 行 pricing_model
    /// 为空 → 有效计价模型回落 model,与库内 session 行口径一致。
    private func overlayRows(_ db: OpaquePointer, start: Int64?, end: Int64?,
                             appType: String?, model: String?) -> [OverlayRow] {
        if let at = appType, at != "claude" { return [] }
        var rows = overlay.pendingRows(db: db)
        if let s = start { rows = rows.filter { $0.createdAt >= s } }
        if let e = end { rows = rows.filter { $0.createdAt <= e } }
        if let m = model { rows = rows.filter { $0.model == m } }
        return rows
    }

    /// LogQueryFilter 版(Tabs 用):多两个维度——provider 名与状态码。
    /// overlay 行的 provider 展示名恒为 "Claude (Session)",状态码恒 200。
    private func overlayLogRows(_ db: OpaquePointer, _ f: LogQueryFilter) -> [OverlayRow] {
        if let pn = f.providerName, pn != "Claude (Session)" { return [] }
        if let sc = f.statusCode, sc != 200 { return [] }
        return overlayRows(db, start: f.start, end: f.end, appType: f.appType, model: f.model)
    }

    /// 把增量行累加进汇总(claude 的 fresh_input = input,无 cache 扣减)。
    private func addOverlay(_ s: inout UsageSummary, _ rows: [OverlayRow]) {
        guard !rows.isEmpty else { return }
        s.requests += rows.count
        for r in rows {
            s.input += r.input
            s.output += r.output
            s.creation += r.cacheCreation
            s.hit += r.cacheRead
            s.cost += r.totalCost
        }
    }

    // MARK: - rollup 日期边界（对齐 usage_stats.rs::compute_rollup_date_bounds）
    //
    // rollups 只纳入「完全落在区间内的整本地日」：区间起点非本地零点 → 从次日起；
    // 区间终点非本地 23:59 → 到前一日止。边界不足整日的那天由 logs(精确 created_at)覆盖，
    // 避免与 rollups 双算。isEmpty=true 时（start>end）用 "1=0" 让 rollups 部分为空。
    struct RollupBounds { var start: String?; var end: String?; var isEmpty: Bool }

    // internal（而非 private）：整日边界对齐是防双算的关键逻辑，单测直接驱动。
    func rollupDateBounds(_ startTs: Int64?, _ endTs: Int64?, _ cal: Calendar) -> RollupBounds {
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        var startStr: String? = nil
        if let s = startTs {
            let d = Date(timeIntervalSince1970: TimeInterval(s))
            let c = cal.dateComponents([.hour, .minute, .second], from: d)
            let day0 = cal.startOfDay(for: d)
            if (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 {
                startStr = fmt.string(from: day0)
            } else if let next = cal.date(byAdding: .day, value: 1, to: day0) {
                startStr = fmt.string(from: next)
            }
        }
        var endStr: String? = nil
        if let e = endTs {
            let d = Date(timeIntervalSince1970: TimeInterval(e))
            let c = cal.dateComponents([.hour, .minute], from: d)
            let day0 = cal.startOfDay(for: d)
            if (c.hour ?? 0) == 23 && (c.minute ?? 0) == 59 {
                endStr = fmt.string(from: day0)
            } else if let prev = cal.date(byAdding: .day, value: -1, to: day0) {
                endStr = fmt.string(from: prev)
            }
        }
        var empty = false
        if let a = startStr, let b = endStr, a > b { empty = true }
        return RollupBounds(start: startStr, end: endStr, isEmpty: empty)
    }

    // MARK: - 区间汇总（两表合并）
    //
    // cc-switch get_usage_summary 是把 (logs 子查询 d) × (rollups 子查询 r) 交叉连接后逐列 d+r。
    // 这里等价地分别求 logs-only 与 rollups-only 再相加（数学完全一致），顺带让
    // get_usage_data_sources 复用 logs-only（rollups 无 data_source，不该算进「来源」）。

    /// logs 部分：仅 proxy_request_logs（fresh_input + 跨源去重过滤）。
    private func summaryLogsOnly(_ db: OpaquePointer, _ f: UsageFilter) throws -> UsageSummary {
        var conds: [String] = [Self.effectiveUsageFilterL]
        var binds: [Bind] = []
        if let s = f.start { conds.append("l.created_at >= ?"); binds.append(.int(s)) }
        if let e = f.end { conds.append("l.created_at <= ?"); binds.append(.int(e)) }
        if let at = f.appType { conds.append("\(Self.foldedAppL) = ?"); binds.append(.text(at)) }
        if let m = f.model { conds.append("\(Self.effectiveModelL) = ?"); binds.append(.text(m)) }
        let sql = """
        SELECT COUNT(*),
               COALESCE(SUM(CAST(l.total_cost_usd AS REAL)),0),
               COALESCE(SUM(\(Self.freshInputL)),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0)
        FROM proxy_request_logs l
        WHERE \(conds.joined(separator: " AND "))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)

        var s = UsageSummary()
        if sqlite3_step(stmt) == SQLITE_ROW {
            s.requests = Int(sqlite3_column_int64(stmt, 0))
            s.cost     = sqlite3_column_double(stmt, 1)
            s.input    = sqlite3_column_int64(stmt, 2)
            s.output   = sqlite3_column_int64(stmt, 3)
            s.creation = sqlite3_column_int64(stmt, 4)
            s.hit      = sqlite3_column_int64(stmt, 5)
        }
        // 未入库增量:所有汇总路径(Hero/菜单栏/累计/数据源)都经此函数,一处叠加全局生效
        addOverlay(&s, overlayRows(db, start: f.start, end: f.end, appType: f.appType, model: f.model))
        return s
    }

    /// rollups 部分：仅 usage_daily_rollups（fresh_input + 整日边界对齐）。
    private func summaryRollupsOnly(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> UsageSummary {
        let b = rollupDateBounds(f.start, f.end, cal)
        var conds: [String] = []
        var binds: [Bind] = []
        if b.isEmpty {
            conds.append("1 = 0")
        } else {
            if let s = b.start { conds.append("r.date >= ?"); binds.append(.text(s)) }
            if let e = b.end { conds.append("r.date <= ?"); binds.append(.text(e)) }
        }
        if let at = f.appType { conds.append("\(Self.foldedAppR) = ?"); binds.append(.text(at)) }
        if let m = f.model { conds.append("\(Self.effectiveModelR) = ?"); binds.append(.text(m)) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        let sql = """
        SELECT COALESCE(SUM(r.request_count),0),
               COALESCE(SUM(CAST(r.total_cost_usd AS REAL)),0),
               COALESCE(SUM(\(Self.freshInputR)),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0)
        FROM usage_daily_rollups r
        \(whereClause)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)

        var s = UsageSummary()
        if sqlite3_step(stmt) == SQLITE_ROW {
            s.requests = Int(sqlite3_column_int64(stmt, 0))
            s.cost     = sqlite3_column_double(stmt, 1)
            s.input    = sqlite3_column_int64(stmt, 2)
            s.output   = sqlite3_column_int64(stmt, 3)
            s.creation = sqlite3_column_int64(stmt, 4)
            s.hit      = sqlite3_column_int64(stmt, 5)
        }
        return s
    }

    /// 两表合并汇总 = logs-only + rollups-only（逐列相加，等价 cc-switch 的 d+r）。
    private func summary(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> UsageSummary {
        let a = try summaryLogsOnly(db, f)
        let r = try summaryRollupsOnly(db, f, cal)
        var s = UsageSummary()
        s.requests = a.requests + r.requests
        s.input    = a.input + r.input
        s.output   = a.output + r.output
        s.creation = a.creation + r.creation
        s.hit      = a.hit + r.hit
        s.cost     = a.cost + r.cost
        return s
    }

    /// 按 app_type 拆分的区间汇总（Hero 用）。对齐 get_usage_summary_by_app：
    /// logs GROUP BY app + rollups GROUP BY app 做 UNION ALL 后外层再 GROUP BY，
    /// 折叠 claude-desktop→claude。空 app 丢弃，按 tokensProcessed 降序（= real_total_tokens）。
    public func summaryByApp(_ filter: UsageFilter) throws -> [(appType: String, summary: UsageSummary)] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let cal = Calendar.current

        // detail(logs) 条件：跨源去重 + 时间窗 + 模型（不按 app 过滤，按 app 分组）
        var dConds: [String] = [Self.effectiveUsageFilterL]
        var binds: [Bind] = []
        if let s = filter.start { dConds.append("l.created_at >= ?"); binds.append(.int(s)) }
        if let e = filter.end { dConds.append("l.created_at <= ?"); binds.append(.int(e)) }
        if let m = filter.model { dConds.append("\(Self.effectiveModelL) = ?"); binds.append(.text(m)) }

        // rollup 条件：整日边界 + 模型
        let rb = rollupDateBounds(filter.start, filter.end, cal)
        var rConds: [String] = []
        if rb.isEmpty {
            rConds.append("1 = 0")
        } else {
            if let s = rb.start { rConds.append("r.date >= ?"); binds.append(.text(s)) }
            if let e = rb.end { rConds.append("r.date <= ?"); binds.append(.text(e)) }
        }
        if let m = filter.model { rConds.append("\(Self.effectiveModelR) = ?"); binds.append(.text(m)) }

        let rWhere = rConds.isEmpty ? "" : "WHERE " + rConds.joined(separator: " AND ")
        let sql = """
        SELECT app_type,
               SUM(req), SUM(cost), SUM(inp), SUM(outp), SUM(cc), SUM(cr)
        FROM (
            SELECT \(Self.foldedAppL) AS app_type,
                   COUNT(*) AS req,
                   COALESCE(SUM(CAST(l.total_cost_usd AS REAL)),0) AS cost,
                   COALESCE(SUM(\(Self.freshInputL)),0) AS inp,
                   COALESCE(SUM(l.output_tokens),0) AS outp,
                   COALESCE(SUM(l.cache_creation_tokens),0) AS cc,
                   COALESCE(SUM(l.cache_read_tokens),0) AS cr
            FROM proxy_request_logs l
            WHERE \(dConds.joined(separator: " AND "))
            GROUP BY l.app_type
            UNION ALL
            SELECT \(Self.foldedAppR) AS app_type,
                   COALESCE(SUM(r.request_count),0),
                   COALESCE(SUM(CAST(r.total_cost_usd AS REAL)),0),
                   COALESCE(SUM(\(Self.freshInputR)),0),
                   COALESCE(SUM(r.output_tokens),0),
                   COALESCE(SUM(r.cache_creation_tokens),0),
                   COALESCE(SUM(r.cache_read_tokens),0)
            FROM usage_daily_rollups r
            \(rWhere)
            GROUP BY r.app_type
        )
        GROUP BY app_type
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)

        var out: [(appType: String, summary: UsageSummary)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = colText(stmt, 0)
            var s = UsageSummary()
            s.requests = Int(sqlite3_column_int64(stmt, 1))
            s.cost     = sqlite3_column_double(stmt, 2)
            s.input    = sqlite3_column_int64(stmt, 3)
            s.output   = sqlite3_column_int64(stmt, 4)
            s.creation = sqlite3_column_int64(stmt, 5)
            s.hit      = sqlite3_column_int64(stmt, 6)
            if s.requests == 0 && s.tokensProcessed == 0 { continue }
            out.append((appType: app, summary: s))
        }
        // 未入库增量并入 claude 桶(不存在则新建)
        let ov = overlayRows(db, start: filter.start, end: filter.end, appType: nil, model: filter.model)
        if !ov.isEmpty {
            if let i = out.firstIndex(where: { $0.appType == "claude" }) {
                addOverlay(&out[i].summary, ov)
            } else {
                var s = UsageSummary()
                addOverlay(&s, ov)
                out.append((appType: "claude", summary: s))
            }
        }
        out.sort { $0.summary.tokensProcessed > $1.summary.tokensProcessed }
        return out
    }

    // MARK: - 走势

    /// 小时桶走势（≤24h）：仅 proxy_request_logs（近期都在明细表），空桶补 0。
    /// 对齐 get_daily_trends 的 duration<=24h 分支（fresh_input + 跨源去重过滤）。
    private func trendHourly(_ db: OpaquePointer, _ f: UsageFilter) throws -> [TrendBucket] {
        let start = f.start ?? 0, end = f.end ?? 0
        let bucketSeconds: Int64 = 3600
        var sql = """
        SELECT CAST((l.created_at - ?1) / ?3 AS INTEGER) AS bucket,
               COALESCE(SUM(\(Self.freshInputL)),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(CAST(l.total_cost_usd AS REAL)),0),
               COUNT(*)
        FROM proxy_request_logs l
        WHERE l.created_at >= ?1 AND l.created_at <= ?2 AND \(Self.effectiveUsageFilterL)
        """
        if f.appType != nil { sql += " AND \(Self.foldedAppL) = ?4" }
        if f.model != nil { sql += " AND \(Self.effectiveModelL) = ?5" }
        sql += " GROUP BY bucket ORDER BY bucket"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)
        sqlite3_bind_int64(stmt, 3, bucketSeconds)
        if let a = f.appType { sqlite3_bind_text(stmt, 4, a, -1, SQLITE_TRANSIENT_DEST) }
        if let m = f.model { sqlite3_bind_text(stmt, 5, m, -1, SQLITE_TRANSIENT_DEST) }

        let count = max(1, Int((end - start + bucketSeconds - 1) / bucketSeconds))
        var buckets = (0..<count).map { i in
            TrendBucket(startTs: start + Int64(i) * bucketSeconds)
        }
        // 累加而非赋值：GROUP BY 保证桶号唯一，但 created_at 恰等于 end 且区间为整桶宽时
        // 会产生一个越界桶号、被钳到末桶——若用赋值，末小时的真实聚合会被这条边界行覆盖。
        while sqlite3_step(stmt) == SQLITE_ROW {
            var idx = Int(sqlite3_column_int64(stmt, 0))
            if idx < 0 { continue }
            if idx >= count { idx = count - 1 }
            buckets[idx].input    += sqlite3_column_int64(stmt, 1)
            buckets[idx].output   += sqlite3_column_int64(stmt, 2)
            buckets[idx].creation += sqlite3_column_int64(stmt, 3)
            buckets[idx].hit      += sqlite3_column_int64(stmt, 4)
            buckets[idx].cost     += sqlite3_column_double(stmt, 5)
            buckets[idx].requestCount += Int(sqlite3_column_int64(stmt, 6))
        }
        // 未入库增量落进对应小时桶(越界钳到末桶,与 DB 行同规则)
        for r in overlayRows(db, start: start, end: end, appType: f.appType, model: f.model) {
            var idx = Int((r.createdAt - start) / bucketSeconds)
            if idx < 0 { continue }
            if idx >= count { idx = count - 1 }
            buckets[idx].input    += r.input
            buckets[idx].output   += r.output
            buckets[idx].creation += r.cacheCreation
            buckets[idx].hit      += r.cacheRead
            buckets[idx].cost     += r.totalCost
            buckets[idx].requestCount += 1
        }
        return buckets
    }

    /// 天桶走势（>24h）：proxy_request_logs 按 localtime 本地日 + usage_daily_rollups 合并，
    /// 空桶补 0，桶时间戳 = 本地零点。对齐 get_daily_trends 的 duration>24h 分支。
    private func trendDaily(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> [TrendBucket] {
        let startTs = f.start ?? 0, endTs = f.end ?? 0

        struct Acc { var req = 0; var input: Int64 = 0; var output: Int64 = 0
                     var creation: Int64 = 0; var hit: Int64 = 0; var cost = 0.0 }
        var map: [String: Acc] = [:]

        // --- logs：按 localtime 本地日分组（set）---
        var lConds: [String] = ["l.created_at >= ?", "l.created_at <= ?", Self.effectiveUsageFilterL]
        var lBinds: [Bind] = [.int(startTs), .int(endTs)]
        if let at = f.appType { lConds.append("\(Self.foldedAppL) = ?"); lBinds.append(.text(at)) }
        if let m = f.model { lConds.append("\(Self.effectiveModelL) = ?"); lBinds.append(.text(m)) }
        let lSQL = """
        SELECT date(l.created_at,'unixepoch','localtime') AS d,
               COUNT(*),
               COALESCE(SUM(\(Self.freshInputL)),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(CAST(l.total_cost_usd AS REAL)),0)
        FROM proxy_request_logs l
        WHERE \(lConds.joined(separator: " AND "))
        GROUP BY d
        """
        var lStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, lSQL, -1, &lStmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(lSQL)
        }
        bindAll(lStmt, lBinds)
        while sqlite3_step(lStmt) == SQLITE_ROW {
            let d = colText(lStmt, 0)
            map[d] = Acc(req: Int(sqlite3_column_int64(lStmt, 1)),
                        input: sqlite3_column_int64(lStmt, 2),
                        output: sqlite3_column_int64(lStmt, 3),
                        creation: sqlite3_column_int64(lStmt, 4),
                        hit: sqlite3_column_int64(lStmt, 5),
                        cost: sqlite3_column_double(lStmt, 6))
        }
        sqlite3_finalize(lStmt)

        // --- rollups：按 r.date 分组，叠加到对应日（add，同一天不双算见边界对齐）---
        let rb = rollupDateBounds(startTs, endTs, cal)
        var rConds: [String] = []
        var rBinds: [Bind] = []
        if rb.isEmpty {
            rConds.append("1 = 0")
        } else {
            if let s = rb.start { rConds.append("r.date >= ?"); rBinds.append(.text(s)) }
            if let e = rb.end { rConds.append("r.date <= ?"); rBinds.append(.text(e)) }
        }
        if let at = f.appType { rConds.append("\(Self.foldedAppR) = ?"); rBinds.append(.text(at)) }
        if let m = f.model { rConds.append("\(Self.effectiveModelR) = ?"); rBinds.append(.text(m)) }
        let rWhere = rConds.isEmpty ? "" : "WHERE " + rConds.joined(separator: " AND ")
        let rSQL = """
        SELECT r.date,
               COALESCE(SUM(r.request_count),0),
               COALESCE(SUM(\(Self.freshInputR)),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0),
               COALESCE(SUM(CAST(r.total_cost_usd AS REAL)),0)
        FROM usage_daily_rollups r
        \(rWhere)
        GROUP BY r.date
        """
        var rStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, rSQL, -1, &rStmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(rSQL)
        }
        bindAll(rStmt, rBinds)
        while sqlite3_step(rStmt) == SQLITE_ROW {
            let d = colText(rStmt, 0)
            var a = map[d] ?? Acc()
            a.req      += Int(sqlite3_column_int64(rStmt, 1))
            a.input    += sqlite3_column_int64(rStmt, 2)
            a.output   += sqlite3_column_int64(rStmt, 3)
            a.creation += sqlite3_column_int64(rStmt, 4)
            a.hit      += sqlite3_column_int64(rStmt, 5)
            a.cost     += sqlite3_column_double(rStmt, 6)
            map[d] = a
        }
        sqlite3_finalize(rStmt)

        // --- 按本地日从 start_day 到 end_day 逐日铺开，空桶补 0 ---
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        // 未入库增量按本地日并入(与 logs 的 date(...,'localtime') 分组同口径)
        for r in overlayRows(db, start: startTs, end: endTs, appType: f.appType, model: f.model) {
            let d = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(r.createdAt)))
            var a = map[d] ?? Acc()
            a.req += 1
            a.input += r.input
            a.output += r.output
            a.creation += r.cacheCreation
            a.hit += r.cacheRead
            a.cost += r.totalCost
            map[d] = a
        }

        let startDay = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(startTs)))
        let endDay = cal.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(endTs)))
        let dayCount = max(1, (cal.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1)

        var buckets: [TrendBucket] = []
        buckets.reserveCapacity(dayCount)
        var day = startDay
        for _ in 0..<dayCount {
            let ds = fmt.string(from: day)
            var b = TrendBucket(startTs: Int64(day.timeIntervalSince1970))
            if let a = map[ds] {
                b.requestCount = a.req
                b.input = a.input
                b.output = a.output
                b.creation = a.creation
                b.hit = a.hit
                b.cost = a.cost
            }
            buckets.append(b)
            day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        }
        return buckets
    }

    private func lastEventTs(_ db: OpaquePointer) -> Int64? {
        var dbTs: Int64? = nil
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(created_at) FROM proxy_request_logs", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                dbTs = sqlite3_column_int64(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        // 「最后活动」把未入库增量也算上(cc-switch 关闭时菜单栏的 "刚刚" 才是真的)
        let ovTs = overlayRows(db, start: nil, end: nil, appType: nil, model: nil)
            .map(\.createdAt).max()
        switch (dbTs, ovTs) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil):    return a
        case (nil, let b?):    return b
        default:               return nil
        }
    }

    /// 缺省时间窗填充：start 缺省 = 本地今日零点，end 缺省 = now（snapshot / trendBuckets 共用）。
    private func resolvedFilter(_ filter: UsageFilter, now: Date, _ cal: Calendar) -> UsageFilter {
        var f = filter
        f.start = filter.start ?? Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        f.end = filter.end ?? Int64(now.timeIntervalSince1970)
        return f
    }

    /// 粒度选择：区间 ≤24h 走小时桶，否则天桶
    /// （阈值与前端 UsageTrendChart 的 isHourly = duration<=24h 严格一致，避免粒度错位）。
    private func trend(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> [TrendBucket] {
        let dur = (f.end ?? 0) - (f.start ?? 0)
        return dur <= 24 * 3600 ? try trendHourly(db, f) : try trendDaily(db, f, cal)
    }

    /// 按过滤条件生成快照（区间汇总 + 累计 + 走势）。
    public func snapshot(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let db = try openRO()
        defer { sqlite3_close(db) }

        let f = resolvedFilter(filter, now: now, calendar)
        let range = try summary(db, f, calendar)
        let cumulative = try summary(db, UsageFilter(appType: filter.appType, model: filter.model), calendar)
        let tr = try trend(db, f, calendar)
        let lastTs = lastEventTs(db)

        return UsageSnapshot(
            today: range,
            cumulative: cumulative,
            trend: tr,
            generatedAt: now,
            lastEventAt: lastTs.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// 只算走势（get_usage_trends 桥接用）：面板每个刷新 tick 都会调，snapshot 里顺带的
    /// 「区间 + 累计」共 4 次聚合在那条路径全是白算——这里跳过。缺省窗口/粒度与 snapshot 一致。
    public func trendBuckets(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current) throws -> [TrendBucket] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try trend(db, resolvedFilter(filter, now: now, calendar), calendar)
    }

    /// 便捷：默认「今日」快照（widget 用）。
    public func snapshot(now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let dayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        return try snapshot(filter: UsageFilter(start: dayStart, end: Int64(now.timeIntervalSince1970)),
                            now: now, calendar: calendar)
    }

    /// 只算某个时间窗的汇总（不含 trend），用于「近5小时 / 本周」这类常驻指标。两表合并。
    public func rangeSummary(_ filter: UsageFilter, calendar: Calendar = .current) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summary(db, filter, calendar)
    }

    /// 仅 logs 部分的区间汇总（不含 rollups）。用于 get_usage_data_sources——
    /// rollups 无 data_source 列，不该被算进「按来源」的 session_log 计数。
    public func rangeSummaryLogsOnly(_ filter: UsageFilter) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summaryLogsOnly(db, filter)
    }

    // MARK: - Tabs 查询（Request Logs / Provider Stats / Model Stats）
    //
    // 全部只读 proxy_request_logs（与 Hero/Chart 同源，忽略 usage_daily_rollups——
    // 本机 rollup 里的历史 codex 数据不在明细表，Request Logs 无法逐行展示，故三个 Tab
    // 统一以明细表为准，保证与用户已看到的 Hero 数字自洽）。SQL 片段逐一复刻
    // usage_stats.rs（alias 固定 l = proxy_request_logs，p = providers）。
    // 本机无 'proxy' 行，故跨源去重过滤（effective_usage_log_filter）为空操作，略去。

    /// 折叠 claude-desktop→claude（仅过滤/分组口径，行投影仍返回原始 app_type）。
    static let foldedAppL = "CASE WHEN l.app_type='claude-desktop' THEN 'claude' ELSE l.app_type END"
    /// 有效计价模型：pricing_model 非空优先，NULL/'' 回落 model。
    static let effectiveModelL = "COALESCE(NULLIF(l.pricing_model, ''), l.model)"
    /// cache 归一化 input：codex/gemini 的 input 含 cache_read，需减去；其余原样。
    static let freshInputL = "CASE WHEN l.app_type IN ('codex','gemini') AND l.input_tokens >= l.cache_read_tokens THEN (l.input_tokens - l.cache_read_tokens) ELSE l.input_tokens END"
    /// provider 展示名：providers.name 优先，会话占位 provider_id 映射为可读名。
    static let providerNameCoalesce = "COALESCE(p.name, CASE l.provider_id WHEN '_session' THEN 'Claude (Session)' WHEN '_codex_session' THEN 'Codex (Session)' WHEN '_gemini_session' THEN 'Gemini (Session)' WHEN '_opencode_session' THEN 'OpenCode (Session)' ELSE l.provider_id END)"
    static let providersJoinL = "LEFT JOIN providers p ON l.provider_id = p.id AND l.app_type = p.app_type"

    // ── usage_daily_rollups(别名 r) 侧的对应片段，供两表合并的 summary/trend/by-app 使用 ──
    /// 折叠 claude-desktop→claude（rollups 侧）。
    static let foldedAppR = "CASE WHEN r.app_type='claude-desktop' THEN 'claude' ELSE r.app_type END"
    /// 有效计价模型（rollups 侧）。
    static let effectiveModelR = "COALESCE(NULLIF(r.pricing_model, ''), r.model)"
    /// cache 归一化 input（rollups 侧）。
    static let freshInputR = "CASE WHEN r.app_type IN ('codex','gemini') AND r.input_tokens >= r.cache_read_tokens THEN (r.input_tokens - r.cache_read_tokens) ELSE r.input_tokens END"
    /// 跨源去重过滤（对齐 usage_stats.rs::effective_usage_log_filter，别名 l）：
    /// session 系日志若在 ±10min 窗口内存在指纹匹配的成功 proxy 行，则剔除该 session 行，
    /// 防止「同一次请求既落 session 又落 proxy」被双算。600 = 10min 窗口秒数。
    /// 本机无 'proxy' 行 → EXISTS 恒 false → NOT(...) 恒 true → 全过（已验证），但忠实照搬。
    static let effectiveUsageFilterL = "NOT (COALESCE(l.data_source,'proxy') IN ('session_log','codex_session','gemini_session','opencode_session') AND EXISTS (SELECT 1 FROM proxy_request_logs proxy_dedup WHERE COALESCE(proxy_dedup.data_source,'proxy')='proxy' AND proxy_dedup.app_type=l.app_type AND proxy_dedup.status_code>=200 AND proxy_dedup.status_code<300 AND proxy_dedup.input_tokens=l.input_tokens AND proxy_dedup.output_tokens=l.output_tokens AND proxy_dedup.cache_read_tokens=l.cache_read_tokens AND (proxy_dedup.cache_creation_tokens=l.cache_creation_tokens OR (l.cache_creation_tokens=0 AND COALESCE(l.data_source,'proxy') IN ('codex_session','gemini_session','opencode_session'))) AND proxy_dedup.created_at BETWEEN l.created_at-600 AND l.created_at+600 AND (LOWER(proxy_dedup.model)=LOWER(l.model) OR LOWER(proxy_dedup.model)='unknown' OR LOWER(l.model)='unknown')))"

    private enum Bind { case int(Int64); case text(String) }

    private func bindAll(_ stmt: OpaquePointer?, _ binds: [Bind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DEST)
            }
        }
    }

    private func colText(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
        return ""
    }
    private func colTextOpt(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
        return nil
    }
    private func colIntOpt(_ stmt: OpaquePointer?, _ i: Int32) -> Int64? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, i)
    }

    // provider / model 统计共用的 WHERE + 绑定参数（时间窗 + app + provider + model）。
    private func statsWhere(_ f: LogQueryFilter) -> (String, [Bind]) {
        var conds: [String] = []
        var binds: [Bind] = []
        if let s = f.start { conds.append("l.created_at >= ?"); binds.append(.int(s)) }
        if let e = f.end { conds.append("l.created_at <= ?"); binds.append(.int(e)) }
        if let at = f.appType { conds.append("\(Self.foldedAppL) = ?"); binds.append(.text(at)) }
        if let pn = f.providerName { conds.append("\(Self.providerNameCoalesce) = ?"); binds.append(.text(pn)) }
        if let m = f.model { conds.append("\(Self.effectiveModelL) = ?"); binds.append(.text(m)) }
        let w = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        return (w, binds)
    }

    /// 请求日志分页（created_at DESC）。对齐 get_request_logs（usage_stats.rs）。
    public func requestLogs(_ f: LogQueryFilter, page: Int, pageSize: Int) throws -> RequestLogPage {
        let db = try openRO()
        defer { sqlite3_close(db) }

        var conds: [String] = []
        var binds: [Bind] = []
        if let at = f.appType { conds.append("\(Self.foldedAppL) = ?"); binds.append(.text(at)) }
        if let pn = f.providerName { conds.append("\(Self.providerNameCoalesce) = ?"); binds.append(.text(pn)) }
        if let m = f.model { conds.append("\(Self.effectiveModelL) = ?"); binds.append(.text(m)) }
        if let sc = f.statusCode { conds.append("l.status_code = ?"); binds.append(.int(Int64(sc))) }
        if let s = f.start { conds.append("l.created_at >= ?"); binds.append(.int(s)) }
        if let e = f.end { conds.append("l.created_at <= ?"); binds.append(.int(e)) }
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")

        // 总数
        let countSQL = "SELECT COUNT(*) FROM proxy_request_logs l \(Self.providersJoinL) \(whereClause)"
        var total = 0
        var cstmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, countSQL, -1, &cstmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(countSQL)
        }
        bindAll(cstmt, binds)
        if sqlite3_step(cstmt) == SQLITE_ROW { total = Int(sqlite3_column_int64(cstmt, 0)) }
        sqlite3_finalize(cstmt)

        // 分页数据
        let offset = max(0, page) * max(1, pageSize)
        var pageBinds = binds
        pageBinds.append(.int(Int64(pageSize)))
        pageBinds.append(.int(Int64(offset)))
        let sql = """
        SELECT l.request_id, l.provider_id, \(Self.providerNameCoalesce) AS provider_name, l.app_type, l.model,
               l.request_model, l.pricing_model, l.cost_multiplier,
               l.input_tokens, l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
               l.input_cost_usd, l.output_cost_usd, l.cache_read_cost_usd, l.cache_creation_cost_usd, l.total_cost_usd,
               l.is_streaming, l.latency_ms, l.first_token_ms, l.duration_ms,
               l.status_code, l.error_message, l.created_at, l.data_source
        FROM proxy_request_logs l
        \(Self.providersJoinL)
        \(whereClause)
        ORDER BY l.created_at DESC
        LIMIT ? OFFSET ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, pageBinds)

        var rows: [RequestLogRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mult = colText(stmt, 7)
            rows.append(RequestLogRow(
                requestId: colText(stmt, 0),
                providerId: colText(stmt, 1),
                providerName: colText(stmt, 2),
                appType: colText(stmt, 3),
                model: colText(stmt, 4),
                requestModel: colTextOpt(stmt, 5),
                pricingModel: colTextOpt(stmt, 6),
                costMultiplier: mult.isEmpty ? "1" : mult,
                inputTokens: sqlite3_column_int64(stmt, 8),
                outputTokens: sqlite3_column_int64(stmt, 9),
                cacheReadTokens: sqlite3_column_int64(stmt, 10),
                cacheCreationTokens: sqlite3_column_int64(stmt, 11),
                inputCostUsd: colText(stmt, 12),
                outputCostUsd: colText(stmt, 13),
                cacheReadCostUsd: colText(stmt, 14),
                cacheCreationCostUsd: colText(stmt, 15),
                totalCostUsd: colText(stmt, 16),
                isStreaming: sqlite3_column_int64(stmt, 17) != 0,
                latencyMs: sqlite3_column_int64(stmt, 18),
                firstTokenMs: colIntOpt(stmt, 19),
                durationMs: colIntOpt(stmt, 20),
                statusCode: Int(sqlite3_column_int64(stmt, 21)),
                errorMessage: colTextOpt(stmt, 22),
                createdAt: sqlite3_column_int64(stmt, 23),
                dataSource: colTextOpt(stmt, 24)
            ))
        }
        // 未入库增量:计入总数;并入第 0 页并按时间倒序重排(增量行都是最新的,
        // 页可能略超 pageSize,前端列表照常渲染)。字段口径与 cc-switch 入库值一致。
        let ov = overlayLogRows(db, f).sorted { $0.createdAt > $1.createdAt }
        if !ov.isEmpty {
            total += ov.count
            if page == 0 {
                let fmt6 = { (v: Double) in String(format: "%.6f", v) }
                let ovRows = ov.map { r in
                    RequestLogRow(
                        requestId: r.requestId, providerId: "_session",
                        providerName: "Claude (Session)", appType: "claude",
                        model: r.model, requestModel: r.model, pricingModel: nil,
                        costMultiplier: "1.0",
                        inputTokens: r.input, outputTokens: r.output,
                        cacheReadTokens: r.cacheRead, cacheCreationTokens: r.cacheCreation,
                        inputCostUsd: fmt6(r.inputCost), outputCostUsd: fmt6(r.outputCost),
                        cacheReadCostUsd: fmt6(r.cacheReadCost), cacheCreationCostUsd: fmt6(r.cacheCreationCost),
                        totalCostUsd: fmt6(r.totalCost),
                        isStreaming: true, latencyMs: 0, firstTokenMs: nil, durationMs: nil,
                        statusCode: 200, errorMessage: nil, createdAt: r.createdAt,
                        dataSource: "session_log"
                    )
                }
                rows = (ovRows + rows).sorted { $0.createdAt > $1.createdAt }
            }
        }
        return RequestLogPage(rows: rows, total: total)
    }

    /// Provider 统计。对齐 get_provider_stats（GROUP BY provider_id, app_type，
    /// total_tokens = fresh_input + output，ORDER BY total_cost DESC）。
    public func providerStats(_ f: LogQueryFilter) throws -> [ProviderStatRow] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let (whereClause, binds) = statsWhere(f)
        let sql = """
        SELECT l.provider_id, \(Self.providerNameCoalesce) AS provider_name,
               COUNT(*) AS request_count,
               COALESCE(SUM(\(Self.freshInputL) + l.output_tokens), 0) AS total_tokens,
               COALESCE(SUM(CAST(l.total_cost_usd AS REAL)), 0) AS total_cost,
               COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END), 0) AS success_count,
               CASE WHEN COUNT(*) > 0 THEN COALESCE(SUM(l.latency_ms), 0) / COUNT(*) ELSE 0 END AS avg_latency
        FROM proxy_request_logs l
        \(Self.providersJoinL)
        \(whereClause)
        GROUP BY l.provider_id, l.app_type
        ORDER BY total_cost DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)

        var out: [ProviderStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reqCount = sqlite3_column_int64(stmt, 2)
            let success = sqlite3_column_int64(stmt, 5)
            let rate = reqCount > 0 ? (Double(success) / Double(reqCount)) * 100.0 : 0.0
            out.append(ProviderStatRow(
                providerId: colText(stmt, 0),
                providerName: colText(stmt, 1),
                requestCount: reqCount,
                totalTokens: sqlite3_column_int64(stmt, 3),
                totalCost: sqlite3_column_double(stmt, 4),
                successRate: rate,
                avgLatencyMs: sqlite3_column_int64(stmt, 6)
            ))
        }
        // 未入库增量并入 "Claude (Session)"(overlay 行恒 200/latency 0,按计数折算均值)
        let ov = overlayLogRows(db, f)
        if !ov.isEmpty {
            let toks = ov.reduce(Int64(0)) { $0 + $1.input + $1.output }
            let cost = ov.reduce(0.0) { $0 + $1.totalCost }
            let n = Int64(ov.count)
            if let i = out.firstIndex(where: { $0.providerId == "_session" }) {
                let oldN = out[i].requestCount
                let newN = oldN + n
                out[i].successRate = newN > 0
                    ? (out[i].successRate * Double(oldN) + 100.0 * Double(n)) / Double(newN) : 100
                out[i].avgLatencyMs = newN > 0 ? out[i].avgLatencyMs * oldN / newN : 0
                out[i].requestCount = newN
                out[i].totalTokens += toks
                out[i].totalCost += cost
            } else {
                out.append(ProviderStatRow(providerId: "_session", providerName: "Claude (Session)",
                                           requestCount: n, totalTokens: toks, totalCost: cost,
                                           successRate: 100, avgLatencyMs: 0))
            }
            out.sort { $0.totalCost > $1.totalCost }
        }
        return out
    }

    /// 模型统计。对齐 get_model_stats（GROUP BY 有效计价模型，
    /// total_tokens = fresh_input + output，avg = total_cost / request_count）。
    public func modelStats(_ f: LogQueryFilter) throws -> [ModelStatRow] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let (whereClause, binds) = statsWhere(f)
        let sql = """
        SELECT \(Self.effectiveModelL) AS model,
               COUNT(*) AS request_count,
               COALESCE(SUM(\(Self.freshInputL) + l.output_tokens), 0) AS total_tokens,
               COALESCE(SUM(CAST(l.total_cost_usd AS REAL)), 0) AS total_cost
        FROM proxy_request_logs l
        \(Self.providersJoinL)
        \(whereClause)
        GROUP BY \(Self.effectiveModelL)
        ORDER BY total_cost DESC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }
        bindAll(stmt, binds)

        var out: [ModelStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reqCount = sqlite3_column_int64(stmt, 1)
            let totalCost = sqlite3_column_double(stmt, 3)
            let avg = reqCount > 0 ? totalCost / Double(reqCount) : 0.0
            out.append(ModelStatRow(
                model: colText(stmt, 0),
                requestCount: reqCount,
                totalTokens: sqlite3_column_int64(stmt, 2),
                totalCost: totalCost,
                avgCostPerRequest: avg
            ))
        }
        // 未入库增量按模型并入(total_tokens 口径 = fresh_input + output,与 SQL 一致)
        let ov = overlayLogRows(db, f)
        if !ov.isEmpty {
            var byModel: [String: (req: Int64, toks: Int64, cost: Double)] = [:]
            for r in ov {
                var a = byModel[r.model] ?? (0, 0, 0)
                a.req += 1
                a.toks += r.input + r.output
                a.cost += r.totalCost
                byModel[r.model] = a
            }
            for (m, a) in byModel {
                if let i = out.firstIndex(where: { $0.model == m }) {
                    out[i].requestCount += a.req
                    out[i].totalTokens += a.toks
                    out[i].totalCost += a.cost
                    out[i].avgCostPerRequest = out[i].requestCount > 0
                        ? out[i].totalCost / Double(out[i].requestCount) : 0
                } else {
                    out.append(ModelStatRow(model: m, requestCount: a.req, totalTokens: a.toks,
                                            totalCost: a.cost,
                                            avgCostPerRequest: a.req > 0 ? a.cost / Double(a.req) : 0))
                }
            }
            out.sort { $0.totalCost > $1.totalCost }
        }
        return out
    }
}
