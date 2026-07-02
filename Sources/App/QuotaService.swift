import Foundation
import Combine

// cc-usage-widget 官方订阅额度层：照搬 cc-switch `src-tauri/src/services/subscription.rs`
// 的 Claude 分支，读取 Claude Code 的 OAuth 凭据 → 调 Anthropic 官方用量端点
// → 解析出各限流窗口的真实 utilization%（而非拿 token 数除以占位额度猜）。
//
// 凭据来源（按优先级，与 cc-switch 一致）：
//   1. macOS Keychain: `security find-generic-password -s "Claude Code-credentials" -w`
//   2. 文件: ~/.claude/.credentials.json
//   JSON 结构（两种 key 名都兼容）：
//   { "claudeAiOauth": { "accessToken": "...", "expiresAt": <ms>, "subscriptionType": "..." } }
//
// 端点：GET https://api.anthropic.com/api/oauth/usage
//   Header: Authorization: Bearer <token>
//           anthropic-beta: oauth-2025-04-20
//           Accept: application/json
//   响应：{ "five_hour": {utilization, resets_at, ...}, "seven_day": {...}, "extra_usage": {...}, ... }
//   其中 5 小时窗口 = "five_hour"，每周窗口 = "seven_day"（utilization 为 0–100）。

// MARK: - 数据模型

/// 单个限流窗口（对齐 cc-switch QuotaTier）
struct QuotaTier: Identifiable, Sendable {
    /// 窗口标识：five_hour / seven_day / seven_day_opus / seven_day_sonnet …
    let name: String
    /// 已用百分比 0–100
    let utilization: Double
    /// 窗口重置时间
    let resetsAt: Date?
    /// 套餐标签（来自凭据 subscriptionType，如 "max"）
    var planLabel: String?

    var id: String { name }

    /// 剩余时间倒计时文本，如 "2h30m" / "3d12h" / "45m"。
    /// 对齐 cc-switch SubscriptionQuotaFooter.countdownStr（已重置/无数据返回 nil）。
    var countdown: String? {
        guard let resetsAt else { return nil }
        let diff = resetsAt.timeIntervalSinceNow
        if diff <= 0 { return nil }
        let totalMinutes = Int(diff / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 24 {
            let days = hours / 24
            return "\(days)d\(hours % 24)h"
        }
        if hours > 0 { return "\(hours)h\(minutes)m" }
        return "\(minutes)m"
    }
}

/// 凭据/查询状态，驱动徽标降级显示（作为 Result 的 Failure，需符合 Error）
enum QuotaStatus: Error, Equatable, Sendable {
    case ok               // 成功拿到 tiers
    case noCredential     // Keychain / 文件都读不到凭据
    case expired          // token 过期或鉴权失败(401/403)
    case failed(String)   // 网络 / 解析等其它错误
}

// MARK: - 进程内共享额度缓存（照搬 cc-switch 的读取策略）

/// 把 cc-switch 的额度读取/缓存机制搬到 widget。
///
/// cc-switch 侧：查询结果写入内存 `UsageCache`（**不落盘**，进程重启即空），由
/// react-query 以 `REFETCH_INTERVAL = 5 分钟` 的 staleTime/refetchInterval 为闸门决定
/// 是否真的再打官方接口；系统托盘只读这份内存快照、从不自己发请求
/// （见 cc-switch `src-tauri/src/services/usage_cache.rs` + `src/lib/query/subscription.ts`）。
///
/// widget 侧：同样用「一份进程内共享缓存 + 5 分钟节流窗口」。原生额度定时器（若启用）与
/// embed 的 `get_quota` 桥接两条读取路径都经过这里，合计 **≤1 次 / 5min** 命中
/// `api.anthropic.com/api/oauth/usage` → 从根上杜绝 429。闸门以「上次发起查询的时刻」为准
/// （成功或失败都推进），因此 429 后会自动退避 5 分钟再试；失败/429/无凭据一律保留上次成功
/// 数据（stale-if-error），不把徽标空成 "—"。
actor QuotaCache {
    static let shared = QuotaCache()

    /// 两次真正打官方接口的最小间隔，对齐 cc-switch `REFETCH_INTERVAL = 5 * 60 * 1000ms`。
    static let minInterval: TimeInterval = 5 * 60

    private var tiers: [QuotaTier] = []   // 上次成功数据；失败不清空 → stale-if-error
    private var lastAttempt: Date?        // 上次发起查询的时刻（节流闸门）
    /// 在途查询（并发去重 + 首屏等待）：启动时菜单栏先发起查询、面板 1–2s 后跟着读，
    /// 若只看节流闸门会拿到「窗口内但缓存还空」的空数组 → 徽标 "—" 干等 20s。
    /// 挂上在途 Task 后，后来者直接 await 同一次网络请求，首屏即真值。
    private var inflight: Task<[QuotaTier], Never>?

    private var throttled: Bool {
        guard let lastAttempt else { return false }
        return Date().timeIntervalSince(lastAttempt) < Self.minInterval
    }

    /// 发起一次真实查询并挂为在途：成功回填缓存，失败保留旧值（stale-if-error）。
    private func launch(_ fetch: @Sendable @escaping () async -> [QuotaTier]?) async -> [QuotaTier] {
        lastAttempt = Date()
        let task = Task<[QuotaTier], Never> { await fetch() ?? [] }
        inflight = task
        let result = await task.value
        inflight = nil
        if !result.isEmpty { tiers = result }
        return tiers
    }

    /// 只读快照 + 是否仍在节流窗口内（供原生 OO 路径短路复用，不触发网络）。
    func peek() -> (tiers: [QuotaTier], throttled: Bool, at: Date?) {
        (tiers, throttled, lastAttempt)
    }

    /// 写穿：任意路径成功查询后回填，供另一条读取路径共享（同时推进节流闸门）。
    func store(_ newTiers: [QuotaTier]) {
        lastAttempt = Date()
        guard !newTiers.isEmpty else { return }
        tiers = newTiers
    }

    /// 缓存优先取额度（`get_quota` 桥接用）：
    /// - 有查询在途 → await 同一次请求（首屏拿真值，不再撞「窗口内但缓存空」）。
    /// - 节流窗口内 → 直接返回上次快照，**绝不打官方接口**。
    /// - 窗口外 → 先推进闸门（失败也退避 5min），再执行 `fetch`；成功则回填缓存。
    /// - `fetch` 返回 nil/空（失败/429/无凭据）→ 保留上次成功数据。
    func read(fetch: @Sendable @escaping () async -> [QuotaTier]?) async -> [QuotaTier] {
        if let inflight { return await inflight.value }
        if throttled { return tiers }
        return await launch(fetch)
    }

    /// 强制取一次（**忽略节流**），用于用户手动动作（如在菜单栏勾选「额度」码片）：
    /// 即便还在 5 分钟窗口内、或上次是空结果，也立即打一次官方接口拿最新值并回填共享缓存。
    /// 已有在途请求时复用它（在途即最新，无需再发一发）。
    /// 仅供低频用户交互调用（不放进定时器），故不会造成限流。
    func forceRefresh(fetch: @Sendable @escaping () async -> [QuotaTier]?) async -> [QuotaTier] {
        if let inflight { return await inflight.value }
        return await launch(fetch)
    }
}

// MARK: - 服务

@MainActor
final class QuotaService: ObservableObject {
    /// 官方返回的全部窗口（按名字查用）
    @Published private(set) var tiers: [QuotaTier] = []
    @Published private(set) var status: QuotaStatus = .noCredential
    @Published private(set) var lastUpdated: Date?
    /// 套餐标签（来自凭据 subscriptionType）
    @Published private(set) var planLabel: String?

    private var timer: Timer?
    private var started = false
    private var inFlight = false

    /// 5 小时会话窗口
    var fiveHour: QuotaTier? { tiers.first { $0.name == "five_hour" } }
    /// 每周窗口
    var weekly: QuotaTier? { tiers.first { $0.name == "seven_day" } }

    /// 启动：立即查一次，然后每 interval 秒触发一次刷新。
    /// 实际是否命中官方接口由 `QuotaCache` 的 5 分钟节流窗口决定（对齐 cc-switch），
    /// 因此即便 interval 较小也不会频繁打接口；默认 300s 与 cc-switch REFETCH_INTERVAL 对齐。
    func start(intervalSeconds: TimeInterval = 300) {
        guard !started else { return }
        started = true
        refreshNow()
        let t = Timer(timeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
    }

    /// 手动触发一次刷新（非阻塞）。
    func refreshNow() {
        Task { await self.refresh() }
    }

    /// 读凭据 → 调 API → 更新状态。全程不抛错，失败即优雅降级。
    func refresh() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        // 0) 缓存优先：节流窗口内复用进程共享缓存，不打官方接口（对齐 cc-switch staleTime）。
        //    与 get_quota 桥接共享同一份 QuotaCache，两条读取路径合计 ≤1 次/5min 命中官方接口。
        let cached = await QuotaCache.shared.peek()
        if cached.throttled {
            if !cached.tiers.isEmpty {
                tiers = cached.tiers
                planLabel = cached.tiers.first?.planLabel
                status = .ok
                lastUpdated = cached.at
            }
            return
        }

        // 1) 读凭据：spawn `security` / 读文件属阻塞操作，放后台线程，避免卡主线程
        let credResult = await Task.detached(priority: .utility) {
            ClaudeCredentialReader.read()
        }.value

        let cred: ClaudeCredential
        switch credResult {
        case .failure(let st):
            status = st
            tiers = []
            planLabel = nil
            return
        case .success(let c):
            cred = c
        }
        planLabel = cred.subscriptionType

        // 2) 调官方端点。即便本地时间戳判定过期也照样尝试——token 可能仍有效
        //    （对齐 cc-switch：Expired 时仍 query，成功就用）。
        let apiResult = await ClaudeUsageAPI.query(token: cred.accessToken)
        switch apiResult {
        case .success(var fetched):
            // 把套餐标签塞进每个 tier，方便 UI 直接取用
            for i in fetched.indices { fetched[i].planLabel = cred.subscriptionType }
            tiers = fetched
            status = .ok
            lastUpdated = Date()
            await QuotaCache.shared.store(fetched)   // 写穿共享缓存，供 get_quota 桥接复用
        case .failure(let st):
            status = st
            // 凭据级问题（无凭据 / 过期）→ 清空，徽标显示 "—"。
            // 仅传输层抖动（.failed）→ 保留上次成功数据，避免频繁闪 "—"。
            if case .failed = st {
                // 保留 tiers
            } else {
                tiers = []
            }
        }
    }
}

// MARK: - Bridge 复用入口（供 PanelWebView 的 get_quota 调用）

extension QuotaService {
    /// 一次性查询：读凭据 → 调官方 /api/oauth/usage → 给每个 tier 附上套餐标签。
    /// 纯静态、`nonisolated`：不触碰 @Published 状态，不影响 MainWindowView 对 QuotaService 的既有接口。
    /// 读不到凭据 / 请求失败一律降级为空数组（前端徽标显示 "—"）。
    nonisolated static func fetchTiersForBridge() async -> [QuotaTier] {
        // 缓存优先（对齐 cc-switch：staleTime / UsageCache 语义）：节流窗口内直接返回上次
        // 快照，绝不打官方接口；窗口外才真正读凭据 + 调 API。失败 / 429 / 无凭据 → 保留上次
        // 成功数据（stale-if-error），前端徽标不空成 "—"。
        await QuotaCache.shared.read {
            // 读凭据属阻塞操作（spawn security / 读文件），放后台线程
            let credResult = await Task.detached(priority: .utility) {
                ClaudeCredentialReader.read()
            }.value
            guard case .success(let cred) = credResult else { return nil }

            switch await ClaudeUsageAPI.query(token: cred.accessToken) {
            case .success(var tiers):
                for i in tiers.indices { tiers[i].planLabel = cred.subscriptionType }
                return tiers
            case .failure:
                return nil
            }
        }
    }

    /// 强制版（忽略 5 分钟节流），供菜单栏勾选「额度」时立即取一次用。
    /// 与 `fetchTiersForBridge` 同样的读凭据 + 调 API，只是走 `QuotaCache.forceRefresh`。
    nonisolated static func forceTiersForBridge() async -> [QuotaTier] {
        await QuotaCache.shared.forceRefresh {
            let credResult = await Task.detached(priority: .utility) {
                ClaudeCredentialReader.read()
            }.value
            guard case .success(let cred) = credResult else { return nil }

            switch await ClaudeUsageAPI.query(token: cred.accessToken) {
            case .success(var tiers):
                for i in tiers.indices { tiers[i].planLabel = cred.subscriptionType }
                return tiers
            case .failure:
                return nil
            }
        }
    }
}

// MARK: - 凭据读取（照搬 subscription.rs 的 read_claude_credentials）

/// 解析出的 Claude 凭据
struct ClaudeCredential: Sendable {
    let accessToken: String
    let expiresAtMs: Double?
    let subscriptionType: String?
    /// 本地时间戳是否判定已过期（仅供参考，仍会尝试调 API）
    let isExpired: Bool
}

/// 纯 Foundation、可在后台线程执行的凭据读取器。
enum ClaudeCredentialReader {
    /// 按优先级读取：Keychain → 文件。返回凭据或降级状态。
    static func read() -> Result<ClaudeCredential, QuotaStatus> {
        // 来源 1：macOS Keychain
        if let json = keychainJSON() {
            return parse(json)
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
        return parse(content)
    }

    /// `security find-generic-password -s "Claude Code-credentials" -w`
    private static func keychainJSON() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "find-generic-password", "-s", "Claude Code-credentials", "-w",
        ]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (s?.isEmpty == false) ? s : nil
    }

    /// 解析凭据 JSON（Keychain / 文件共用）
    private static func parse(_ json: String) -> Result<ClaudeCredential, QuotaStatus> {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .failure(.failed("凭据 JSON 解析失败"))
        }
        // 兼容两种 key 名
        guard let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any]
        else {
            return .failure(.failed("凭据中缺少 OAuth 条目"))
        }
        guard let token = entry["accessToken"] as? String, !token.isEmpty else {
            return .failure(.failed("accessToken 为空或缺失"))
        }

        // expiresAt：数字（秒/毫秒）或 ISO 字符串，统一归一到毫秒
        var expiresMs: Double?
        if let num = entry["expiresAt"] as? NSNumber {
            let raw = num.doubleValue
            expiresMs = raw > 1_000_000_000_000 ? raw : raw * 1000
        } else if let s = entry["expiresAt"] as? String,
                  let d = ClaudeUsageAPI.parseISODate(s) {
            expiresMs = d.timeIntervalSince1970 * 1000
        }

        let subscriptionType = entry["subscriptionType"] as? String
        let nowMs = Date().timeIntervalSince1970 * 1000
        let isExpired = expiresMs.map { $0 < nowMs } ?? false

        return .success(ClaudeCredential(
            accessToken: token,
            expiresAtMs: expiresMs,
            subscriptionType: subscriptionType,
            isExpired: isExpired
        ))
    }
}

// MARK: - 官方用量 API（照搬 subscription.rs 的 query_claude_quota）

enum ClaudeUsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 已知窗口名（对齐 cc-switch KNOWN_TIERS），非窗口键跳过。
    private static let nonTierKeys: Set<String> = [
        "extra_usage", "limits", "spend", "member_dashboard_available",
    ]

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
        if http.statusCode == 401 || http.statusCode == 403 {
            return .failure(.expired)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.failed("API 错误 (HTTP \(http.statusCode))"))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.failed("解析 API 响应失败"))
        }

        // 遍历所有窗口键：凡是带 utilization 的对象都收进来（对齐 cc-switch
        // 「已知 + 未知窗口」两段解析的合并效果）。null / 非对象 / 无 utilization 的键跳过。
        var tiers: [QuotaTier] = []
        for (key, value) in root {
            if nonTierKeys.contains(key) { continue }
            guard let window = value as? [String: Any],
                  let util = window["utilization"] as? NSNumber else { continue }
            let resetsAt = (window["resets_at"] as? String).flatMap(parseISODate)
            tiers.append(QuotaTier(
                name: key,
                utilization: util.doubleValue,
                resetsAt: resetsAt,
                planLabel: nil
            ))
        }
        return .success(tiers)
    }

    /// 稳健解析 ISO 8601（官方 resets_at 带 6 位微秒 + `+00:00` 偏移，
    /// ISO8601DateFormatter 对小数位数敏感，先剥掉小数秒——倒计时精度到分钟即可）。
    static func parseISODate(_ s: String) -> Date? {
        let cleaned = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: cleaned) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f2.date(from: s)
    }
}
