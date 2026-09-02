import Foundation
import SQLite3

extension UsageStore {
    // MARK: - 区间汇总（两表合并）
    //
    // cc-switch get_usage_summary 是把 (logs 子查询 d) × (rollups 子查询 r) 交叉连接后逐列 d+r。
    // 这里等价地分别求 logs-only 与 rollups-only 再相加（数学完全一致），顺带让
    // get_usage_data_sources 复用 logs-only（rollups 无 data_source，不该算进「来源」）。

    /// logs 部分：仅 proxy_request_logs（fresh_input + 跨源去重过滤）。
    func summaryLogsOnly(_ db: OpaquePointer, _ f: UsageFilter) throws -> UsageSummary {
        let (conds, binds) = logConds(f)
        let sql = """
        SELECT COUNT(*),
               COALESCE(SUM(\(costL(db))),0),
               COALESCE(SUM(\(freshInput(db, "l"))),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END),0)
        FROM proxy_request_logs l\(Self.providersJoinIf(f.providerName, log: "l", provider: "p"))
        WHERE \(conds.joined(separator: " AND "))
        """
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }

        var s = UsageSummary()
        if sqlite3_step(stmt) == SQLITE_ROW { s = readSummary(stmt) }
        // 未入库增量:所有汇总路径(Hero/菜单栏/累计/数据源)都经此函数,一处叠加全局生效
        addOverlay(&s, overlayRows(db, f))
        return s
    }

    /// rollups 部分：仅 usage_daily_rollups（fresh_input + 整日边界对齐）。
    func summaryRollupsOnly(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> UsageSummary {
        let (conds, binds) = rollupConds(f, rollupDateBounds(f.start, f.end, cal))
        let whereClause = conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND ")
        let sql = """
        SELECT COALESCE(SUM(r.request_count),0),
               COALESCE(SUM(\(costR(db))),0),
               COALESCE(SUM(\(freshInput(db, "r"))),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0),
               COALESCE(SUM(r.success_count),0)
        FROM usage_daily_rollups r\(Self.providersJoinIf(f.providerName, log: "r", provider: "p2"))
        \(whereClause)
        """
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }

        var s = UsageSummary()
        if sqlite3_step(stmt) == SQLITE_ROW { s = readSummary(stmt) }
        return s
    }

    /// 两表合并汇总 = logs-only + rollups-only（逐列相加，等价 cc-switch 的 d+r）。
    func summary(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> UsageSummary {
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

        // 不按 app 过滤、按 app 分组：两侧条件都用 appType = nil 的过滤器生成；
        // 绑定参数顺序 = 明细侧在前、rollup 侧在后（与 SQL 里两个子查询的先后一致）。
        var noApp = filter; noApp.appType = nil
        let (dConds, dBinds) = logConds(noApp)
        let (rConds, rBinds) = rollupConds(noApp, rollupDateBounds(filter.start, filter.end, cal))
        let binds = dBinds + rBinds

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
            FROM proxy_request_logs l\(Self.providersJoinIf(filter.providerName, log: "l", provider: "p"))
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
            FROM usage_daily_rollups r\(Self.providersJoinIf(filter.providerName, log: "r", provider: "p2"))
            \(rWhere)
            GROUP BY r.app_type
        )
        GROUP BY app_type
        """
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }

        var out: [(appType: String, summary: UsageSummary)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let app = SQLite.text(stmt, 0)
            let s = readSummary(stmt, from: 1)
            if s.requests == 0 && s.tokensProcessed == 0 { continue }
            out.append((appType: app, summary: s))
        }
        // 增量行按各自 app_type 并入(桶不存在则新建)。OMP 日志一个文件里混着
        // Claude 与 Grok，全塞进 claude 桶会让 Grok 的用量假装成 Claude 的。
        let ov = overlayRows(db, noApp)
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

    // MARK: - 汇总小工具

    /// 明细表侧 WHERE 条件（首条恒为跨源去重；其余顺序 = 上游 push 顺序：时间窗 → app → provider → 模型）。
    func logConds(_ f: UsageFilter) -> ([String], [SQLBind]) {
        var conds: [String] = [Self.effectiveUsageFilterL]
        var binds: [SQLBind] = []
        if let s = f.start { conds.append("l.created_at >= ?"); binds.append(.int(s)) }
        if let e = f.end { conds.append("l.created_at <= ?"); binds.append(.int(e)) }
        if let at = f.appType { conds.append("\(Self.foldedAppL) = ?"); binds.append(.text(at)) }
        if let pn = f.providerName { conds.append("\(Self.providerNameCoalesce) = ?"); binds.append(.text(pn)) }
        if let m = f.model { conds.append("\(Self.effectiveModelL) = ?"); binds.append(.text(m)) }
        return (conds, binds)
    }

    /// rollups 侧 WHERE 条件：整日边界（isEmpty → "1 = 0" 让该侧为空）→ app → provider → 模型。
    func rollupConds(_ f: UsageFilter, _ b: RollupBounds) -> ([String], [SQLBind]) {
        var conds: [String] = []
        var binds: [SQLBind] = []
        if b.isEmpty {
            conds.append("1 = 0")
        } else {
            if let s = b.start { conds.append("r.date >= ?"); binds.append(.text(s)) }
            if let e = b.end { conds.append("r.date <= ?"); binds.append(.text(e)) }
        }
        if let at = f.appType { conds.append("\(Self.foldedAppR) = ?"); binds.append(.text(at)) }
        if let pn = f.providerName { conds.append("\(Self.providerNameSQL(log: "r", provider: "p2")) = ?"); binds.append(.text(pn)) }
        if let m = f.model { conds.append("\(Self.effectiveModelR) = ?"); binds.append(.text(m)) }
        return (conds, binds)
    }

    /// 七列投影 → UsageSummary。列序固定：requests, cost, input, output, creation, hit, successes；
    /// `from` 为首列偏移（by-app 查询第 0 列是 app_type）。
    func readSummary(_ stmt: OpaquePointer?, from c: Int32 = 0) -> UsageSummary {
        var s = UsageSummary()
        s.requests  = Int(sqlite3_column_int64(stmt, c))
        s.cost      = sqlite3_column_double(stmt, c + 1)
        s.input     = sqlite3_column_int64(stmt, c + 2)
        s.output    = sqlite3_column_int64(stmt, c + 3)
        s.creation  = sqlite3_column_int64(stmt, c + 4)
        s.hit       = sqlite3_column_int64(stmt, c + 5)
        s.successes = Int(sqlite3_column_int64(stmt, c + 6))
        return s
    }
}
