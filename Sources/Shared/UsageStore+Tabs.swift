import Foundation
import SQLite3

/// requestLogs 的 SELECT 投影列序（早前 26 个位置索引散在映射代码里，改 SELECT 顺序即静默错位）。
private enum RequestLogCol: Int32 {
    case requestId, providerId, providerName, appType, model, requestModel, pricingModel, costMultiplier,
         inputTokens, outputTokens, cacheReadTokens, cacheCreationTokens,
         inputCost, outputCost, cacheReadCost, cacheCreationCost, totalCost,
         isStreaming, latencyMs, firstTokenMs, durationMs, statusCode, errorMessage, createdAt, dataSource,
         billableInput
}

extension UsageStore {
    // MARK: - Tabs 查询（Request Logs / Provider Stats / Model Stats）
    //
    // Request Logs 只能读 proxy_request_logs（rollup 没有逐行明细）；Provider / Model Stats 与上游
    // v4 一样把整日 rollup 也并进来，和 Hero 同口径，各行加起来等于顶部总数（早先三个 Tab 都只读明细，
    // 区间跨到 30 天前时两张统计表会比 Hero 少一截，2026-10-15 随主窗口升级 v4 用量页一起对齐）。
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

    /// 请求日志分页（created_at DESC）。对齐 get_request_logs（usage_stats.rs）。
    public func requestLogs(_ f: LogQueryFilter, page: Int, pageSize: Int) throws -> RequestLogPage {
        let db = try openRO()
        defer { sqlite3_close(db) }

        // 首条恒为跨源去重过滤，对齐 get_request_logs（usage_stats.rs:1554）。
        var conds: [String] = [effectiveUsageFilter(db)]
        var binds: [SQLBind] = []
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
        let cstmt = try prepare(db, countSQL, binds)
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
        // SELECT 投影列序 = RequestLogCol 的 case 顺序（改一处必须同步改另一处）
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
        let stmt = try prepare(db, sql, pageBinds)
        defer { sqlite3_finalize(stmt) }
        // 按名取列，列序由 RequestLogCol 与上面的 SELECT 投影共同约定
        func text(_ c: RequestLogCol) -> String { SQLite.text(stmt, c.rawValue) }
        func textOpt(_ c: RequestLogCol) -> String? { SQLite.textOpt(stmt, c.rawValue) }
        func int(_ c: RequestLogCol) -> Int64 { sqlite3_column_int64(stmt, c.rawValue) }
        func intOpt(_ c: RequestLogCol) -> Int64? { SQLite.intOpt(stmt, c.rawValue) }

        var rows: [RequestLogRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let mult = text(.costMultiplier)
            let inTok = int(.inputTokens)
            let outTok = int(.outputTokens)
            let crTok = int(.cacheReadTokens)
            let ccTok = int(.cacheCreationTokens)
            var costs = (input: text(.inputCost), output: text(.outputCost),
                         cacheRead: text(.cacheReadCost), cacheCreation: text(.cacheCreationCost),
                         total: text(.totalCost))
            // cc-switch 入库时查不到定价 → 成本写死 0,面板显示「未定价」。这里用
            // 内置表现场补算(只读,不改库);库里已有正成本的行原样保留。
            if (Double(costs.total) ?? 0) <= 0,
               inTok > 0 || outTok > 0 || crTok > 0 || ccTok > 0 {
                // 计价基准与 input 口径都走与 costSQL 同一套规则（占位符判定 +
                // billable input），否则同一行在 Hero 和明细表里会算出两个数。
                let effective = ModelPricing.resolvePricingModel(
                    pricingModel: textOpt(.pricingModel),
                    model: text(.model),
                    requestModel: textOpt(.requestModel))
                if let effective,
                   let b = ModelPricing.backfilledCosts(
                    model: effective, multiplier: Double(mult) ?? 1,
                    billableInput: int(.billableInput),
                    output: outTok, cacheRead: crTok, cacheCreation: ccTok) {
                    costs = b
                }
            }
            rows.append(RequestLogRow(
                requestId: text(.requestId),
                providerId: text(.providerId),
                providerName: text(.providerName),
                appType: text(.appType),
                model: text(.model),
                requestModel: textOpt(.requestModel),
                pricingModel: textOpt(.pricingModel),
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
                isStreaming: int(.isStreaming) != 0,
                latencyMs: int(.latencyMs),
                firstTokenMs: intOpt(.firstTokenMs),
                durationMs: intOpt(.durationMs),
                statusCode: Int(int(.statusCode)),
                errorMessage: textOpt(.errorMessage),
                createdAt: int(.createdAt),
                dataSource: textOpt(.dataSource)
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
                isStreaming: true, latencyMs: r.latencyMs, firstTokenMs: r.firstTokenMs, durationMs: nil,
                statusCode: 200, errorMessage: nil, createdAt: r.createdAt,
                dataSource: r.dataSource   // 与 dataSourceBreakdown 同一真值，不按 providerId 反推
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
        // 一股脑塞进 "Claude (Session)" 会把 grok 的花费记到 Claude 头上。估出来的首字先并进样本，再统一取中位数。
        var overlay = Self.groupOverlay(overlayLogRows(db, f)) { "\($0.providerId)\u{1F}\($0.appType)" }
        let hasOverlay = !overlay.isEmpty
        Self.mergeFirstTokens(of: overlay, into: &estimated)

        let stmt = try prepare(db, sql, detailBinds + rollupBinds)
        defer { sqlite3_finalize(stmt) }
        var out: [ProviderStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let providerId = SQLite.text(stmt, 0)
            let appType = SQLite.text(stmt, 1)
            let key = "\(providerId)\u{1F}\(appType)"
            let ov = overlay.removeValue(forKey: key) ?? OverlayStatsGroup()
            let requests = sqlite3_column_int64(stmt, 3) + ov.requests
            var performance = Self.readPerformance(stmt, from: 8, exact: exact[key].map(Self.median),
                                                   estimated: estimated[key].map(Self.median))
            ov.addEstimatedSpeed(to: &performance)
            out.append(ProviderStatRow(
                providerId: providerId,
                appType: appType,
                providerName: SQLite.text(stmt, 2),
                requestCount: requests,
                totalTokens: sqlite3_column_int64(stmt, 4) + ov.tokens,
                totalCost: sqlite3_column_double(stmt, 5) + ov.cost,
                successRate: Self.successRate(sqlite3_column_int64(stmt, 6) + ov.requests, of: requests),
                avgLatencyMs: Self.averageLatency(sqlite3_column_int64(stmt, 7) + ov.latencySum, of: requests),
                performance: performance
            ))
        }
        // 只有叠加行的分组
        for (key, ov) in overlay {
            var performance = StatsPerformance()
            performance.estFirstTokenMedianMs = estimated[key].map(Self.median)
            ov.addEstimatedSpeed(to: &performance)
            out.append(ProviderStatRow(providerId: ov.providerId, appType: ov.appType, providerName: ov.providerName,
                                       requestCount: ov.requests, totalTokens: ov.tokens, totalCost: ov.cost,
                                       successRate: Self.successRate(ov.requests, of: ov.requests),
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
        var overlay = Self.groupOverlay(overlayLogRows(db, f)) { $0.model }
        let hasOverlay = !overlay.isEmpty
        Self.mergeFirstTokens(of: overlay, into: &estimated)

        let stmt = try prepare(db, sql, detailBinds + rollupBinds)
        defer { sqlite3_finalize(stmt) }
        var out: [ModelStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let model = SQLite.text(stmt, 0)
            let ov = overlay.removeValue(forKey: model) ?? OverlayStatsGroup()
            let requests = sqlite3_column_int64(stmt, 1) + ov.requests
            let totalCost = sqlite3_column_double(stmt, 3) + ov.cost
            var performance = Self.readPerformance(stmt, from: 5, exact: exact[model].map(Self.median),
                                                   estimated: estimated[model].map(Self.median))
            ov.addEstimatedSpeed(to: &performance)
            out.append(ModelStatRow(
                model: model,
                requestCount: requests,
                totalTokens: sqlite3_column_int64(stmt, 2) + ov.tokens,
                totalCost: totalCost,
                avgCostPerRequest: requests > 0 ? totalCost / Double(requests) : 0,
                successRate: Self.successRate(sqlite3_column_int64(stmt, 4) + ov.requests, of: requests),
                performance: performance
            ))
        }
        // 只有叠加行的模型
        for (model, ov) in overlay {
            var performance = StatsPerformance()
            performance.estFirstTokenMedianMs = estimated[model].map(Self.median)
            ov.addEstimatedSpeed(to: &performance)
            out.append(ModelStatRow(model: model, requestCount: ov.requests, totalTokens: ov.tokens,
                                    totalCost: ov.cost,
                                    avgCostPerRequest: ov.requests > 0 ? ov.cost / Double(ov.requests) : 0,
                                    successRate: Self.successRate(ov.requests, of: ov.requests),
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
        let (conds, binds) = rollupConds(scope, rollupDateBounds(f.start, f.end, cal))
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

    /// 已升序的一组数的中位数：奇数个取中间，偶数个取中间两个的整除平均（同上游）。
    static func median(_ sorted: [Int64]) -> Int64 {
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// 成功率（百分比）。请求数为 0 时为 0（同上游）。
    static func successRate(_ successes: Int64, of requests: Int64) -> Double {
        requests > 0 ? Double(successes) / Double(requests) * 100 : 0
    }

    /// 平均耗时：耗时之和整除请求数，请求数为 0 时为 0（同上游的 SQL 写法）。
    static func averageLatency(_ sum: Int64, of requests: Int64) -> Int64 {
        requests > 0 ? sum / requests : 0
    }

    /// 叠加行按统计表的行身份汇总。叠加行恒 200，全部计入成功；计时是叠加层现场估的（或 OMP 自己记的），
    /// 非路由来源一律按估算口径：耗时之和进平均耗时；够门槛的（输出 ≥ 200、耗时 ≥ 1s，同 speedEstimateEligibleL）
    /// 进估算速度；推出了首字的进估算首字中位数（同 estFirstTokenEligibleL）。没有计时的行（耗时 0）只算请求数、
    /// Tokens、成本，平均耗时里按 0 计——与库里没有计时的行同一口径。
    struct OverlayStatsGroup {
        /// 供应商分组用的身份与展示名，取这组第一条叠加行的。
        var providerId = ""
        var appType = ""
        var providerName = ""
        var requests: Int64 = 0
        var tokens: Int64 = 0
        var cost: Double = 0
        var latencySum: Int64 = 0
        var estOutputTokens: Int64 = 0
        var estDurationMs: Int64 = 0
        var firstTokens: [Int64] = []

        mutating func add(_ r: OverlayRow) {
            requests += 1
            tokens += r.realTotalTokens
            cost += r.totalCost
            latencySum += r.latencyMs
            if r.output >= UsageStore.speedEstimateMinOutputTokens,
               r.latencyMs >= UsageStore.speedEstimateMinDurationMs {
                estOutputTokens += r.output
                estDurationMs += r.latencyMs
            }
            if let ms = r.firstTokenMs { firstTokens.append(max(0, ms)) }
        }

        func addEstimatedSpeed(to performance: inout StatsPerformance) {
            performance.estSpeedOutputTokens += estOutputTokens
            performance.estSpeedDurationMs += estDurationMs
        }
    }

    static func groupOverlay(_ rows: [OverlayRow],
                             by key: (OverlayRow) -> String) -> [String: OverlayStatsGroup] {
        var groups: [String: OverlayStatsGroup] = [:]
        for r in rows {
            let k = key(r)
            var g = groups[k] ?? OverlayStatsGroup(providerId: r.providerId, appType: r.appType,
                                                   providerName: r.providerName)
            g.add(r)
            groups[k] = g
        }
        return groups
    }

    /// 叠加行估出的首字并进估算首字的样本，各组重新排好序，之后统一取中位数。
    static func mergeFirstTokens(of groups: [String: OverlayStatsGroup], into samples: inout [String: [Int64]]) {
        for (key, g) in groups where !g.firstTokens.isEmpty {
            var merged = samples[key] ?? []
            merged.append(contentsOf: g.firstTokens)
            merged.sort()
            samples[key] = merged
        }
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
        // 未入库增量按各自来源并入（SessionOverlay=session_log 会与库内同名桶合并，
        // 补录后自动收敛；OmpOverlay=omp_session 单列）。
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
