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
        case .open(let rc): return "无法打开数据库 (sqlite rc=\(rc))"
        case .prepare(let sql): return "SQL 准备失败: \(sql)"
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

public final class UsageStore {
    // claude-desktop → claude，口径对齐 cc-switch
    static let foldedApp = "CASE WHEN app_type='claude-desktop' THEN 'claude' ELSE app_type END"

    public static let defaultPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".cc-switch/cc-switch.db")

    private let path: String
    public init(path: String = UsageStore.defaultPath) { self.path = path }

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

    // MARK: - rollup 日期边界（对齐 usage_stats.rs::compute_rollup_date_bounds）
    //
    // rollups 只纳入「完全落在区间内的整本地日」：区间起点非本地零点 → 从次日起；
    // 区间终点非本地 23:59 → 到前一日止。边界不足整日的那天由 logs(精确 created_at)覆盖，
    // 避免与 rollups 双算。isEmpty=true 时（start>end）用 "1=0" 让 rollups 部分为空。
    private struct RollupBounds { var start: String?; var end: String?; var isEmpty: Bool }

    private func rollupDateBounds(_ startTs: Int64?, _ endTs: Int64?, _ cal: Calendar) -> RollupBounds {
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
        while sqlite3_step(stmt) == SQLITE_ROW {
            var idx = Int(sqlite3_column_int64(stmt, 0))
            if idx < 0 { continue }
            if idx >= count { idx = count - 1 }
            buckets[idx].input    = sqlite3_column_int64(stmt, 1)
            buckets[idx].output   = sqlite3_column_int64(stmt, 2)
            buckets[idx].creation = sqlite3_column_int64(stmt, 3)
            buckets[idx].hit      = sqlite3_column_int64(stmt, 4)
            buckets[idx].cost     = sqlite3_column_double(stmt, 5)
            buckets[idx].requestCount = Int(sqlite3_column_int64(stmt, 6))
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
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(created_at) FROM proxy_request_logs", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
            return sqlite3_column_int64(stmt, 0)
        }
        return nil
    }

    /// 按过滤条件生成快照（区间汇总 + 累计 + 走势）。区间 ≤24h 走小时桶，否则天桶
    /// （阈值与前端 UsageTrendChart 的 isHourly = duration<=24h 严格一致，避免粒度错位）。
    public func snapshot(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let db = try openRO()
        defer { sqlite3_close(db) }

        let nowTs = Int64(now.timeIntervalSince1970)
        var f = filter
        f.start = filter.start ?? Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        f.end = filter.end ?? nowTs
        let dur = (f.end ?? nowTs) - (f.start ?? 0)

        let range = try summary(db, f, calendar)
        let cumulative = try summary(db, UsageFilter(appType: filter.appType, model: filter.model), calendar)
        let tr = dur <= 24 * 3600 ? try trendHourly(db, f) : try trendDaily(db, f, calendar)
        let lastTs = lastEventTs(db)

        return UsageSnapshot(
            today: range,
            cumulative: cumulative,
            trend: tr,
            generatedAt: now,
            lastEventAt: lastTs.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// 便捷：默认「今日」快照（widget 用）。
    public func snapshot(now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let dayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        return try snapshot(filter: UsageFilter(start: dayStart, end: Int64(now.timeIntervalSince1970)),
                            now: now, calendar: calendar)
    }

    /// 只算某个时间窗的汇总（不含 trend），用于「近5小时 / 本周」这类常驻指标。两表合并。
    public func rangeSummary(_ filter: UsageFilter) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summary(db, filter, Calendar.current)
    }

    /// 仅 logs 部分的区间汇总（不含 rollups）。用于 get_usage_data_sources——
    /// rollups 无 data_source 列，不该被算进「按来源」的 session_log 计数。
    public func rangeSummaryLogsOnly(_ filter: UsageFilter) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summaryLogsOnly(db, filter)
    }

    private func queryStrings(_ sql: String) -> [String] {
        guard let db = try? openRO() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// 库中出现过的来源(app)，已折叠，按用量降序。
    public func distinctAppTypes() -> [String] {
        queryStrings("SELECT \(Self.foldedApp) AS a FROM proxy_request_logs WHERE app_type<>'' GROUP BY a ORDER BY COUNT(*) DESC")
    }

    /// 库中出现过的模型，按用量降序（限 40 个）。
    public func distinctModels() -> [String] {
        queryStrings("SELECT model FROM proxy_request_logs WHERE model<>'' GROUP BY model ORDER BY COUNT(*) DESC LIMIT 40")
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
        return out
    }
}
