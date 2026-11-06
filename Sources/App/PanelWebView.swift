import SwiftUI
import WebKit
import os

/// 真·1:1 面板:加载打包好的 cc-switch 真实前端(web-panel/index.html)。
/// 前端调用的 Tauri `invoke(cmd,args)` 通过 WKScriptMessageHandlerWithReply 桥接到这里，
/// 由 Swift 读 ~/.cc-switch/cc-switch.db 返回数据。字段名对齐 cc-switch(camelCase)。
struct PanelWebView: NSViewRepresentable {
    let store: UsageStore
    /// embed 面板改了刷新间隔（set_setting refreshIntervalMs）时回调，宿主拿去同步菜单栏节奏。
    /// 回调注入，而不是让桥接层反向认识 PanelModel（早前靠 static weak var shared 这条全局暗线）。
    var onRefreshIntervalChanged: @MainActor (Int) -> Void = { _ in }

    func makeCoordinator() -> Bridge { Bridge(store: store, onRefreshIntervalChanged: onRefreshIntervalChanged) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 不开 allowFileAccessFromFileURLs / allowUniversalAccessFromFileURLs（KVC 私有键）：
        // 面板是单文件 index.html（JS/CSS/字体全内联），数据全走 message handler，
        // 无 file:// 跨文件/跨源访问需求——少开一扇门，也免私有键在系统更新后悄悄失效。
        // JS: window.webkit.messageHandlers.invoke.postMessage({cmd,args}) → 返回 Promise
        config.userContentController.addScriptMessageHandler(
            context.coordinator, contentWorld: .page, name: "invoke")
        // 前端 window.onerror / unhandledrejection 往 embedError 报错（index-embed.html）。
        // 没有这个 handler，面板白屏 / JS 异常就在 WKWebView 里静默吞掉，无从排查。
        config.userContentController.add(context.coordinator, contentWorld: .page, name: "embedError")

        // 顶部留白改由 embed 最外层 wrapper 的 paddingTop 负责（usage-embed.tsx，可靠避开交通灯）。
        // 不再注入 `#root{padding-top}`：实测被 index.css / 时序覆盖不生效，且会与 embed padding 叠加。

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .clear
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// 主窗每次关开都新建 WKWebView + Bridge；按惯例显式解注册，不留 handler 挂在死配置上。
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Bridge) {
        let ucc = nsView.configuration.userContentController
        ucc.removeScriptMessageHandler(forName: "invoke", contentWorld: .page)
        ucc.removeScriptMessageHandler(forName: "embedError", contentWorld: .page)
    }

    // MARK: - invoke 桥接

    final class Bridge: NSObject, WKScriptMessageHandlerWithReply, WKScriptMessageHandler {
        private let store: UsageStore
        private let onRefreshIntervalChanged: @MainActor (Int) -> Void
        private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "embed")

        init(store: UsageStore, onRefreshIntervalChanged: @escaping @MainActor (Int) -> Void) {
            self.store = store
            self.onRefreshIntervalChanged = onRefreshIntervalChanged
            super.init()
        }
        /// SQL/overlay 扫描全部下放到这条并发队列（UsageStore 每次查询独立连接、线程安全），
        /// 主线程只收发消息——面板高频刷新不再与 UI 抢主线程。
        private static let workQueue = DispatchQueue(
            label: "cc-usage.bridge", qos: .userInitiated, attributes: .concurrent)
        /// 桥接层拒绝请求时回给前端的错误（catch 分支会把它字符串化进 replyHandler）。
        struct Err: LocalizedError {
            let msg: String
            init(_ m: String) { msg = m }
            var errorDescription: String? { msg }
        }

        /// embedError：前端运行期错误，只记日志（`log stream --predicate 'subsystem == "com.ganxing.ccusage"'`）。
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "embedError" else { return }
            Self.log.error("panel JS error: \(String(describing: message.body), privacy: .public)")
        }

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
                    replyHandler(BridgePayload.quota(tiers), nil)
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

        private func handle(_ cmd: String, _ raw: [String: Any]) throws -> Any {
            let args = BridgeArgs(raw)

            switch cmd {
            // 三条 Hero/走势路径都要吃 providerName：上游 get_usage_summary / _by_app / get_daily_trends
            // 均按 provider 过滤；早前这里丢了它，工具栏选 Source 后 Hero 不动、三个 Tab 却动，同屏打架。
            case "get_usage_summary_by_app":
                return BridgePayload.summaryByApp(try store.summaryByApp(args.usageFilterAllApps))
            case "get_usage_trends":
                // 走 trendBuckets 而非 snapshot——后者顺带算的「区间 + 累计」4 次聚合在这条路径全是白算。
                return BridgePayload.trends(try store.trendBuckets(filter: args.usageFilter))
            // 热力图（embed/usage-heatmap.tsx）：最早有记录的本地日，决定铺几段 53 周。对齐 v4.0.5。
            case "get_usage_first_date":
                if let day = try store.firstUsageDate(args.scopeFilter) {
                    return day
                }
                return NSNull()
            case "get_usage_summary":
                return BridgePayload.summary(try store.rangeSummary(args.usageFilter))
            case "get_usage_data_sources":
                // 「按来源」只统计有 data_source 的明细行（rollups 无该列，不计入）。
                // 真按 data_source 分组——库里除 session_log 外还有 codex_session，
                // 升级 cc-switch 后还会出现 grok_session；旧实现把它们全贴成 session_log。
                // 与上游一样不吃时间窗（get_data_source_breakdown 是全表口径）。
                return BridgePayload.dataSources(try store.dataSourceBreakdown())

            // ── 下半部 Tabs：真查 proxy_request_logs（对齐 usage_stats.rs 字段/口径）──
            case "get_request_logs":
                let q = args.requestLogs
                let pageResult = try store.requestLogs(q.filter, page: q.page, pageSize: q.pageSize)
                return BridgePayload.requestLogs(pageResult, page: q.page, pageSize: q.pageSize)
            case "get_request_detail":
                // 入参：invoke("get_request_detail", { requestId })，点请求日志的一行打开详情抽屉时发。
                // 查不到回 null，前端显示「Request not found」；查询出错照常抛，前端显示可重试的错误。
                guard let requestId = args.nonEmptyString("requestId") else { return NSNull() }
                guard let row = try store.requestDetail(requestId) else { return NSNull() }
                return BridgePayload.requestLog(row)
            case "get_provider_stats":
                return try store.providerStats(args.statsFilter).map { BridgePayload.providerStat($0) }
            case "get_model_stats":
                return try store.modelStats(args.statsFilter).map { BridgePayload.modelStat($0) }

            // ── 面板设置持久化（embed 用）：UserDefaults，键加 "embed." 前缀。
            // refreshIntervalMs 额外写穿 PanelModel → 菜单栏与面板同一个刷新节奏，
            // 修复「面板选 5s 重开回 30s」与「菜单栏/面板更新时间不一致」。
            // 键名不走 BridgeArgs.filter——它会把 "all" 归一成 nil(那是筛选参数的语义),
            // 设置键/值必须原样透传。
            case "get_setting":
                guard let key = args.nonEmptyString("key") else { return NSNull() }
                return UserDefaults.standard.object(forKey: EmbedKey.setting(key)) ?? NSNull()
            case "set_setting":
                guard let key = args.nonEmptyString("key") else { return NSNull() }
                let value = raw["value"]
                let dkey = EmbedKey.setting(key)
                if value == nil || value is NSNull {
                    UserDefaults.standard.removeObject(forKey: dkey)
                } else if let v = value as? NSNumber {
                    UserDefaults.standard.set(v, forKey: dkey)
                } else if let v = value as? String {
                    UserDefaults.standard.set(v, forKey: dkey)
                } else {
                    // UserDefaults 只吃 plist 类型，喂进 NSNull（JS 的 [null] / {a:null}
                    // 桥接过来就是）会抛 ObjC 异常——Swift 捕获不了，整个进程当场终止。
                    // 面板真正用到的设置只有标量，其余一律拒绝，走既有错误路径回给前端。
                    throw Err("set_setting: unsupported value type for key \(key)")
                }
                if key == EmbedKey.refreshIntervalName, let ms = (value as? NSNumber)?.intValue {
                    let notify = onRefreshIntervalChanged
                    Task { @MainActor in notify(ms) }
                }
                return NSNull()
            // 上游 v4.0.20 的用量页和趋势图经 useSettingsQuery 读 settings：只给它认的两样——
            // usageDisplay（本应用自己存，页面经 set_setting("usageDisplay", JSON 字符串) 写）与
            // visibleApps（只读镜像 cc-switch 的 settings.json）。拼装与白名单见 EmbedSettings。
            case "get_settings":
                let settingsPath = (NSHomeDirectory() as NSString)
                    .appendingPathComponent(".cc-switch/settings.json")
                return EmbedSettings.compose(
                    usageDisplayJSON: UserDefaults.standard.string(forKey: EmbedKey.usageDisplay),
                    ccSwitchSettings: FileManager.default.contents(atPath: settingsPath))

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
    }
}
