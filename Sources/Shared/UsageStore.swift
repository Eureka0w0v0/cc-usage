import Foundation
import SQLite3

// cc-switch 用量数据层：只读 ~/.cc-switch/cc-switch.db，聚合出「区间摘要 / 走势 / 累计」。
// 口径逐字对齐 cc-switch 的 usage_stats.rs（get_usage_summary / get_usage_summary_by_app /
// get_daily_trends）——「近期明细」proxy_request_logs 与「历史日聚合」usage_daily_rollups
// 两表合并：
//   Tokens Processed = fresh_input + output + cache_creation + cache_read
//   fresh_input      = 按行 input_token_semantics 归一（sql_helpers.rs v13）：legacy 行
//                      codex 系减 cache_read，total 行再减 cache_creation，fresh 行原样；
//                      旧库（schema <13，无该列）沿用旧口径：codex/gemini 减 cache_read
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
    public var successes: Int = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var creation: Int64 = 0
    public var hit: Int64 = 0
    public var cost: Double = 0

    /// 成功率（百分比）。对齐 usage_stats.rs：无请求时返回 **0** 而非 100。
    /// 早前桥接层给面板直接写死 100，属于潜伏的错值——只是当前 embed 不渲染
    /// summary 的这个字段（只有 ProviderStatsTable 渲染成功率，走的是另一条路）。
    public var successRate: Double {
        requests > 0 ? Double(successes) / Double(requests) * 100 : 0
    }
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

/// 「按来源」一行。dataSource 取值空间同 proxy_request_logs.data_source
/// （session_log / codex_session / gemini_session / opencode_session / grok_session /
/// proxy），外加本 app 独有的 omp_session（cc-switch 不导入 OMP）。
public struct DataSourceStat: Sendable {
    public var dataSource: String
    public var requestCount: Int64
    public var totalCost: Double
}

// SQLite 绑定文本时用（拷贝字符串，安全）
let SQLITE_TRANSIENT_DEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 线程安全：自身状态只有三个不可变引用（path / overlay / ompOverlay），每次查询独立开
/// 只读连接，两个 overlay 内部各自有锁——可安全从任意线程调用（后台 reload / 桥接队列
/// 都依赖这点）。
public final class UsageStore: @unchecked Sendable {
    public static let defaultPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".cc-switch/cc-switch.db")

    private let path: String
    private let overlay: SessionOverlay
    private let ompOverlay: OmpOverlay
    /// 两个 overlay 均可注入：测试用独立实例（空目录）隔离真实会话日志，生产默认共享单例。
    public init(path: String = UsageStore.defaultPath,
                overlay: SessionOverlay = .shared,
                ompOverlay: OmpOverlay = .shared) {
        self.path = path
        self.overlay = overlay
        self.ompOverlay = ompOverlay
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
        // 装内置定价兜底表(TEMP;只读库照样可建,temp 库独立于主库)。用于给
        // cc-switch 尚未收录定价、成本被写成 0 的行现场补算。建表失败不致命：
        // costL/costR 的子查询取不到行会回落 0,即旧行为。
        ModelPricing.installFallbackTable(handle)
        return handle
    }

    // MARK: - 增量叠加（SessionOverlay + OmpOverlay）
    //
    // 两个来源性质不同：
    //   * SessionOverlay —— cc-switch 迟早会入库的 Claude Code 增量。它不在运行时新用量
    //     只存在于 ~/.claude/projects 的 JSONL 里，补录后 overlay 自动清空、数字无缝交接；
    //   * OmpOverlay —— cc-switch 压根不扫 ~/.omp/agent/sessions，永远不会收录，所以这
    //     一层是 OMP 用量在本应用里的唯一来源，不存在「等它补录」。
    //
    // 两者产出同一种 OverlayRow，各自带 appType/providerName，这里按行过滤后合并：于是
    // OMP 走 anthropic 的 Claude 请求落进 claude 分组（与 5H/Week 徽标同一笔账），走
    // custom-gateway 的 grok 落进 grokbuild 分组，不会被笼统算成一坨。
    // 两层共用 "session:<msg_id>" 命名空间，同一条响应即便都看见也只算一次。

    /// 取符合过滤条件的增量行。overlay 行 pricing_model 为空 → 有效计价模型回落 model,
    /// 与库内 session 行口径一致。
    private func overlayRows(_ db: OpaquePointer, start: Int64?, end: Int64?,
                             appType: String?, model: String?) -> [OverlayRow] {
        var rows = overlay.pendingRows(db: db)
        let ompRows = ompOverlay.pendingRows(db: db)
        if !ompRows.isEmpty {
            if rows.isEmpty {
                rows = ompRows                      // 常态：cc-switch 已消化完 Claude Code 日志
            } else {
                let seen = Set(rows.map(\.requestId))
                rows.append(contentsOf: ompRows.filter { !seen.contains($0.requestId) })
            }
        }
        if let at = appType { rows = rows.filter { $0.appType == at } }
        if let s = start { rows = rows.filter { $0.createdAt >= s } }
        if let e = end { rows = rows.filter { $0.createdAt <= e } }
        if let m = model { rows = rows.filter { $0.model == m } }
        return rows
    }

    /// LogQueryFilter 版(Tabs 用):多两个维度——provider 名与状态码。
    /// overlay 行状态码恒 200;provider 展示名由行自带("Claude (Session)" / "OMP (…)")。
    private func overlayLogRows(_ db: OpaquePointer, _ f: LogQueryFilter) -> [OverlayRow] {
        if let sc = f.statusCode, sc != 200 { return [] }
        var rows = overlayRows(db, start: f.start, end: f.end, appType: f.appType, model: f.model)
        if let pn = f.providerName { rows = rows.filter { $0.providerName == pn } }
        return rows
    }

    /// 把增量行累加进汇总(claude 的 fresh_input = input,无 cache 扣减)。
    private func addOverlay(_ s: inout UsageSummary, _ rows: [OverlayRow]) {
        guard !rows.isEmpty else { return }
        s.requests += rows.count
        // 增量行来自已完成的响应（JSONL 里只有拿到 usage 的 assistant 消息才成行），
        // 没有失败态可言，全部计入成功。
        s.successes += rows.count
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
               COALESCE(SUM(\(costL(db))),0),
               COALESCE(SUM(\(freshInput(db, "l"))),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END),0)
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
            s.successes = Int(sqlite3_column_int64(stmt, 6))
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
               COALESCE(SUM(\(costR(db))),0),
               COALESCE(SUM(\(freshInput(db, "r"))),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0),
               COALESCE(SUM(r.success_count),0)
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
            s.successes = Int(sqlite3_column_int64(stmt, 6))
        }
        return s
    }

    /// 两表合并汇总 = logs-only + rollups-only（逐列相加，等价 cc-switch 的 d+r）。
    private func summary(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> UsageSummary {
        let a = try summaryLogsOnly(db, f)
        let r = try summaryRollupsOnly(db, f, cal)
        var s = UsageSummary()
        s.requests  = a.requests + r.requests
        s.successes = a.successes + r.successes
        s.input     = a.input + r.input
        s.output    = a.output + r.output
        s.creation  = a.creation + r.creation
        s.hit       = a.hit + r.hit
        s.cost      = a.cost + r.cost
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
               SUM(req), SUM(cost), SUM(inp), SUM(outp), SUM(cc), SUM(cr), SUM(ok)
        FROM (
            SELECT \(Self.foldedAppL) AS app_type,
                   COUNT(*) AS req,
                   COALESCE(SUM(\(costL(db))),0) AS cost,
                   COALESCE(SUM(\(freshInput(db, "l"))),0) AS inp,
                   COALESCE(SUM(l.output_tokens),0) AS outp,
                   COALESCE(SUM(l.cache_creation_tokens),0) AS cc,
                   COALESCE(SUM(l.cache_read_tokens),0) AS cr,
                   COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END),0) AS ok
            FROM proxy_request_logs l
            WHERE \(dConds.joined(separator: " AND "))
            GROUP BY l.app_type
            UNION ALL
            SELECT \(Self.foldedAppR) AS app_type,
                   COALESCE(SUM(r.request_count),0),
                   COALESCE(SUM(\(costR(db))),0),
                   COALESCE(SUM(\(freshInput(db, "r"))),0),
                   COALESCE(SUM(r.output_tokens),0),
                   COALESCE(SUM(r.cache_creation_tokens),0),
                   COALESCE(SUM(r.cache_read_tokens),0),
                   COALESCE(SUM(r.success_count),0)
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
            s.successes = Int(sqlite3_column_int64(stmt, 7))
            if s.requests == 0 && s.tokensProcessed == 0 { continue }
            out.append((appType: app, summary: s))
        }
        // 增量行按各自 app_type 并入(桶不存在则新建)。OMP 日志一个文件里混着
        // Claude 与 Grok，全塞进 claude 桶会让 Grok 的用量假装成 Claude 的。
        let ov = overlayRows(db, start: filter.start, end: filter.end, appType: nil, model: filter.model)
        if !ov.isEmpty {
            var byApp: [String: [OverlayRow]] = [:]
            for r in ov { byApp[r.appType, default: []].append(r) }
            for (app, rows) in byApp {
                if let i = out.firstIndex(where: { $0.appType == app }) {
                    addOverlay(&out[i].summary, rows)
                } else {
                    var s = UsageSummary()
                    addOverlay(&s, rows)
                    out.append((appType: app, summary: s))
                }
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
               COALESCE(SUM(\(freshInput(db, "l"))),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(\(costL(db))),0),
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
               COALESCE(SUM(\(freshInput(db, "l"))),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(\(costL(db))),0)
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
               COALESCE(SUM(\(freshInput(db, "r"))),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0),
               COALESCE(SUM(\(costR(db))),0)
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
    ///
    /// includeCumulative=false 时跳过那次无时间窗的全库聚合：它要带着跨源去重的相关
    /// 子查询逐行扫完 proxy_request_logs + rollups（本机实测 ~27ms），而菜单栏路径
    /// 只读 today/trend/lastEventAt，累计值拿了就扔——默认 5 秒一刷即每秒白燃 CPU。
    /// Widget 要显示累计，保持传 true。
    public func snapshot(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current,
                         includeCumulative: Bool = true) throws -> UsageSnapshot {
        let db = try openRO()
        defer { sqlite3_close(db) }

        let f = resolvedFilter(filter, now: now, calendar)
        let range = try summary(db, f, calendar)
        let cumulative = includeCumulative
            ? try summary(db, UsageFilter(appType: filter.appType, model: filter.model), calendar)
            : UsageSummary()
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
    // 跨源去重过滤（effective_usage_log_filter）在三个 Tab 里同样必须套用：早前以
    // 「本机无 'proxy' 行 → 空操作」为由略去，但那是环境事实不是语义结论——用户一旦
    // 打开 cc-switch 的代理，同一笔请求既落 proxy 又落 session_log，Hero 去重而 Tab
    // 不去重就会当场自相矛盾（Hero 总额 ≠ Σ Provider Stats，重复行还直接列在日志里）。

    /// 折叠 claude-desktop→claude（仅过滤/分组口径，行投影仍返回原始 app_type）。
    static let foldedAppL = "CASE WHEN l.app_type='claude-desktop' THEN 'claude' ELSE l.app_type END"
    /// 有效计价模型：pricing_model 非空优先，NULL/'' 回落 model。
    static let effectiveModelL = "COALESCE(NULLIF(l.pricing_model, ''), l.model)"
    /// cache 归一化 input（对齐 sql_helpers.rs::fresh_input_sql，v13 语义）：
    /// input_token_semantics 0=legacy（codex 系 input 含 cache_read）、
    /// 1=total（还含 cache_creation）、2=fresh（已归一，原样返回）。
    static func freshInputV13(_ a: String) -> String {
        "CASE WHEN \(a).input_token_semantics = 2 THEN \(a).input_tokens WHEN \(a).app_type IN ('codex','gemini','grokbuild') AND \(a).input_token_semantics = 1 AND \(a).input_tokens >= (\(a).cache_read_tokens + \(a).cache_creation_tokens) THEN (\(a).input_tokens - \(a).cache_read_tokens - \(a).cache_creation_tokens) WHEN \(a).app_type IN ('codex','gemini','grokbuild') AND \(a).input_token_semantics = 0 AND \(a).input_tokens >= \(a).cache_read_tokens THEN (\(a).input_tokens - \(a).cache_read_tokens) ELSE \(a).input_tokens END"
    }
    /// cache 归一化 input（schema <13 旧库：无 input_token_semantics 列，行为与旧版完全一致）。
    static func freshInputLegacy(_ a: String) -> String {
        "CASE WHEN \(a).app_type IN ('codex','gemini') AND \(a).input_tokens >= \(a).cache_read_tokens THEN (\(a).input_tokens - \(a).cache_read_tokens) ELSE \(a).input_tokens END"
    }
    /// 元数据探测小工具：每次查询用打开的连接现探，不做实例级缓存，避免 cc-switch
    /// 升级迁移后口径滞后。读的是元数据表，微秒级。
    private func exists(_ db: OpaquePointer, _ sql: String) -> Bool {
        var stmt: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        return found
    }
    /// 某表是否有某列（老库缺列时相关分支必须整支摘掉，否则 prepare 直接失败）。
    private func hasColumn(_ db: OpaquePointer, _ table: String, _ col: String) -> Bool {
        exists(db, "SELECT 1 FROM pragma_table_info('\(table)') WHERE name='\(col)'")
    }
    /// 本库是否有 v13 的 input_token_semantics 列。
    private func hasSemantics(_ db: OpaquePointer) -> Bool {
        hasColumn(db, "proxy_request_logs", "input_token_semantics")
    }
    /// TEMP 兜底定价表是否建成（openRO 里装的）。建不成时 costSQL 必须退化，
    /// 否则相关子查询在 prepare 阶段解析不到表名，会让每一条查询直接抛错。
    private func hasFallbackPricing(_ db: OpaquePointer) -> Bool {
        exists(db, "SELECT 1 FROM sqlite_temp_master WHERE type='table' AND name='\(ModelPricing.fallbackTable)'")
    }
    /// 按当前库 schema 选 fresh_input 表达式。
    private func freshInput(_ db: OpaquePointer, _ alias: String) -> String {
        hasSemantics(db) ? Self.freshInputV13(alias) : Self.freshInputLegacy(alias)
    }
    /// 成本（明细表侧）：库里已有正成本优先，未定价行按内置表现场补算(见 ModelPricing)。
    /// 用户在 cc-switch 里改过的价永远优先，绝不被内置表覆盖。
    private func costL(_ db: OpaquePointer) -> String {
        ModelPricing.costSQL(
            alias: "l",
            multiplier: "COALESCE(NULLIF(CAST(l.cost_multiplier AS REAL), 0), 1.0)",
            hasSemantics: hasSemantics(db), hasFallbackTable: hasFallbackPricing(db),
            hasRequestModel: hasColumn(db, "proxy_request_logs", "request_model"))
    }
    /// 成本（rollups 侧）。该表没有 cost_multiplier 列，倍率恒 1。
    private func costR(_ db: OpaquePointer) -> String {
        ModelPricing.costSQL(
            alias: "r", multiplier: "1.0",
            hasSemantics: hasSemantics(db), hasFallbackTable: hasFallbackPricing(db),
            hasRequestModel: hasColumn(db, "usage_daily_rollups", "request_model"))
    }
    /// provider 展示名：providers.name 优先，会话占位 provider_id 映射为可读名。
    static let providerNameCoalesce = "COALESCE(p.name, CASE l.provider_id WHEN '_session' THEN 'Claude (Session)' WHEN '_codex_session' THEN 'Codex (Session)' WHEN '_gemini_session' THEN 'Gemini (Session)' WHEN '_opencode_session' THEN 'OpenCode (Session)' WHEN '_grok_session' THEN 'Grok Build (Session)' ELSE l.provider_id END)"
    static let providersJoinL = "LEFT JOIN providers p ON l.provider_id = p.id AND l.app_type = p.app_type"

    // ── usage_daily_rollups(别名 r) 侧的对应片段，供两表合并的 summary/trend/by-app 使用 ──
    /// 折叠 claude-desktop→claude（rollups 侧）。
    static let foldedAppR = "CASE WHEN r.app_type='claude-desktop' THEN 'claude' ELSE r.app_type END"
    /// 有效计价模型（rollups 侧）。
    static let effectiveModelR = "COALESCE(NULLIF(r.pricing_model, ''), r.model)"
    /// 跨源去重时的 app_type 匹配（对齐 usage_stats.rs::dedup_app_type_match_sql）：
    /// Claude Code 与 Claude Desktop 共用同一套 message id —— 走 Desktop 网关的请求以
    /// `claude-desktop` 落 proxy 行，而 session 导入器以 `claude` 落 session_log 行。
    /// 故 `claude` 的 session 行必须也能匹配 `claude-desktop` 的 proxy 行，否则同一笔
    /// 请求被双算。其余 app_type 保持精确比较，避免不同上游之间误撞。
    /// 注意：这是比展示口径折叠（foldedAppL）更窄的匹配 —— 只放宽 claude 一侧。
    static func dedupAppTypeMatch(_ left: String, _ right: String) -> String {
        "\(left) IN (\(right), CASE WHEN \(right)='claude' THEN 'claude-desktop' ELSE \(right) END)"
    }
    /// 跨源去重过滤（对齐 usage_stats.rs::effective_usage_log_filter，别名 l）：
    /// session 系日志若在 ±10min 窗口内存在指纹匹配的成功 proxy 行，则剔除该 session 行，
    /// 防止「同一次请求既落 session 又落 proxy」被双算。600 = 10min 窗口秒数。
    /// 本机无 'proxy' 行 → EXISTS 恒 false → NOT(...) 恒 true → 全过（已验证），但忠实照搬。
    static let effectiveUsageFilterL = "NOT (COALESCE(l.data_source,'proxy') IN ('session_log','codex_session','gemini_session','opencode_session') AND EXISTS (SELECT 1 FROM proxy_request_logs proxy_dedup WHERE COALESCE(proxy_dedup.data_source,'proxy')='proxy' AND \(dedupAppTypeMatch("proxy_dedup.app_type", "l.app_type")) AND proxy_dedup.status_code>=200 AND proxy_dedup.status_code<300 AND proxy_dedup.input_tokens=l.input_tokens AND proxy_dedup.output_tokens=l.output_tokens AND proxy_dedup.cache_read_tokens=l.cache_read_tokens AND (proxy_dedup.cache_creation_tokens=l.cache_creation_tokens OR (l.cache_creation_tokens=0 AND COALESCE(l.data_source,'proxy') IN ('codex_session','gemini_session','opencode_session'))) AND proxy_dedup.created_at BETWEEN l.created_at-600 AND l.created_at+600 AND (LOWER(proxy_dedup.model)=LOWER(l.model) OR LOWER(proxy_dedup.model)='unknown' OR LOWER(l.model)='unknown')))"

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
    // 首条恒为跨源去重过滤，对齐 get_provider_stats / get_model_stats（usage_stats.rs
    // :1265 / :1409，两者都以 vec![effective_usage_log_filter("l")] 起头）。
    private func statsWhere(_ f: LogQueryFilter) -> (String, [Bind]) {
        var conds: [String] = [Self.effectiveUsageFilterL]
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

        // 首条恒为跨源去重过滤，对齐 get_request_logs（usage_stats.rs:1554）。
        var conds: [String] = [Self.effectiveUsageFilterL]
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

        // 分页数据。pageSize 直接来自 WebView 桥接，必须消毒后再绑给 LIMIT：
        // 0 → LIMIT 0 返回空页；负数 → SQLite 语义下 LIMIT -1 = 无上限，会把整张
        // proxy_request_logs 物化成 RequestLogRow 再桥接成 JSON 丢给 WKWebView。
        let size = max(1, pageSize)
        let offset = max(0, page) * size
        // 库内行与增量行各自按 created_at DESC 有序，本页 = 两路归并后的第
        // [offset, offset+size) 段。取该段只需两路各拿前 need 条——排在更后面的行
        // 无论如何都挤不进这一页。故 SQL 侧不再走 OFFSET，改为一律 LIMIT need
        // 后在内存里切片(见下方归并)。
        //
        // 取舍：深翻页要物化 need 行而非 size 行，成本随页码线性上涨(本机 26480 行
        // 下 page 0 = 9.7ms、page 1000 = 67ms，内存无异常)。换来的是第 0 页——也就是
        // 面板每次打开与每轮刷新都要走的那条路——从 56ms/7.8MB payload 降到 9.7ms，
        // 且分页终于自洽。真实使用里没人翻到第一千页，这笔换划算。
        let need = offset + size
        var pageBinds = binds
        pageBinds.append(.int(Int64(need)))
        let sql = """
        SELECT l.request_id, l.provider_id, \(Self.providerNameCoalesce) AS provider_name, l.app_type, l.model,
               l.request_model, l.pricing_model, l.cost_multiplier,
               l.input_tokens, l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
               l.input_cost_usd, l.output_cost_usd, l.cache_read_cost_usd, l.cache_creation_cost_usd, l.total_cost_usd,
               l.is_streaming, l.latency_ms, l.first_token_ms, l.duration_ms,
               l.status_code, l.error_message, l.created_at, l.data_source,
               \(ModelPricing.billableInputSQL("l", hasSemantics: hasSemantics(db))) AS billable_input
        FROM proxy_request_logs l
        \(Self.providersJoinL)
        \(whereClause)
        ORDER BY l.created_at DESC
        LIMIT ?
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
            let inTok = sqlite3_column_int64(stmt, 8)
            let outTok = sqlite3_column_int64(stmt, 9)
            let crTok = sqlite3_column_int64(stmt, 10)
            let ccTok = sqlite3_column_int64(stmt, 11)
            var costs = (input: colText(stmt, 12), output: colText(stmt, 13),
                         cacheRead: colText(stmt, 14), cacheCreation: colText(stmt, 15),
                         total: colText(stmt, 16))
            // cc-switch 入库时查不到定价 → 成本写死 0,面板显示「未定价」。这里用
            // 内置表现场补算(只读,不改库);库里已有正成本的行原样保留。
            if (Double(costs.total) ?? 0) <= 0,
               inTok > 0 || outTok > 0 || crTok > 0 || ccTok > 0 {
                // 计价基准与 input 口径都走与 costSQL 同一套规则（占位符判定 +
                // billable input），否则同一行在 Hero 和明细表里会算出两个数。
                let effective = ModelPricing.resolvePricingModel(
                    pricingModel: colTextOpt(stmt, 6),
                    model: colText(stmt, 4),
                    requestModel: colTextOpt(stmt, 5))
                if let effective,
                   let b = ModelPricing.backfilledCosts(
                    model: effective, multiplier: Double(mult) ?? 1,
                    billableInput: sqlite3_column_int64(stmt, 25),
                    output: outTok, cacheRead: crTok, cacheCreation: ccTok) {
                    costs = b
                }
            }
            rows.append(RequestLogRow(
                requestId: colText(stmt, 0),
                providerId: colText(stmt, 1),
                providerName: colText(stmt, 2),
                appType: colText(stmt, 3),
                model: colText(stmt, 4),
                requestModel: colTextOpt(stmt, 5),
                pricingModel: colTextOpt(stmt, 6),
                costMultiplier: mult.isEmpty ? "1" : mult,
                inputTokens: inTok,
                outputTokens: outTok,
                cacheReadTokens: crTok,
                cacheCreationTokens: ccTok,
                inputCostUsd: costs.input,
                outputCostUsd: costs.output,
                cacheReadCostUsd: costs.cacheRead,
                cacheCreationCostUsd: costs.cacheCreation,
                totalCostUsd: costs.total,
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
        // 增量行:计入总数,并与库内行二路归并后再切页。
        //
        // 旧实现把符合条件的增量行**整批**塞进第 0 页(无视 pageSize)。本机 overlay
        // 常驻 1.4 万行 → 前端要 20 条却收到 14722 条、7.8MB payload 过 WKWebView 桥,
        // 面板直接卡死;而且 total 把这些行算了进去、第 1 页之后却一条都不给,分页
        // 一路错位到底(逐页拉全量只能取回不到七成,跨页时间序也是断的)。
        //
        // 归并只需两路各自的前 need 条:两路都按 created_at DESC 有序,第 need 条
        // 之后的行不可能落进 [offset, offset+size)。
        let ov = overlayLogRows(db, f)
        guard !ov.isEmpty else {
            return RequestLogPage(rows: Array(rows.dropFirst(offset)), total: total)
        }
        total += ov.count

        let fmt6 = { (v: Double) in String(format: "%.6f", v) }
        let ovRows = ov.sorted { $0.createdAt > $1.createdAt }.prefix(need).map { r in
            RequestLogRow(
                requestId: r.requestId, providerId: r.providerId,
                providerName: r.providerName, appType: r.appType,
                model: r.model, requestModel: r.model, pricingModel: nil,
                costMultiplier: "1.0",
                inputTokens: r.input, outputTokens: r.output,
                cacheReadTokens: r.cacheRead, cacheCreationTokens: r.cacheCreation,
                inputCostUsd: fmt6(r.inputCost), outputCostUsd: fmt6(r.outputCost),
                cacheReadCostUsd: fmt6(r.cacheReadCost), cacheCreationCostUsd: fmt6(r.cacheCreationCost),
                totalCostUsd: fmt6(r.totalCost),
                isStreaming: true, latencyMs: 0, firstTokenMs: nil, durationMs: nil,
                statusCode: 200, errorMessage: nil, createdAt: r.createdAt,
                dataSource: r.providerId == "_session" ? "session_log" : "omp_session"
            )
        }

        // 同 created_at 时库内行优先(>=)：cc-switch 补录后同一条响应会先由库内行
        // 顶替、overlay 侧再被 request_id 去重剔除，翻页时不会先后跳位。
        var merged: [RequestLogRow] = []
        merged.reserveCapacity(min(need, rows.count + ovRows.count))
        var i = 0, j = 0
        while merged.count < need, i < rows.count || j < ovRows.count {
            if j >= ovRows.count || (i < rows.count && rows[i].createdAt >= ovRows[j].createdAt) {
                merged.append(rows[i]); i += 1
            } else {
                merged.append(ovRows[j]); j += 1
            }
        }
        return RequestLogPage(rows: Array(merged.dropFirst(offset)), total: total)
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
               COALESCE(SUM(\(freshInput(db, "l")) + l.output_tokens), 0) AS total_tokens,
               COALESCE(SUM(\(costL(db))), 0) AS total_cost,
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
        // 增量行按各自 provider 并入(overlay 行恒 200/latency 0,按计数折算均值)。
        // OMP 日志里混着多家 provider,必须分组累加——一股脑塞进 "Claude (Session)"
        // 会把 grok 的花费记到 Claude 头上。
        let ov = overlayLogRows(db, f)
        if !ov.isEmpty {
            var grouped: [String: (name: String, req: Int64, toks: Int64, cost: Double)] = [:]
            for r in ov {
                var g = grouped[r.providerId] ?? (name: r.providerName, req: 0, toks: 0, cost: 0)
                g.req += 1
                g.toks += r.input + r.output
                g.cost += r.totalCost
                grouped[r.providerId] = g
            }
            for (pid, g) in grouped {
                if let i = out.firstIndex(where: { $0.providerId == pid }) {
                    let oldN = out[i].requestCount
                    let newN = oldN + g.req
                    out[i].successRate = newN > 0
                        ? (out[i].successRate * Double(oldN) + 100.0 * Double(g.req)) / Double(newN) : 100
                    out[i].avgLatencyMs = newN > 0 ? out[i].avgLatencyMs * oldN / newN : 0
                    out[i].requestCount = newN
                    out[i].totalTokens += g.toks
                    out[i].totalCost += g.cost
                } else {
                    out.append(ProviderStatRow(providerId: pid, providerName: g.name,
                                               requestCount: g.req, totalTokens: g.toks, totalCost: g.cost,
                                               successRate: 100, avgLatencyMs: 0))
                }
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
               COALESCE(SUM(\(freshInput(db, "l")) + l.output_tokens), 0) AS total_tokens,
               COALESCE(SUM(\(costL(db))), 0) AS total_cost
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

    /// 「按来源」分组，对齐 session_usage.rs::get_data_source_breakdown：
    /// **不带时间窗**（上游此接口就是全表口径，日期选择器不作用于它）、
    /// GROUP BY COALESCE(data_source,'proxy')、带跨源去重过滤、按请求数降序。
    /// usage_daily_rollups 无 data_source 列，天然不参与（与上游一致）。
    ///
    /// 与上游的唯一有意偏差：成本用 costL（内置定价兜底）而非裸 total_cost_usd，
    /// 与本 app 其余面板同源，未定价模型不至于显示 0。
    public func dataSourceBreakdown() throws -> [DataSourceStat] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let sql = """
        SELECT COALESCE(l.data_source,'proxy') AS ds,
               COUNT(*),
               COALESCE(SUM(\(costL(db))),0)
        FROM proxy_request_logs l
        WHERE \(Self.effectiveUsageFilterL)
        GROUP BY ds
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        defer { sqlite3_finalize(stmt) }

        var acc: [String: (req: Int64, cost: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            acc[String(cString: c)] = (sqlite3_column_int64(stmt, 1),
                                       sqlite3_column_double(stmt, 2))
        }
        // 未入库增量按各自来源并入（SessionOverlay=session_log 会与库内同名桶合并，
        // 补录后自动收敛；OmpOverlay=omp_session 单列）。
        for r in overlayRows(db, start: nil, end: nil, appType: nil, model: nil) {
            var a = acc[r.dataSource] ?? (0, 0)
            a.req += 1
            a.cost += r.totalCost
            acc[r.dataSource] = a
        }
        return acc
            .map { DataSourceStat(dataSource: $0.key,
                                  requestCount: $0.value.req,
                                  totalCost: $0.value.cost) }
            .sorted { $0.requestCount > $1.requestCount }
    }
}
