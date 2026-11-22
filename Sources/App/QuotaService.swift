import Foundation
import os

// cc-usage-widget 官方订阅额度层：照搬 cc-switch `src-tauri/src/services/subscription.rs`
// 的 Claude 分支，读取 Claude Code 的 OAuth 凭据 → 调 Anthropic 官方用量端点
// → 解析出各限流窗口的真实 utilization%（而非拿 token 数除以占位额度猜）。
//
// 凭据来源（按优先级，与 cc-switch 一致）：
//   1. macOS Keychain: `security find-generic-password -s "Claude Code-credentials" -a $USER -w`，
//      没有可用的登录再不带 `-a` 查一次（同名条目可能只存了 MCP 登录，上游 #8764）
//   2. 文件: ~/.claude/.credentials.json
//   JSON 结构（两种 key 名都兼容）：
//   { "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms>, "subscriptionType": "..." } }
//
// 端点：GET https://api.anthropic.com/api/oauth/usage
//   Header: Authorization: Bearer <token>
//           anthropic-beta: oauth-2025-04-20
//           Accept: application/json
//   响应：{ "five_hour": {utilization, resets_at, ...}, "seven_day": {...},
//          "limits": [ {kind, group, percent, scope:{model:{display_name}}, ...}, ... ],
//          "extra_usage": {...}, ... }
//   其中 5 小时窗口 = "five_hour"，每周窗口 = "seven_day"（utilization 为 0–100）；
//   模型专属周限额（Fable/Opus/Sonnet）在新版里改走顶层 `limits[]`，用 `percent`。
//
// 响应体的解析规则全部在 `Sources/Shared/Quota/ClaudeQuotaParsing.swift`（纯函数，可测）；
// 本文件只负责凭据、网络与缓存。

// MARK: - 数据模型

// QuotaTier 定义见 Sources/Shared/Quota/ClaudeQuotaParsing.swift。

/// 这一轮查不到额度的原因（作为 Result 的 Failure，需符合 Error）。界面上保留上次的额度（首次是「—」），原因只进日志。
enum QuotaStatus: Error, Equatable, Sendable {
    case noCredential     // Keychain / 文件都读不到凭据
    case expired          // token 过期或鉴权失败(401/403)
    case rateLimited(retryAfter: TimeInterval?)   // HTTP 429；retryAfter = 服务端要求再等的秒数（没给为 nil）
    case failed(String)   // 网络 / 解析等其它错误
}

// MARK: - 进程内共享额度缓存

/// 额度缓存的落盘读写：App 用 UserDefaults，测试注入内存版。
struct QuotaSnapshotStore: Sendable {
    var load: @Sendable () -> QuotaSnapshot?
    var save: @Sendable (QuotaSnapshot) -> Void

    static let userDefaultsKey = "quota.claude.snapshot"
    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "quota")

    static let userDefaults = QuotaSnapshotStore(
        load: {
            guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else { return nil }
            do {
                return try QuotaSnapshot.decode(data)
            } catch {
                log.error("额度快照读不出来，当作没有：\(error.localizedDescription, privacy: .public)")
                return nil
            }
        },
        save: { snapshot in
            do {
                UserDefaults.standard.set(try snapshot.encoded(), forKey: userDefaultsKey)
            } catch {
                log.error("额度快照存不下：\(error.localizedDescription, privacy: .public)")
            }
        })
}

/// 把 cc-switch 的额度读取/缓存机制搬到 widget，并补上限流退避与落盘。
///
/// cc-switch 侧：查询结果写入内存 `UsageCache`（**不落盘**，进程重启即空），由
/// react-query 以 `REFETCH_INTERVAL = 5 分钟` 的 staleTime/refetchInterval 为闸门决定
/// 是否真的再打官方接口；系统托盘只读这份内存快照、从不自己发请求
/// （见 cc-switch `src-tauri/src/services/usage_cache.rs` + `src/lib/query/subscription.ts`）。
///
/// widget 侧：一份进程内共享缓存 + 查询闸门（QuotaThrottle）。原生额度定时器（若启用）与 embed 的 `get_quota`
/// 桥接两条读取路径都经过这里，平时合计 **≤1 次 / 5min** 命中 `api.anthropic.com/api/oauth/usage`。
/// 与上游不同的两点（2026-11-20）：
/// - 被限流（429）后按 `Retry-After` 暂停（没给先停 30 分钟），暂停期间手动刷新也不打——上游照旧每 5 分钟打，
///   限流期间只会把限流拖长，同账号的 Claude Code 状态栏也跟着拿不到数；
/// - 上次成功的额度和闸门状态落盘（QuotaSnapshot），重启后先显示上次的数、暂停期间不会一启动就再打。
/// 失败/429/无凭据一律保留上次成功数据（stale-if-error）；过了重置时刻的档不再显示。
actor QuotaCache {
    static let shared = QuotaCache(store: .userDefaults)

    private var tiers: [QuotaTier]          // 上次成功数据；失败不清空 → stale-if-error
    private var throttle: QuotaThrottle
    /// 在途查询（并发去重 + 首屏等待）：启动时菜单栏先发起查询、面板 1–2s 后跟着读，
    /// 若只看节流闸门会拿到「窗口内但缓存还空」的空数组 → 徽标 "—" 干等 20s。
    /// 挂上在途 Task 后，后来者直接 await 同一次网络请求，首屏即真值。
    private var inflight: Task<Result<[QuotaTier], QuotaStatus>, Never>?
    private let store: QuotaSnapshotStore
    private let now: @Sendable () -> Date

    init(store: QuotaSnapshotStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
        let snapshot = store.load()
        tiers = snapshot?.tiers ?? []
        throttle = QuotaThrottle(lastAttempt: snapshot?.lastAttempt, blockedUntil: snapshot?.blockedUntil)
    }

    /// 现在能显示的额度（过了重置时刻的档丢掉）。
    private var current: [QuotaTier] { QuotaSnapshot.live(tiers, now: now()) }

    private func persist() {
        store.save(QuotaSnapshot(tiers: tiers, lastAttempt: throttle.lastAttempt, blockedUntil: throttle.blockedUntil))
    }

    /// 发起一次真实查询并挂为在途。查询前先记下时刻并落盘：查询中途退出、重启后也不会立刻再打。
    private func launch(_ fetch: @Sendable @escaping () async -> Result<[QuotaTier], QuotaStatus>) async -> [QuotaTier] {
        throttle.recordAttempt(at: now())
        persist()
        let task = Task<Result<[QuotaTier], QuotaStatus>, Never> { await fetch() }
        inflight = task
        let result = await task.value
        inflight = nil
        apply(result)
        return current
    }

    /// 成功（非空）→ 回填并落盘；429 → 按 Retry-After 暂停并落盘；其它失败 / 空结果 → 保留上次成功数据。
    private func apply(_ result: Result<[QuotaTier], QuotaStatus>) {
        switch result {
        case .success(let fresh) where !fresh.isEmpty:
            tiers = fresh
        case .failure(.rateLimited(let retryAfter)):
            throttle.recordRateLimited(at: now(), retryAfter: retryAfter)
        default:
            return
        }
        persist()
    }

    /// 缓存优先取额度（`get_quota` 桥接与菜单栏定时刷新用）：
    /// - 有查询在途 → await 同一次请求（首屏拿真值，不再撞「窗口内但缓存空」）。
    /// - 闸门不放行（5 分钟内、或限流暂停中）→ 直接返回上次快照，**绝不打官方接口**。
    /// - 否则发起查询；失败/429/无凭据 → 保留上次成功数据。
    func read(fetch: @Sendable @escaping () async -> Result<[QuotaTier], QuotaStatus>) async -> [QuotaTier] {
        if let inflight { return await joinInflight(inflight) }
        guard throttle.mayFetch(now: now(), force: false) else { return current }
        return await launch(fetch)
    }

    /// 搭车在途请求时同样享受「失败保留上次成功数据」：`inflight.value` 是 **原始**
    /// 结果，失败时直接返回会让搭车方把额度徽标刷成空，而发起方却拿着完好的缓存——同一次刷新里两边不一致。
    /// 不写成「await 后读 self.tiers」是因为发起方回填 `tiers` 与本方恢复执行同为
    /// actor 上的独立任务，先后顺序无保证；改按结果判断则与顺序无关。
    private func joinInflight(_ task: Task<Result<[QuotaTier], QuotaStatus>, Never>) async -> [QuotaTier] {
        if case .success(let fresh) = await task.value, !fresh.isEmpty {
            return QuotaSnapshot.live(fresh, now: now())
        }
        return current
    }

    /// 强制取一次，用于用户手动动作（如在菜单栏勾选「额度」码片）：不受 5 分钟间隔限制，
    /// 但限流暂停期间照样不打（返回上次快照）。已有在途请求时复用它。
    /// 仅供低频用户交互调用（不放进定时器）。
    func forceRefresh(fetch: @Sendable @escaping () async -> Result<[QuotaTier], QuotaStatus>) async -> [QuotaTier] {
        if let inflight { return await joinInflight(inflight) }
        guard throttle.mayFetch(now: now(), force: true) else { return current }
        return await launch(fetch)
    }
}

// MARK: - 额度查询入口（菜单栏 PanelModel 与 embed 桥接 get_quota 共用）

/// 纯静态命名空间：两条读取路径都经同一份 `QuotaCache`（查询闸门 + 在途去重 +
/// stale-if-error + 落盘）——这正是「菜单栏与面板的额度数字永远一致」的机制所在。
/// 读不到凭据 / 请求失败一律返回上次成功值（从没成功过时为空数组，前端徽标显示 "—"）。
enum QuotaService {
    /// 缓存优先取额度（定时刷新用）：节流窗口内只读共享缓存，绝不打官方接口。
    static func fetchTiersForBridge() async -> [QuotaTier] {
        await QuotaCache.shared.read { await ClaudeQuotaFetch(recovery: .shared).run() }
    }

    /// 强制取一次（不受 5 分钟间隔限制，限流暂停期间除外）：仅供低频用户交互（勾选额度码片）调用。
    static func forceTiersForBridge() async -> [QuotaTier] {
        await QuotaCache.shared.forceRefresh { await ClaudeQuotaFetch(recovery: .shared).run() }
    }
}

/// 一次真实查询：读凭据 → 调官方 /api/oauth/usage（令牌被拒就请 Claude Code 刷新、用它缓存的额度）→ 给每个 tier
/// 附上套餐标签。几头都可注入，失败路径能测。
struct ClaudeQuotaFetch: Sendable {
    var readCredential: @Sendable () -> Result<ClaudeCredential, QuotaStatus> = { ClaudeCredentialReader.read() }
    var planDisplayName: @Sendable () -> String? = { ClaudeConfigReader.planDisplayName() }
    var query: @Sendable (String) async -> Result<[QuotaTier], QuotaStatus> = { await ClaudeUsageAPI.query(token: $0) }
    var report: @Sendable (QuotaStatus) -> Void = { ClaudeQuotaFetch.log($0) }
    /// 令牌被拒以后请 Claude Code 刷新（ClaudeLoginRecovery）。没有默认值：测试必须换成假的，免得真去跑 claude。
    let recovery: ClaudeLoginRecovery

    private static let logger = Logger(subsystem: "com.ganxing.ccusage", category: "quota")

    /// 经 QuotaCache 的闸门，最多 5 分钟一次（限流时更少），不用再去重。
    private static func log(_ status: QuotaStatus) {
        switch status {
        case .noCredential: logger.info("没有 Claude 登录，额度不可用")
        case .expired: logger.error("Claude 额度查询失败：令牌过期或鉴权失败")
        case .rateLimited(let retryAfter):
            let wait = retryAfter.map { "服务端要求等 \(Int($0)) 秒" } ?? "没给 Retry-After，先停 30 分钟"
            logger.error("Claude 额度查询失败：API 限流 (HTTP 429)，\(wait, privacy: .public)")
        case .failed(let reason): logger.error("Claude 额度查询失败：\(reason, privacy: .public)")
        }
    }

    /// 失败原因经 report 记下，再原样交给 QuotaCache（429 要按 Retry-After 暂停，其它失败保留上次成功值）。
    func run() async -> Result<[QuotaTier], QuotaStatus> {
        // 读凭据、读 Claude Code 配置都是阻塞操作（spawn security / 读文件），放后台线程
        let (credResult, displayName) = await Task.detached(priority: .utility) { [readCredential, planDisplayName] in
            (readCredential(), planDisplayName())
        }.value
        let cred: ClaudeCredential
        switch credResult {
        case .success(let value):
            cred = value
        case .failure(let status):
            report(status)
            return .failure(status)
        }

        switch await queryOrRecover(cred.accessToken) {
        case .success(var tiers):
            let plan = ClaudePlan.label(displayName: displayName, subscriptionType: cred.subscriptionType,
                                        rateLimitTier: cred.rateLimitTier)
            for i in tiers.indices { tiers[i].planLabel = plan }
            return .success(tiers)
        case .failure(let status):
            report(status)
            return .failure(status)
        }
    }

    /// 直接查官方接口；令牌被拒（这次 401/403，或这份令牌以前就被拒过、不再查）就请 Claude Code 刷新，用它缓存的额度。
    /// 限流、网络错误原样交回：429 要按 Retry-After 暂停，网络抖一下不能把令牌记成被拒的。
    private func queryOrRecover(_ token: String) async -> Result<[QuotaTier], QuotaStatus> {
        let fingerprint = TokenFingerprint.of(token)
        if await !recovery.isRejected(fingerprint) {
            let direct = await query(token)
            guard case .failure(.expired) = direct else { return direct }
            await recovery.reject(fingerprint)
        }
        guard let tiers = await recovery.recover() else { return .failure(.expired) }
        return .success(tiers)
    }
}

// MARK: - 凭据读取（照搬 subscription.rs 的 read_claude_credentials）

/// 纯 Foundation、可在后台线程执行的凭据读取器。取舍规则（先当前用户账户、再旧查法、
/// 最后凭据文件）和 JSON 解析都在 `Sources/Shared/Quota/ClaudeCredentialSource.swift`，这里只起进程、读文件。
enum ClaudeCredentialReader {
    /// `security` 最多等多久。钥匙串弹窗要等用户点，不能太短；但也不能无限：这段卡住时 QuotaCache.inflight 不结束，
    /// 所有 get_quota 搭车方一起等。超时当查不到，接着读凭据文件。
    private static let keychainTimeout: TimeInterval = 60

    /// 按优先级读取：Keychain → 文件。返回凭据或降级状态。
    static func read() -> Result<ClaudeCredential, QuotaStatus> {
        // 来源 1：macOS Keychain。上游取 $USER；从访达启动时环境里没有它的话退回登录名（同一个值）。
        let env = ProcessInfo.processInfo.environment["USER"] ?? ""
        let user = env.isEmpty ? NSUserName() : env
        if let credential = ClaudeKeychainLookup.select(user: user, run: runSecurity) {
            return .success(credential)
        }
        // 来源 2：~/.claude/.credentials.json
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".claude/.credentials.json")
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.noCredential)
        }
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure(.failed("读取凭据文件失败"))
        }
        switch ClaudeCredentialParser.parse(content) {
        case .success(let credential):
            return .success(credential)
        case .failure(.invalidJSON):
            return .failure(.failed("凭据 JSON 解析失败"))
        case .failure(.missingOAuthEntry):
            return .failure(.failed("凭据中缺少 OAuth 条目"))
        case .failure(.missingAccessToken):
            return .failure(.failed("accessToken 为空或缺失"))
        }
    }

    /// 跑一次 `/usr/bin/security <arguments>`；进程起不来或超时返回 nil。
    private static func runSecurity(_ arguments: [String]) -> SecurityLookupOutput? {
        ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/security"), arguments, timeout: keychainTimeout)
            .map { SecurityLookupOutput(status: $0.status, stdout: $0.stdout) }
    }
}

// MARK: - Claude Code 全局配置里的套餐显示名

/// Claude Code 的全局配置：套餐显示名（`oauthAccount.planDisplayName`，来自 `/api/oauth/profile`，见 ClaudePlan）、
/// 当前登录账号和它缓存的额度（见 ClaudeUsageCache）都在这里。
/// 文件位置同 Claude Code 2.1.316（上游 Slot::global_config 同理）：旧版 `~/.claude/.config.json` 非空就用它，否则 `~/.claude.json`。
/// CLAUDE_CONFIG_DIR 只对终端里起的 Claude Code 生效；本应用从访达启动，和钥匙串只查默认条目一样只看默认位置。
enum ClaudeConfigReader {
    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "quota")

    /// 全局配置的内容。不存在（没装 Claude Code、API key 登录）返回 nil，属正常情况只记 debug；读不了记错误。
    static func profileData() -> Data? {
        let home = NSHomeDirectory() as NSString
        let legacy = home.appendingPathComponent(".claude/.config.json")
        let path = fileSize(legacy) > 0 ? legacy : home.appendingPathComponent(".claude.json")
        guard FileManager.default.fileExists(atPath: path) else {
            log.debug("没有 Claude Code 全局配置")
            return nil
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            log.error("读取 Claude Code 全局配置失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 读不到返回 nil，套餐名回落到按凭据推断。
    static func planDisplayName() -> String? {
        guard let data = profileData() else { return nil }
        let name = ClaudePlan.displayName(fromClaudeConfig: data)
        if name == nil { log.debug("Claude Code 配置里没有 planDisplayName，套餐名按凭据推断") }
        return name
    }

    /// 文件大小；不存在或读不到属性都按 0（旧版配置文件绝大多数人没有，属正常情况，不记日志）。
    private static func fileSize(_ path: String) -> Int {
        guard FileManager.default.fileExists(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}

// MARK: - 官方用量 API（照搬 subscription.rs 的 query_claude_quota）

enum ClaudeUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    static func query(token: String) async -> Result<[QuotaTier], QuotaStatus> {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            return .failure(.failed("网络错误: \(error.localizedDescription)"))
        }

        guard let http = resp as? HTTPURLResponse else {
            return .failure(.failed("无 HTTP 响应"))
        }
        return interpret(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"),
                         body: data, now: Date())
    }

    /// HTTP 响应 → 额度或失败原因（纯函数，可测）。401/403 是令牌问题；429 带上服务端要求再等的秒数，
    /// QuotaCache 据此暂停查询；其它非 2xx 和解析失败都记原因、保留上次的数。
    static func interpret(status: Int, retryAfter: String?, body: Data, now: Date) -> Result<[QuotaTier], QuotaStatus> {
        if status == 401 || status == 403 {
            return .failure(.expired)
        }
        if status == 429 {
            return .failure(.rateLimited(retryAfter: RetryAfter.seconds(retryAfter, now: now)))
        }
        guard (200..<300).contains(status) else {
            return .failure(.failed("API 错误 (HTTP \(status))"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return .failure(.failed("解析 API 响应失败"))
        }
        return .success(ClaudeQuotaParser.parse(root))
    }
}
