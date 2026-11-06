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

/// requestLogSelect 一行的按名取列（列序由 RequestLogCol 与投影共同约定）。
private struct RequestLogColumns {
    let stmt: OpaquePointer?
    func text(_ c: RequestLogCol) -> String { SQLite.text(stmt, c.rawValue) }
    func textOpt(_ c: RequestLogCol) -> String? { SQLite.textOpt(stmt, c.rawValue) }
    func int(_ c: RequestLogCol) -> Int64 { sqlite3_column_int64(stmt, c.rawValue) }
    func intOpt(_ c: RequestLogCol) -> Int64? { SQLite.intOpt(stmt, c.rawValue) }
}

extension UsageStore {
    // MARK: - Request Logs
    //
    // 只能读 proxy_request_logs（rollup 没有逐行明细）。跨源去重同样必须套用，理由见 UsageStore+Stats 文件头。

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
        defer { sqlite3_finalize(cstmt) }
        if try stepRow(cstmt, countSQL) { total = Int(sqlite3_column_int64(cstmt, 0)) }

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
        let sql = "\(requestLogSelect(db)) \(whereClause) ORDER BY l.created_at DESC LIMIT ?"
        let stmt = try prepare(db, sql, pageBinds)
        defer { sqlite3_finalize(stmt) }
        var rows: [RequestLogRow] = []
        while try stepRow(stmt, sql) {
            rows.append(readRequestLogRow(stmt))
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

        let ovRows = ov.sorted { $0.createdAt > $1.createdAt }.prefix(need).map(Self.overlayRequestLogRow)

        let merged = RequestLogMerge.merged(rows, ovRows, limit: need)
        return RequestLogPage(rows: Array(merged.dropFirst(offset)), total: total)
    }

    /// 单条请求（详情抽屉）。对齐 get_request_detail（usage_stats.rs）：按 request_id 直查明细、成本照列表一样
    /// 补算、不套跨源去重；库里没有就找还没入库的叠加行。都没有返回 nil，前端显示「Request not found」。
    public func requestDetail(_ requestId: String) throws -> RequestLogRow? {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let sql = "\(requestLogSelect(db)) WHERE l.request_id = ?"
        let stmt = try prepare(db, sql, [.text(requestId)])
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            return readRequestLogRow(stmt)
        case SQLITE_DONE:
            return overlayRows(db, UsageFilter()).first { $0.requestId == requestId }
                .map(Self.overlayRequestLogRow)
        case let rc:
            // 查询出错不能当「没有这条」：抛给桥接层，前端显示可重试的错误
            throw UsageStoreError.step(rc, sql)
        }
    }

    /// requestLogs / requestDetail 共用的 SELECT 投影，后面接 WHERE。列序 = RequestLogCol 的 case 顺序
    /// （改一处必须同步改另一处）。
    private func requestLogSelect(_ db: OpaquePointer) -> String {
        """
        SELECT l.request_id, l.provider_id, \(Self.providerNameCoalesce) AS provider_name, l.app_type, l.model,
               l.request_model, l.pricing_model, l.cost_multiplier,
               l.input_tokens, l.output_tokens, l.cache_read_tokens, l.cache_creation_tokens,
               l.input_cost_usd, l.output_cost_usd, l.cache_read_cost_usd, l.cache_creation_cost_usd, l.total_cost_usd,
               l.is_streaming, l.latency_ms, l.first_token_ms, l.duration_ms,
               l.status_code, l.error_message, l.created_at, l.data_source,
               \(ModelPricing.billableInputSQL("l", hasSemantics: hasSemantics(db))) AS billable_input
        FROM proxy_request_logs l
        \(Self.providersJoinL)
        """
    }

    /// requestLogSelect 的当前一行 → RequestLogRow。
    private func readRequestLogRow(_ stmt: OpaquePointer?) -> RequestLogRow {
        let col = RequestLogColumns(stmt: stmt)
        let mult = col.text(.costMultiplier)
        let costs = requestLogCosts(col)
        return RequestLogRow(
            requestId: col.text(.requestId),
            providerId: col.text(.providerId),
            providerName: col.text(.providerName),
            appType: col.text(.appType),
            model: col.text(.model),
            requestModel: col.textOpt(.requestModel),
            pricingModel: col.textOpt(.pricingModel),
            costMultiplier: mult.isEmpty ? "1" : mult,
            inputTokens: col.int(.inputTokens),
            outputTokens: col.int(.outputTokens),
            cacheReadTokens: col.int(.cacheReadTokens),
            cacheCreationTokens: col.int(.cacheCreationTokens),
            inputCostUsd: costs.input,
            outputCostUsd: costs.output,
            cacheReadCostUsd: costs.cacheRead,
            cacheCreationCostUsd: costs.cacheCreation,
            totalCostUsd: costs.total,
            isStreaming: col.int(.isStreaming) != 0,
            latencyMs: col.int(.latencyMs),
            firstTokenMs: col.intOpt(.firstTokenMs),
            durationMs: col.intOpt(.durationMs),
            statusCode: Int(col.int(.statusCode)),
            errorMessage: col.textOpt(.errorMessage),
            createdAt: col.int(.createdAt),
            dataSource: col.textOpt(.dataSource)
        )
    }

    /// 这一行的五项成本。cc-switch 入库时查不到定价 → 成本写死 0,面板显示「未定价」:这里用
    /// 内置表现场补算(只读,不改库);库里已有正成本的行原样保留。
    private func requestLogCosts(_ col: RequestLogColumns)
        -> (input: String, output: String, cacheRead: String, cacheCreation: String, total: String) {
        let stored = (input: col.text(.inputCost), output: col.text(.outputCost),
                      cacheRead: col.text(.cacheReadCost), cacheCreation: col.text(.cacheCreationCost),
                      total: col.text(.totalCost))
        let inTok = col.int(.inputTokens), outTok = col.int(.outputTokens)
        let crTok = col.int(.cacheReadTokens), ccTok = col.int(.cacheCreationTokens)
        guard (Double(stored.total) ?? 0) <= 0, inTok > 0 || outTok > 0 || crTok > 0 || ccTok > 0 else { return stored }
        // 计价基准与 input 口径都走与 costSQL 同一套规则（占位符判定 +
        // billable input），否则同一行在 Hero 和明细表里会算出两个数。
        guard let effective = ModelPricing.resolvePricingModel(
                pricingModel: col.textOpt(.pricingModel), model: col.text(.model),
                requestModel: col.textOpt(.requestModel)),
              let backfilled = ModelPricing.backfilledCosts(
                model: effective, multiplier: Double(col.text(.costMultiplier)) ?? 1,
                billableInput: col.int(.billableInput),
                output: outTok, cacheRead: crTok, cacheCreation: ccTok) else { return stored }
        return backfilled
    }

    /// 叠加行 → RequestLogRow：provider、状态码、错误信息都是行自带的（SessionOverlay 恒 200；OmpOverlay
    /// 照上游有 499 / 500），计时是叠加层现场估的（SessionOverlay）或 OMP 自己记的（OmpOverlay），没有计时时
    /// latencyMs 0、firstTokenMs nil，与库里的约定相同。
    static func overlayRequestLogRow(_ r: OverlayRow) -> RequestLogRow {
        RequestLogRow(
            requestId: r.requestId, providerId: r.providerId,
            providerName: r.providerName, appType: r.appType,
            model: r.model, requestModel: r.requestModel ?? r.model, pricingModel: nil,
            costMultiplier: "1.0",
            inputTokens: r.input, outputTokens: r.output,
            cacheReadTokens: r.cacheRead, cacheCreationTokens: r.cacheCreation,
            inputCostUsd: Fmt.usd6(r.inputCost), outputCostUsd: Fmt.usd6(r.outputCost),
            cacheReadCostUsd: Fmt.usd6(r.cacheReadCost), cacheCreationCostUsd: Fmt.usd6(r.cacheCreationCost),
            totalCostUsd: Fmt.usd6(r.totalCost),
            isStreaming: true, latencyMs: r.latencyMs, firstTokenMs: r.firstTokenMs, durationMs: nil,
            statusCode: Int(r.statusCode), errorMessage: r.errorMessage, createdAt: r.createdAt,
            dataSource: r.dataSource   // 与 dataSourceBreakdown 同一真值，不按 providerId 反推
        )
    }
}
