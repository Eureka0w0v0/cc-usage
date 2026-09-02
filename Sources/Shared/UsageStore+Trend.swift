import Foundation
import SQLite3

extension UsageStore {
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
        FROM proxy_request_logs l\(Self.providersJoinIf(f.providerName, log: "l", provider: "p"))
        WHERE l.created_at >= ?1 AND l.created_at <= ?2 AND \(Self.effectiveUsageFilterL)
        """
        if f.appType != nil { sql += " AND \(Self.foldedAppL) = ?4" }
        if f.model != nil { sql += " AND \(Self.effectiveModelL) = ?5" }
        if f.providerName != nil { sql += " AND \(Self.providerNameCoalesce) = ?6" }
        sql += " GROUP BY bucket ORDER BY bucket"

        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)
        sqlite3_bind_int64(stmt, 3, bucketSeconds)
        if let a = f.appType { sqlite3_bind_text(stmt, 4, a, -1, SQLITE_TRANSIENT_DEST) }
        if let m = f.model { sqlite3_bind_text(stmt, 5, m, -1, SQLITE_TRANSIENT_DEST) }
        if let pn = f.providerName { sqlite3_bind_text(stmt, 6, pn, -1, SQLITE_TRANSIENT_DEST) }

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
        var ovFilter = f; ovFilter.start = start; ovFilter.end = end
        for r in overlayRows(db, ovFilter) {
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
        var lf = f; lf.start = startTs; lf.end = endTs   // 缺省窗口已在 startTs/endTs 落定
        let (lConds, lBinds) = logConds(lf)
        let lSQL = """
        SELECT date(l.created_at,'unixepoch','localtime') AS d,
               COUNT(*),
               COALESCE(SUM(\(freshInput(db, "l"))),0),
               COALESCE(SUM(l.output_tokens),0),
               COALESCE(SUM(l.cache_creation_tokens),0),
               COALESCE(SUM(l.cache_read_tokens),0),
               COALESCE(SUM(\(costL(db))),0)
        FROM proxy_request_logs l\(Self.providersJoinIf(f.providerName, log: "l", provider: "p"))
        WHERE \(lConds.joined(separator: " AND "))
        GROUP BY d
        """
        let lStmt = try prepare(db, lSQL, lBinds)
        while sqlite3_step(lStmt) == SQLITE_ROW {
            let d = SQLite.text(lStmt, 0)
            map[d] = Acc(req: Int(sqlite3_column_int64(lStmt, 1)),
                        input: sqlite3_column_int64(lStmt, 2),
                        output: sqlite3_column_int64(lStmt, 3),
                        creation: sqlite3_column_int64(lStmt, 4),
                        hit: sqlite3_column_int64(lStmt, 5),
                        cost: sqlite3_column_double(lStmt, 6))
        }
        sqlite3_finalize(lStmt)

        // --- rollups：按 r.date 分组，叠加到对应日（add，同一天不双算见边界对齐）---
        let (rConds, rBinds) = rollupConds(f, rollupDateBounds(startTs, endTs, cal))
        let rWhere = rConds.isEmpty ? "" : "WHERE " + rConds.joined(separator: " AND ")
        let rSQL = """
        SELECT r.date,
               COALESCE(SUM(r.request_count),0),
               COALESCE(SUM(\(freshInput(db, "r"))),0),
               COALESCE(SUM(r.output_tokens),0),
               COALESCE(SUM(r.cache_creation_tokens),0),
               COALESCE(SUM(r.cache_read_tokens),0),
               COALESCE(SUM(\(costR(db))),0)
        FROM usage_daily_rollups r\(Self.providersJoinIf(f.providerName, log: "r", provider: "p2"))
        \(rWhere)
        GROUP BY r.date
        """
        let rStmt = try prepare(db, rSQL, rBinds)
        while sqlite3_step(rStmt) == SQLITE_ROW {
            let d = SQLite.text(rStmt, 0)
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
        for r in overlayRows(db, lf) {
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

    /// 粒度选择：区间 ≤24h 走小时桶，否则天桶
    /// （阈值与前端 UsageTrendChart 的 isHourly = duration<=24h 严格一致，避免粒度错位）。
    func trend(_ db: OpaquePointer, _ f: UsageFilter, _ cal: Calendar) throws -> [TrendBucket] {
        let dur = (f.end ?? 0) - (f.start ?? 0)
        return dur <= 24 * 3600 ? try trendHourly(db, f) : try trendDaily(db, f, cal)
    }

    func lastEventTs(_ db: OpaquePointer) -> Int64? {
        var dbTs: Int64? = nil
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT MAX(created_at) FROM proxy_request_logs", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                dbTs = sqlite3_column_int64(stmt, 0)
            }
            sqlite3_finalize(stmt)
        }
        // 「最后活动」把未入库增量也算上(cc-switch 关闭时菜单栏的 "刚刚" 才是真的)
        let ovTs = overlayRows(db, UsageFilter())
            .map(\.createdAt).max()
        switch (dbTs, ovTs) {
        case (let a?, let b?): return max(a, b)
        case (let a?, nil):    return a
        case (nil, let b?):    return b
        default:               return nil
        }
    }
}
