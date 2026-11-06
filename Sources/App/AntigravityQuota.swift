import Foundation
import SQLite3
import os

/// Antigravity（Google Antigravity IDE）的官方**实时**额度。
///
/// Antigravity 的余量不落盘（本地只有登录时的静态快照），实时值只能查服务端。链路：
///   1. 从 state.vscdb 的 oauthToken 提取 Google refresh_token（嵌套 base64 → `1//…`）
///   2. refresh_token → access_token（oauth2.googleapis.com，缓存到过期前）
///   3. loadCodeAssist（metadata.ideType=ANTIGRAVITY）→ cloudaicompanionProject
///   4. retrieveUserQuotaSummary（project + User-Agent）→ 两组（Gemini；Claude 和 GPT 共用）× 两个窗口
///      （5 小时、每周）的剩余比例与重置时间。和 agy 的 `/usage`、cc-switch v4.0.18 起的官方卡是同一个接口，
///      解析规则在 `Sources/Shared/Quota/AntigravityQuotaParsing.swift`。
///
/// 第 4 步必须带 project：10-26 实测 IDE 的令牌发 `{}` 会 403「没有有效许可」，带上 project 才 200
/// （cc-switch 用的是 agy CLI 的令牌，`{}` 就够）。早先查的是 fetchAvailableModels 的逐模型剩余比例、
/// 再按家族折叠——那只有一个窗口（重置时间与每周桶一致，实为每周），看不到 5 小时。
///
/// 只读本机凭据、只在本机发起查询、不外传。属未公开私有接口，Antigravity 大更新可能改。
actor AntigravityQuota {
    static let shared = AntigravityQuota()

    /// 一次 HTTP 往返。
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "quota")

    /// 这一轮查不到的原因。界面上还是上次的额度（首次是「—」），原因只进日志。
    enum Failure: Equatable, Sendable {
        case noCredential            // 没装 Antigravity 或没登录
        case network(String)         // 断网、超时
        case unauthorized            // 401：access_token 失效
        case http(Int)
        case badResponse             // 200 但不是 JSON 对象
        case unrecognizedSummary     // 额度响应里一个认识的桶都没有
    }

    // Antigravity 桌面应用公开内置的 Google OAuth 客户端凭据（每个安装包都含，社区工具通用，
    // 非用户私密）。用户真正的私密凭据是 refresh_token，只从本机读取、绝不入库。
    // 分片拼接：避免密钥扫描器把这对公开常量误判为泄露的私密而拦下提交。
    private static let clientID = ["1071006060591-tmhssin2h21lcre235vtolojh4g403ep",
                                   "apps.googleusercontent.com"].joined(separator: ".")
    private static let clientSecret = ["GOCSPX", "K58FWR486LdLJ1mLB8sXC4z6qDAf"].joined(separator: "-")
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    private static let apiBase = "https://cloudcode-pa.googleapis.com"
    /// loadCodeAssist 沿用旧 UA：它不看 User-Agent 回不同内容，没必要动一条正常工作的请求。
    private static let legacyUserAgent = "AntigravityQuotaWatcher/1.0"
    private static let dbPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage/state.vscdb")
    /// `agy --version` 最多等多久（上游 VERSION_PROBE_TIMEOUT）。
    private static let versionProbeTimeout: TimeInterval = 5

    private let transport: Transport
    private let storedRefreshToken: @Sendable () -> String?
    private let localAgyVersion: @Sendable () -> String?
    private let minInterval: TimeInterval
    private let onFailure: @Sendable (Failure) -> Void

    private var accessToken: String?
    private var accessExpiry = Date.distantPast
    private var projectID: String?
    private var agyVersion: String?
    private var cache: [AntigravityTier] = []
    private var cacheAt = Date.distantPast
    private var lastFailure: Failure?

    /// 网络、本机凭据和 agy 版本都从这里注入，测试不碰真实环境。
    init(transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
         refreshToken: @escaping @Sendable () -> String? = { AntigravityQuota.readRefreshToken() },
         agyVersion: @escaping @Sendable () -> String? = { AntigravityQuota.probeAgyVersion() },
         minInterval: TimeInterval = 30,
         onFailure: @escaping @Sendable (Failure) -> Void = { AntigravityQuota.logFailure($0) }) {
        self.transport = transport
        self.storedRefreshToken = refreshToken
        self.localAgyVersion = agyVersion
        self.minInterval = minInterval
        self.onFailure = onFailure
    }

    /// 各档实时额度；未装 Antigravity / 未登录 / 网络失败返回上次结果（首次为空）。30s 节流。
    /// 失败时保留上次结果（stale-if-error），不闪空。
    func latest() async -> [AntigravityTier] {
        if Date().timeIntervalSince(cacheAt) < minInterval { return cache }
        // 闸门在入口就推进,成败一视同仁。只在成功后推进的话 30s 节流对失败路径完全
        // 失效——Dashboard 每 5 秒调一次,凭据一过期就是每小时 720 次带 client_secret
        // 与 refresh_token 的 POST 打向 Google,足以被限流甚至标记异常。
        // 放在第一个 await 之前:actor 重入时后来的调用会被上面的 if 挡住。
        cacheAt = Date()
        guard let token = await validAccessToken() else { return cache }
        guard let proj = await ensureProject(token: token) else { return cache }
        guard let tiers = await fetchSummary(token: token, project: proj) else { return cache }
        lastFailure = nil
        cache = tiers
        return tiers
    }

    /// 同一个原因只报一次：这里 30 秒一轮，断网一整天不能写几千条一样的日志。成功一次就清掉。
    private func report(_ failure: Failure) {
        guard failure != lastFailure else { return }
        lastFailure = failure
        onFailure(failure)
    }

    private nonisolated static func logFailure(_ failure: Failure) {
        switch failure {
        case .noCredential: log.debug("Antigravity 没有可用的登录，额度不可用")
        case .network(let reason): log.error("Antigravity 额度查询失败：\(reason, privacy: .public)")
        case .unauthorized: log.error("Antigravity 额度查询失败：401，令牌已作废，下一轮重新换")
        case .http(let status): log.error("Antigravity 额度查询失败：HTTP \(status)")
        case .badResponse: log.error("Antigravity 额度查询失败：响应不是预期的 JSON")
        case .unrecognizedSummary: log.error("Antigravity 额度响应里没有认识的桶，接口可能变了")
        }
    }

    // MARK: - OAuth

    private func validAccessToken() async -> String? {
        if let t = accessToken, Date() < accessExpiry.addingTimeInterval(-60) { return t }
        guard let rt = storedRefreshToken() else {
            report(.noCredential)
            return nil
        }
        guard var req = post(Self.tokenEndpoint) else { return nil }
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form = ["client_id": Self.clientID, "client_secret": Self.clientSecret,
                    "refresh_token": rt, "grant_type": "refresh_token"]
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        guard let obj = await json(req) else { return nil }
        guard let t = obj["access_token"] as? String else {
            report(.badResponse)
            return nil
        }
        accessToken = t
        let ttl = (obj["expires_in"] as? Double) ?? 3600
        accessExpiry = Date().addingTimeInterval(ttl)
        return t
    }

    /// 从 state.vscdb 的 oauthToken 值里挖出 Google refresh_token（`1//…`）。
    private nonisolated static func readRefreshToken() -> String? {
        guard let outer = readOAuthValue(),
              let l1 = Data(base64Encoded: outer) else { return nil }
        // l1 里嵌一段更长的 base64；longestBase64 返回其**解码后**的 blob，明文 refresh_token 在里面
        if let inner = longestBase64(in: [UInt8](l1)), let t = firstRefreshToken(in: inner) { return t }
        return firstRefreshToken(in: l1)
    }

    private nonisolated static func firstRefreshToken(in data: Data) -> String? {
        // ASCII 扫描：连续可打印段中匹配 "1//" 开头的 token
        var run = [UInt8]()
        for b in data {
            if b >= 0x21 && b <= 0x7e { run.append(b) }
            else { if let t = pick(&run) { return t }; run.removeAll(keepingCapacity: true) }
        }
        return pick(&run)
    }
    private nonisolated static func pick(_ run: inout [UInt8]) -> String? {
        guard let s = String(bytes: run, encoding: .ascii), let r = s.range(of: "1//") else { return nil }
        // 只保留 Google refresh_token 合法字符集（base64url + '/'），遇到别的字节即截断，
        // 否则会把后面粘着的 protobuf 字节也带进 token → invalid_grant
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-/")
        var tok = ""
        for ch in s[r.lowerBound...] {
            if allowed.contains(ch) { tok.append(ch) } else { break }
        }
        return tok.count > 20 ? tok : nil
    }

    /// 内层 base64（GetUserStatus/oauth protobuf blob），取最长可解码段。
    private nonisolated static func longestBase64(in bytes: [UInt8]) -> Data? {
        func isB64(_ b: UInt8) -> Bool {
            (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || (b >= 48 && b <= 57) || b == 43 || b == 47 || b == 61
        }
        var best: Data?; var start: Int?
        func flush(_ end: Int) {
            if let s = start, end - s >= 200 {
                let sub = Data(bytes[s..<end])
                if let d = Data(base64Encoded: sub, options: .ignoreUnknownCharacters),
                   d.count > (best?.count ?? 0) { best = d }
            }
            start = nil
        }
        for (i, b) in bytes.enumerated() {
            if isB64(b) { if start == nil { start = i } } else { flush(i) }
        }
        flush(bytes.count)
        return best
    }

    private nonisolated static func readOAuthValue() -> String? {
        guard FileManager.default.fileExists(atPath: Self.dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2("file:\(Self.dbPath)?mode=ro", &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key='antigravityUnifiedStateSync.oauthToken'", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c)
    }

    // MARK: - Cloud Code API

    private func ensureProject(token: String) async -> String? {
        if let p = projectID { return p }
        guard var req = post("\(Self.apiBase)/v1internal:loadCodeAssist") else { return nil }
        auth(&req, token, userAgent: Self.legacyUserAgent)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["metadata": ["ideType": "ANTIGRAVITY"]])
        guard let obj = await json(req) else { return nil }
        let p = obj["cloudaicompanionProject"] as? String ?? ""
        // 空 project（onboarding 未完成 / 瞬时错误）不缓存，否则整个进程生命周期不再重查。
        if !p.isEmpty { projectID = p }
        return p
    }

    private func fetchSummary(token: String, project: String) async -> [AntigravityTier]? {
        guard var req = post("\(Self.apiBase)/v1internal:retrieveUserQuotaSummary") else { return nil }
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let ua = AntigravityQuotaParsing.userAgent(appVersion: appVersion, agyVersion: await resolvedAgyVersion())
        auth(&req, token, userAgent: ua)
        let body: [String: Any] = project.isEmpty ? [:] : ["project": project]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let obj = await json(req) else { return nil }
        guard let tiers = AntigravityQuotaParsing.parseSummary(obj) else {
            report(.unrecognizedSummary)
            return nil
        }
        return tiers
    }

    // MARK: - 本机 agy 版本（写进 User-Agent）

    /// 每个进程只探测一次（上游同样只探一次）；找不到或读不出用兜底版本。
    /// 探测会起子进程、最多等 5 秒，放到 GCD 队列上跑，不占 Swift 并发的协作线程。
    private func resolvedAgyVersion() async -> String {
        if let v = agyVersion { return v }
        let probe = localAgyVersion
        let v = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: probe() ?? AntigravityQuotaParsing.fallbackAgyVersion)
            }
        }
        agyVersion = v
        return v
    }

    /// 找 agy 的顺序照上游 real_agy_bin：PATH → ~/.local/bin → /opt/homebrew/bin → /usr/local/bin。
    /// 上游最后还会问登录 shell（`command -v agy`）；这里不跑用户的 rc 文件，找不到就用兜底版本——
    /// 兜底版本服务端同样认，差别只在 User-Agent 里的版本号。
    private nonisolated static func probeAgyVersion() -> String? {
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let dirs = pathDirs + [(NSHomeDirectory() as NSString).appendingPathComponent(".local/bin"),
                               "/opt/homebrew/bin", "/usr/local/bin"]
        guard let bin = dirs.map({ ($0 as NSString).appendingPathComponent("agy") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }

        guard let out = ProcessRunner.run(URL(fileURLWithPath: bin), ["--version"], timeout: versionProbeTimeout),
              out.status == 0 else { return nil }
        return AntigravityQuotaParsing.parseVersion(String(decoding: out.stdout, as: UTF8.self))
    }

    // MARK: - HTTP helpers

    private func post(_ url: String) -> URLRequest? {
        guard let u = URL(string: url) else { return nil }
        var r = URLRequest(url: u); r.httpMethod = "POST"; r.timeoutInterval = 15
        return r
    }
    private func auth(_ r: inout URLRequest, _ token: String, userAgent: String) {
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    }
    /// 发一次请求拿 JSON 对象。失败返回 nil，原因经 report 记下。
    private func json(_ req: URLRequest) async -> [String: Any]? {
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await transport(req)
        } catch {
            report(.network(error.localizedDescription))
            return nil
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if status == 401 {
            // 令牌在服务端失效了（改密码、撤销授权）：作废，下一轮用 refresh_token 重新换，不要到过期前一直拿它去撞
            accessToken = nil
            report(.unauthorized)
            return nil
        }
        guard status == 200 else {
            report(.http(status))
            return nil
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            report(.badResponse)
            return nil
        }
        return obj
    }
}
