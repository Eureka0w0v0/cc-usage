import Foundation
import SQLite3

extension UsageStore {
    // MARK: - Provider Stats / Model Stats / 按来源
    //
    // Provider / Model Stats 与上游 v4 一样把整日 rollup 也并进来，和 Hero 同口径，各行加起来等于顶部总数
    // （早先三个 Tab 都只读明细，区间跨到 30 天前时两张统计表会比 Hero 少一截，2026-10-15 随主窗口升级
    // v4 用量页一起对齐）。
    // SQL 片段逐一复刻 usage_stats.rs（alias 固定 l = proxy_request_logs，p = providers，
    // r = usage_daily_rollups，p2 = rollup 侧的 providers）。
    // 跨源去重过滤（effective_usage_log_filter）在三个 Tab 里同样必须套用：早前以
    // 「本机无 'proxy' 行 → 空操作」为由略去，但那是环境事实不是语义结论——用户一旦
    // 打开 cc-switch 的代理，同一笔请求既落 proxy 又落 session_log，Hero 去重而 Tab
    // 不去重就会当场自相矛盾（Hero 总额 ≠ Σ Provider Stats，重复行还直接列在日志里）。

    // provider / model 统计共用的 WHERE + 绑定参数（时间窗 + app + provider + model）。
    // 首条恒为跨源去重过滤，对齐 get_provider_stats / get_model_stats（usage_stats.rs
    // :1265 / :1409，两者都以 vec![effective_usage_log_filter("l")] 起头）。
    private func statsWhere(_ db: OpaquePointer, _ f: LogQueryFilter) -> (String, [SQLBind]) {
        let (conds, binds) = logConds(db, UsageFilter(start: f.start, end: f.end, appType: f.appType,
                                                  providerName: f.providerName, model: f.model))
        return ("WHERE " + conds.joined(separator: " AND "), binds)
    }

    /// Provider 统计。对齐 get_provider_stats（v4.0.12）：明细行与整日 rollup UNION ALL 后按
    /// (provider_id, app_type) 汇总，total_tokens = 真实消耗 realTotalTokens，ORDER BY total_cost DESC。
    /// 行身份是 (providerId, appType)：「Claude」筛选折叠了 claude-desktop，同一个供应商两边都配过时
    /// 会有两行同 id 同名的记录，appType 是区分它们的唯一依据（上游 v4.0.7 #8032）。
    /// 速度只看明细（rollup 没有逐条计时）；首字中位数另起一条查询按同一身份分组（见 firstTokenSamples）。
    /// 平均耗时 = 耗时之和 ÷ 请求数（整除，同上游）；SQL 只取和，叠加行并进来以后在这里除。
    public func providerStats(_ f: LogQueryFilter, calendar: Calendar = .current) throws -> [ProviderStatRow] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let (detailWhere, detailBinds) = statsWhere(db, f)
        let (rollupWhere, rollupBinds) = rollupStatsWhere(f, calendar)
        let sql = """
        SELECT provider_id, app_type, provider_name,
               SUM(request_count), SUM(total_tokens), SUM(total_cost), SUM(success_count),
               SUM(latency_sum),
               SUM(speed_output), SUM(speed_gen_ms), SUM(est_output), SUM(est_ms)
        FROM (
            SELECT l.provider_id, l.app_type, \(Self.providerNameCoalesce) AS provider_name,
                   COUNT(*) AS request_count,
                   COALESCE(SUM(\(realTotalTokens(db, "l"))), 0) AS total_tokens,
                   COALESCE(SUM(\(costL(db))), 0) AS total_cost,
                   COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END), 0) AS success_count,
                   COALESCE(SUM(l.latency_ms), 0) AS latency_sum,
                   \(Self.speedSumsL)
            FROM proxy_request_logs l
            \(Self.providersJoinL)
            \(detailWhere)
            GROUP BY l.provider_id, l.app_type
            UNION ALL
            SELECT r.provider_id, r.app_type, \(Self.providerNameSQL(log: "r", provider: "p2")),
                   COALESCE(SUM(r.request_count), 0),
                   COALESCE(SUM(\(realTotalTokens(db, "r"))), 0),
                   COALESCE(SUM(\(costR(db))), 0),
                   COALESCE(SUM(r.success_count), 0),
                   COALESCE(SUM(r.avg_latency_ms * r.request_count), 0),
                   0, 0, 0, 0
            FROM usage_daily_rollups r
            \(Self.providersJoin(log: "r", provider: "p2"))
            \(rollupWhere)
            GROUP BY r.provider_id, r.app_type
        )
        GROUP BY provider_id, app_type
        ORDER BY SUM(total_cost) DESC
        """
        // 分组键用不会出现在 id 里的 0x1F 拼接，和主查询的 (provider_id, app_type) 对上
        let medianKey = "l.provider_id || char(31) || l.app_type"
        let medianFrom = "FROM proxy_request_logs l \(Self.providersJoinL)"
        let exact = try firstTokenSamples(db, key: medianKey, from: medianFrom, where: detailWhere,
                                          binds: detailBinds, eligible: Self.firstTokenEligibleL)
        var estimated = try firstTokenSamples(db, key: medianKey, from: medianFrom, where: detailWhere,
                                              binds: detailBinds, eligible: Self.estFirstTokenEligibleL)
        // 增量行按 (provider, app) 汇总，与库内行同一套身份。OMP 日志里混着多家 provider，必须分组累加——
        // 同名 provider 在库里属于别的应用时也要分开。估出来的首字先并进样本，再统一取中位数。
        var overlay = OverlayStats.group(overlayLogRows(db, f)) { "\($0.providerId)\u{1F}\($0.appType)" }
        let hasOverlay = !overlay.isEmpty
        OverlayStats.mergeFirstTokens(of: overlay, into: &estimated)

        let stmt = try prepare(db, sql, detailBinds + rollupBinds)
        defer { sqlite3_finalize(stmt) }
        var out: [ProviderStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let providerId = SQLite.text(stmt, 0)
            let appType = SQLite.text(stmt, 1)
            let key = "\(providerId)\u{1F}\(appType)"
            let ov = overlay.removeValue(forKey: key) ?? OverlayStats.Group()
            let requests = sqlite3_column_int64(stmt, 3) + ov.requests
            var performance = Self.readPerformance(stmt, from: 8, exact: exact[key].map(OverlayStats.median),
                                                   estimated: estimated[key].map(OverlayStats.median))
            ov.addEstimatedSpeed(to: &performance)
            out.append(ProviderStatRow(
                providerId: providerId,
                appType: appType,
                providerName: SQLite.text(stmt, 2),
                requestCount: requests,
                totalTokens: sqlite3_column_int64(stmt, 4) + ov.tokens,
                totalCost: sqlite3_column_double(stmt, 5) + ov.cost,
                successRate: Self.successRate(sqlite3_column_int64(stmt, 6) + ov.successes, of: requests),
                avgLatencyMs: Self.averageLatency(sqlite3_column_int64(stmt, 7) + ov.latencySum, of: requests),
                performance: performance
            ))
        }
        // 只有叠加行的分组
        for (key, ov) in overlay {
            var performance = StatsPerformance()
            performance.estFirstTokenMedianMs = estimated[key].map(OverlayStats.median)
            ov.addEstimatedSpeed(to: &performance)
            out.append(ProviderStatRow(providerId: ov.providerId, appType: ov.appType, providerName: ov.providerName,
                                       requestCount: ov.requests, totalTokens: ov.tokens, totalCost: ov.cost,
                                       successRate: Self.successRate(ov.successes, of: ov.requests),
                                       avgLatencyMs: Self.averageLatency(ov.latencySum, of: ov.requests),
                                       performance: performance))
        }
        if hasOverlay { out.sort { $0.totalCost > $1.totalCost } }
        return out
    }

    /// 模型统计。对齐 get_model_stats（v4.0.12）：明细与整日 rollup UNION ALL 后按有效计价模型汇总，
    /// total_tokens = 真实消耗，avg = total_cost / request_count，带成功率（v4 前端必填）与速度、首字。
    public func modelStats(_ f: LogQueryFilter, calendar: Calendar = .current) throws -> [ModelStatRow] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let (detailWhere, detailBinds) = statsWhere(db, f)
        let (rollupWhere, rollupBinds) = rollupStatsWhere(f, calendar)
        let sql = """
        SELECT model, SUM(request_count), SUM(total_tokens), SUM(total_cost), SUM(success_count),
               SUM(speed_output), SUM(speed_gen_ms), SUM(est_output), SUM(est_ms)
        FROM (
            SELECT \(Self.effectiveModelL) AS model,
                   COUNT(*) AS request_count,
                   COALESCE(SUM(\(realTotalTokens(db, "l"))), 0) AS total_tokens,
                   COALESCE(SUM(\(costL(db))), 0) AS total_cost,
                   COALESCE(SUM(CASE WHEN l.status_code >= 200 AND l.status_code < 300 THEN 1 ELSE 0 END), 0) AS success_count,
                   \(Self.speedSumsL)
            FROM proxy_request_logs l
            \(Self.providersJoinL)
            \(detailWhere)
            GROUP BY \(Self.effectiveModelL)
            UNION ALL
            SELECT \(Self.effectiveModelR),
                   COALESCE(SUM(r.request_count), 0),
                   COALESCE(SUM(\(realTotalTokens(db, "r"))), 0),
                   COALESCE(SUM(\(costR(db))), 0),
                   COALESCE(SUM(r.success_count), 0),
                   0, 0, 0, 0
            FROM usage_daily_rollups r
            \(Self.providersJoin(log: "r", provider: "p2"))
            \(rollupWhere)
            GROUP BY \(Self.effectiveModelR)
        )
        GROUP BY model
        ORDER BY SUM(total_cost) DESC
        """
        let medianFrom = "FROM proxy_request_logs l \(Self.providersJoinL)"
        let exact = try firstTokenSamples(db, key: Self.effectiveModelL, from: medianFrom, where: detailWhere,
                                          binds: detailBinds, eligible: Self.firstTokenEligibleL)
        var estimated = try firstTokenSamples(db, key: Self.effectiveModelL, from: medianFrom, where: detailWhere,
                                              binds: detailBinds, eligible: Self.estFirstTokenEligibleL)
        // 未入库增量按模型汇总：叠加行 pricing_model 为空，有效计价模型就是 model（与库内会话行同口径）
        var overlay = OverlayStats.group(overlayLogRows(db, f)) { $0.model }
        let hasOverlay = !overlay.isEmpty
        OverlayStats.mergeFirstTokens(of: overlay, into: &estimated)

        let stmt = try prepare(db, sql, detailBinds + rollupBinds)
        defer { sqlite3_finalize(stmt) }
        var out: [ModelStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = SQLite.text(stmt, 0)
            let ov = overlay.removeValue(forKey: model) ?? OverlayStats.Group()
            let requests = sqlite3_column_int64(stmt, 1) + ov.requests
            let totalCost = sqlite3_column_double(stmt, 3) + ov.cost
            var performance = Self.readPerformance(stmt, from: 5, exact: exact[model].map(OverlayStats.median),
                                                   estimated: estimated[model].map(OverlayStats.median))
            ov.addEstimatedSpeed(to: &performance)
            out.append(ModelStatRow(
                model: model,
                requestCount: requests,
                totalTokens: sqlite3_column_int64(stmt, 2) + ov.tokens,
                totalCost: totalCost,
                avgCostPerRequest: requests > 0 ? totalCost / Double(requests) : 0,
                successRate: Self.successRate(sqlite3_column_int64(stmt, 4) + ov.successes, of: requests),
                performance: performance
            ))
        }
        // 只有叠加行的模型
        for (model, ov) in overlay {
            var performance = StatsPerformance()
            performance.estFirstTokenMedianMs = estimated[model].map(OverlayStats.median)
            ov.addEstimatedSpeed(to: &performance)
            out.append(ModelStatRow(model: model, requestCount: ov.requests, totalTokens: ov.tokens,
                                    totalCost: ov.cost,
                                    avgCostPerRequest: ov.requests > 0 ? ov.cost / Double(ov.requests) : 0,
                                    successRate: Self.successRate(ov.successes, of: ov.requests),
                                    performance: performance))
        }
        if hasOverlay { out.sort { $0.totalCost > $1.totalCost } }
        return out
    }

    // MARK: - 统计小工具

    /// rollups 侧 WHERE：整日边界 → app → provider → 模型（provider 筛选靠 p2 联表，两张统计都恒带）。
    private func rollupStatsWhere(_ f: LogQueryFilter, _ cal: Calendar) -> (String, [SQLBind]) {
        let scope = UsageFilter(start: f.start, end: f.end, appType: f.appType,
                                providerName: f.providerName, model: f.model)
        let (conds, binds) = rollupConds(scope, Self.rollupDateBounds(f.start, f.end, cal))
        return (conds.isEmpty ? "" : "WHERE " + conds.joined(separator: " AND "), binds)
    }

    /// 按分组键取首字样本，各组升序（对齐 first_token_medians 的取数部分）。首字长尾明显，偶尔一次排队就十几秒，
    /// 所以用中位数不用平均；SQLite 没有中位数函数，按键、值排好序取出来，并进叠加行的样本以后再用 median 算。
    /// `whereClause` 是统计查询明细部分的 WHERE（恒非空：首条是跨源去重），`binds` 是它的参数。
    func firstTokenSamples(_ db: OpaquePointer, key: String, from: String, where whereClause: String,
                           binds: [SQLBind], eligible: String) throws -> [String: [Int64]] {
        let sql = "SELECT \(key) AS k, l.first_token_ms \(from) \(whereClause) AND \(eligible) ORDER BY k, l.first_token_ms"
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }
        var grouped: [String: [Int64]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            grouped[SQLite.text(stmt, 0), default: []].append(max(0, sqlite3_column_int64(stmt, 1)))
        }
        return grouped
    }

    /// 成功率（百分比）。请求数为 0 时为 0（同上游）。
    static func successRate(_ successes: Int64, of requests: Int64) -> Double {
        requests > 0 ? Double(successes) / Double(requests) * 100 : 0
    }

    /// 平均耗时：耗时之和整除请求数，请求数为 0 时为 0（同上游的 SQL 写法）。
    static func averageLatency(_ sum: Int64, of requests: Int64) -> Int64 {
        requests > 0 ? sum / requests : 0
    }

    /// 从主查询第 `c` 列起读四个速度累计列，配上两组首字中位数。
    static func readPerformance(_ stmt: OpaquePointer?, from c: Int32,
                                exact: Int64?, estimated: Int64?) -> StatsPerformance {
        var p = StatsPerformance()
        p.speedOutputTokens = max(0, sqlite3_column_int64(stmt, c))
        p.speedGenerationMs = max(0, sqlite3_column_int64(stmt, c + 1))
        p.estSpeedOutputTokens = max(0, sqlite3_column_int64(stmt, c + 2))
        p.estSpeedDurationMs = max(0, sqlite3_column_int64(stmt, c + 3))
        p.firstTokenMedianMs = exact
        p.estFirstTokenMedianMs = estimated
        return p
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
        WHERE \(effectiveUsageFilter(db))
        GROUP BY ds
        """
        let stmt = try prepare(db, sql)
        defer { sqlite3_finalize(stmt) }

        var acc: [String: (req: Int64, cost: Double)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            acc[String(cString: c)] = (sqlite3_column_int64(stmt, 1),
                                       sqlite3_column_double(stmt, 2))
        }
        // 未入库增量按各自来源并入（SessionOverlay=session_log、OmpOverlay=omp_session，
        // 都与库内同名桶合并，入库后自动收敛）。
        for r in overlayRows(db, UsageFilter()) {
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
