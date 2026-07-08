import SwiftUI
import WebKit

/// 真·1:1 面板:加载打包好的 cc-switch 真实前端(web-panel/index.html)。
/// 前端调用的 Tauri `invoke(cmd,args)` 通过 WKScriptMessageHandlerWithReply 桥接到这里，
/// 由 Swift 读 ~/.cc-switch/cc-switch.db 返回数据。字段名对齐 cc-switch(camelCase)。
struct PanelWebView: NSViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 不开 allowFileAccessFromFileURLs / allowUniversalAccessFromFileURLs（KVC 私有键）：
        // 面板是单文件 index.html（JS/CSS/字体全内联），数据全走 message handler，
        // 无 file:// 跨文件/跨源访问需求——少开一扇门，也免私有键在系统更新后悄悄失效。
        // JS: window.webkit.messageHandlers.invoke.postMessage({cmd,args}) → 返回 Promise
        config.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "invoke")

        // 顶部留白改由 embed 最外层 wrapper 的 paddingTop 负责（usage-embed.tsx，可靠避开交通灯）。
        // 不再注入 `#root{padding-top}`：实测被 index.css / 时序覆盖不生效，且会与 embed padding 叠加。

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .clear
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: nil)
            ?? Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    // MARK: - invoke 桥接

    final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
        private let store = UsageStore()
        /// SQL/overlay 扫描全部下放到这条并发队列（UsageStore 每次查询独立连接、线程安全），
        /// 主线程只收发消息——面板高频刷新不再与 UI 抢主线程。
        private static let workQueue = DispatchQueue(
            label: "cc-usage.bridge", qos: .userInitiated, attributes: .concurrent)
        /// ISO8601DateFormatter 线程安全，静态复用（quotaJSON / trends 每 tick 都在调）。
        private static let iso = ISO8601DateFormatter()

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage,
                                   replyHandler: @escaping (Any?, String?) -> Void) {
            guard let body = message.body as? [String: Any],
                  let cmd = body["cmd"] as? String else {
                replyHandler(nil, "bad invoke payload"); return
            }
            let args = body["args"] as? [String: Any] ?? [:]

            // get_quota：走 QuotaService.fetchTiersForBridge()，其内部经 QuotaCache 缓存优先
            // （对齐 cc-switch：5 分钟节流窗口内只读进程内缓存，窗口外才打官方 /api/oauth/usage，
            // 失败/429 保留上次值）→ 从根上杜绝把官方接口打限流。失败/无凭据降级为 []，前端显示 "—"。
            // replyHandler 需在主线程回调，故 Task 标注 @MainActor（网络在 nonisolated fetch 内自行离开主线程）。
            if cmd == "get_quota" {
                Task { @MainActor in
                    let tiers = await QuotaService.fetchTiersForBridge()
                    replyHandler(Self.quotaJSON(tiers), nil)
                }
                return
            }

            // 其余命令：后台执行查询，主线程回填（replyHandler 的调用约定）
            Self.workQueue.async { [self] in
                do {
                    let result = try handle(cmd, args)
                    DispatchQueue.main.async { replyHandler(result, nil) }
                } catch {
                    DispatchQueue.main.async { replyHandler(nil, "\(error)") }
                }
            }
        }

        /// [QuotaTier] → 前端可消费、WKWebView 可序列化的 JSON：
        /// [{ name, utilization(0–100), resetsAt: ISO8601?, planLabel? }]。
        private static func quotaJSON(_ tiers: [QuotaTier]) -> [[String: Any]] {
            return tiers.map { t in
                [
                    "name": t.name,
                    "utilization": t.utilization,
                    "resetsAt": t.resetsAt.map { iso.string(from: $0) } ?? NSNull(),
                    "planLabel": t.planLabel ?? NSNull(),
                ]
            }
        }

        private func int64(_ v: Any?) -> Int64? {
            if let n = v as? NSNumber { return n.int64Value }
            if let d = v as? Double { return Int64(d) }
            if let s = v as? String { return Int64(s) }
            return nil
        }
        private func str(_ v: Any?) -> String? {
            if let s = v as? String, !s.isEmpty, s != "all" { return s }
            return nil
        }

        private func handle(_ cmd: String, _ args: [String: Any]) throws -> Any {
            let start = int64(args["startDate"])
            let end = int64(args["endDate"])
            let appType = str(args["appType"])
            let providerName = str(args["providerName"])
            let model = str(args["model"])

            switch cmd {
            case "get_usage_summary_by_app":
                return try summaryByApp(start: start, end: end, model: model)
            case "get_usage_trends":
                return try trends(start: start, end: end, appType: appType, model: model)
            case "get_usage_summary":
                let s = try store.rangeSummary(UsageFilter(start: start, end: end, appType: appType, model: model))
                return summaryDict(s)
            case "get_usage_data_sources":
                return try dataSources(start: start, end: end)

            // ── 下半部 Tabs：真查 proxy_request_logs（对齐 usage_stats.rs 字段/口径）──
            case "get_request_logs":
                // 入参形状：invoke("get_request_logs", { filters, page, pageSize })，
                // 时间窗被 useRequestLogs 合并进 filters（filters.startDate/endDate）。
                let filters = args["filters"] as? [String: Any] ?? [:]
                let page = Int(int64(args["page"]) ?? 0)
                let pageSize = Int(int64(args["pageSize"]) ?? 20)
                let f = LogQueryFilter(
                    start: int64(filters["startDate"]),
                    end: int64(filters["endDate"]),
                    appType: str(filters["appType"]),
                    providerName: str(filters["providerName"]),
                    model: str(filters["model"]),
                    statusCode: int64(filters["statusCode"]).map { Int($0) }
                )
                let pageResult = try store.requestLogs(f, page: page, pageSize: pageSize)
                return requestLogsDict(pageResult, page: page, pageSize: pageSize)
            case "get_provider_stats":
                let f = LogQueryFilter(start: start, end: end, appType: appType,
                                       providerName: providerName, model: model)
                return try store.providerStats(f).map { providerStatDict($0) }
            case "get_model_stats":
                let f = LogQueryFilter(start: start, end: end, appType: appType,
                                       providerName: providerName, model: model)
                return try store.modelStats(f).map { modelStatDict($0) }

            // ── 面板设置持久化（embed 用）：UserDefaults，键加 "embed." 前缀。
            // refreshIntervalMs 额外写穿 PanelModel → 菜单栏与面板同一个刷新节奏，
            // 修复「面板选 5s 重开回 30s」与「菜单栏/面板更新时间不一致」。
            // 键名不走 str()——它会把 "all" 归一成 nil(那是筛选参数的语义),
            // 设置键/值必须原样透传。
            case "get_setting":
                guard let key = args["key"] as? String, !key.isEmpty else { return NSNull() }
                return UserDefaults.standard.object(forKey: "embed.\(key)") ?? NSNull()
            case "set_setting":
                guard let key = args["key"] as? String, !key.isEmpty else { return NSNull() }
                let value = args["value"]
                if value == nil || value is NSNull {
                    UserDefaults.standard.removeObject(forKey: "embed.\(key)")
                } else {
                    UserDefaults.standard.set(value, forKey: "embed.\(key)")
                }
                if key == "refreshIntervalMs", let ms = (value as? NSNumber)?.intValue {
                    Task { @MainActor in PanelModel.shared?.applyEmbedRefreshInterval(ms: ms) }
                }
                return NSNull()

            // 次要命令(Pricing/Sync/Limits)—返回空/桩，面板未用
            case "get_model_pricing":
                return [[String: Any]]()
            case "sync_session_usage":
                return ["imported": 0, "skipped": 0, "filesScanned": 0, "errors": [String]()]
            case "check_provider_limits":
                return ["hasLimit": false]
            default:
                return NSNull()
            }
        }

        // MARK: - Tabs JSON 映射（camelCase，对齐 types/usage.ts）

        // RequestLogPage → PaginatedLogs{ data, total, page, pageSize }
        private func requestLogsDict(_ p: RequestLogPage, page: Int, pageSize: Int) -> [String: Any] {
            return [
                "data": p.rows.map { requestLogDict($0) },
                "total": p.total,
                "page": page,
                "pageSize": pageSize,
            ]
        }

        // RequestLogRow → RequestLog。可空字段仅在有值时写入（对齐 serde skip_serializing_if）。
        private func requestLogDict(_ r: RequestLogRow) -> [String: Any] {
            var d: [String: Any] = [
                "requestId": r.requestId,
                "providerId": r.providerId,
                "providerName": r.providerName,
                "appType": r.appType,
                "model": r.model,
                "costMultiplier": r.costMultiplier,
                "inputTokens": r.inputTokens,
                "outputTokens": r.outputTokens,
                "cacheReadTokens": r.cacheReadTokens,
                "cacheCreationTokens": r.cacheCreationTokens,
                "inputCostUsd": r.inputCostUsd,
                "outputCostUsd": r.outputCostUsd,
                "cacheReadCostUsd": r.cacheReadCostUsd,
                "cacheCreationCostUsd": r.cacheCreationCostUsd,
                "totalCostUsd": r.totalCostUsd,
                "isStreaming": r.isStreaming,
                "latencyMs": r.latencyMs,
                "statusCode": r.statusCode,
                "createdAt": r.createdAt,
            ]
            if let v = r.requestModel, !v.isEmpty { d["requestModel"] = v }
            if let v = r.pricingModel, !v.isEmpty { d["pricingModel"] = v }
            if let v = r.firstTokenMs { d["firstTokenMs"] = v }
            if let v = r.durationMs { d["durationMs"] = v }
            if let v = r.errorMessage, !v.isEmpty { d["errorMessage"] = v }
            if let v = r.dataSource, !v.isEmpty { d["dataSource"] = v }
            return d
        }

        // ProviderStatRow → ProviderStats
        private func providerStatDict(_ s: ProviderStatRow) -> [String: Any] {
            return [
                "providerId": s.providerId,
                "providerName": s.providerName,
                "requestCount": s.requestCount,
                "totalTokens": s.totalTokens,
                "totalCost": String(format: "%.6f", s.totalCost),
                "successRate": s.successRate,
                "avgLatencyMs": s.avgLatencyMs,
            ]
        }

        // ModelStatRow → ModelStats
        private func modelStatDict(_ s: ModelStatRow) -> [String: Any] {
            return [
                "model": s.model,
                "requestCount": s.requestCount,
                "totalTokens": s.totalTokens,
                "totalCost": String(format: "%.6f", s.totalCost),
                "avgCostPerRequest": String(format: "%.6f", s.avgCostPerRequest),
            ]
        }

        // 单个 summary → camelCase dict（对齐 types/usage.ts UsageSummary）
        private func summaryDict(_ s: UsageSummary) -> [String: Any] {
            return [
                "totalRequests": s.requests,
                "totalCost": String(format: "%.6f", s.cost),
                "totalInputTokens": s.input,
                "totalOutputTokens": s.output,
                "totalCacheCreationTokens": s.creation,
                "totalCacheReadTokens": s.hit,
                "successRate": 100.0,
                "realTotalTokens": s.tokensProcessed,
                "cacheHitRate": s.cacheHitRate,
            ]
        }

        // get_usage_summary_by_app → [{appType, summary}]（每个 app 一行）
        // 底层为 proxy_request_logs + usage_daily_rollups 两表合并的 GROUP BY app_type，
        // 故仅存在于历史聚合表的来源（如 codex）也会出现，且各 app 数字含历史。
        private func summaryByApp(start: Int64?, end: Int64?, model: String?) throws -> [[String: Any]] {
            let list = try store.summaryByApp(UsageFilter(start: start, end: end, model: model))
            return list.map { item in
                ["appType": item.appType, "summary": summaryDict(item.summary)]
            }
        }

        // get_usage_trends → DailyStats[]（date rfc3339 + 各 token/cost 字段，camelCase）。
        // 走 trendBuckets 而非 snapshot——后者顺带算的「区间 + 累计」4 次聚合在这条路径全是白算。
        private func trends(start: Int64?, end: Int64?, appType: String?, model: String?) throws -> [[String: Any]] {
            let buckets = try store.trendBuckets(
                filter: UsageFilter(start: start, end: end, appType: appType, model: model))
            let iso = Self.iso
            return buckets.map { b in
                return [
                    "date": iso.string(from: Date(timeIntervalSince1970: TimeInterval(b.startTs))),
                    "requestCount": b.requestCount,
                    "totalCost": String(format: "%.6f", b.cost),
                    "totalTokens": b.input + b.output,
                    "totalInputTokens": b.input,
                    "totalOutputTokens": b.output,
                    "totalCacheCreationTokens": b.creation,
                    "totalCacheReadTokens": b.hit,
                ]
            }
        }

        private func dataSources(start: Int64?, end: Int64?) throws -> [[String: Any]] {
            // 「按来源」只统计有 data_source 的明细行（rollups 无该列，不计入）。
            // 本机明细只有 session_log 一个来源。
            let s = try store.rangeSummaryLogsOnly(UsageFilter(start: start, end: end))
            return [[
                "dataSource": "session_log",
                "requestCount": s.requests,
                "totalCostUsd": String(format: "%.6f", s.cost),
            ]]
        }
    }
}
