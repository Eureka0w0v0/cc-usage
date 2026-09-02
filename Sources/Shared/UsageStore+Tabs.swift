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
    // 全部只读 proxy_request_logs（与 Hero/Chart 同源，忽略 usage_daily_rollups——
    // 本机 rollup 里的历史 codex 数据不在明细表，Request Logs 无法逐行展示，故三个 Tab
    // 统一以明细表为准，保证与用户已看到的 Hero 数字自洽）。SQL 片段逐一复刻
    // usage_stats.rs（alias 固定 l = proxy_request_logs，p = providers）。
    // 跨源去重过滤（effective_usage_log_filter）在三个 Tab 里同样必须套用：早前以
    // 「本机无 'proxy' 行 → 空操作」为由略去，但那是环境事实不是语义结论——用户一旦
    // 打开 cc-switch 的代理，同一笔请求既落 proxy 又落 session_log，Hero 去重而 Tab
    // 不去重就会当场自相矛盾（Hero 总额 ≠ Σ Provider Stats，重复行还直接列在日志里）。

    // provider / model 统计共用的 WHERE + 绑定参数（时间窗 + app + provider + model）。
    // 首条恒为跨源去重过滤，对齐 get_provider_stats / get_model_stats（usage_stats.rs
    // :1265 / :1409，两者都以 vec![effective_usage_log_filter("l")] 起头）。
    private func statsWhere(_ f: LogQueryFilter) -> (String, [SQLBind]) {
        let (conds, binds) = logConds(UsageFilter(start: f.start, end: f.end, appType: f.appType,
                                                  providerName: f.providerName, model: f.model))
        return ("WHERE " + conds.joined(separator: " AND "), binds)
    }

    /// 请求日志分页（created_at DESC）。对齐 get_request_logs（usage_stats.rs）。
    public func requestLogs(_ f: LogQueryFilter, page: Int, pageSize: Int) throws -> RequestLogPage {
        let db = try openRO()
        defer { sqlite3_close(db) }

        // 首条恒为跨源去重过滤，对齐 get_request_logs（usage_stats.rs:1554）。
        var conds: [String] = [Self.effectiveUsageFilterL]
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
                isStreaming: true, latencyMs: 0, firstTokenMs: nil, durationMs: nil,
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
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }

        var out: [ProviderStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reqCount = sqlite3_column_int64(stmt, 2)
            let success = sqlite3_column_int64(stmt, 5)
            let rate = reqCount > 0 ? (Double(success) / Double(reqCount)) * 100.0 : 0.0
            out.append(ProviderStatRow(
                providerId: SQLite.text(stmt, 0),
                providerName: SQLite.text(stmt, 1),
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
        let stmt = try prepare(db, sql, binds)
        defer { sqlite3_finalize(stmt) }

        var out: [ModelStatRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let reqCount = sqlite3_column_int64(stmt, 1)
            let totalCost = sqlite3_column_double(stmt, 3)
            let avg = reqCount > 0 ? totalCost / Double(reqCount) : 0.0
            out.append(ModelStatRow(
                model: SQLite.text(stmt, 0),
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
