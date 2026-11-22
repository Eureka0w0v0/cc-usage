import CryptoKit
import Foundation
import os

// 令牌过期以后怎么拿额度：对齐 cc-switch `subscription.rs` 的 get_local_claude_quota 过期分支（上游 v4.0.26 起），
// 外加被拒令牌的指纹。规则（参数、环境、缓存怎么认）在 Sources/Shared/Quota 的 ClaudeUsageCLI / ClaudeUsageCache，
// 这里管状态和起进程。

/// 令牌的指纹：SHA-256 前 8 字节的十六进制。落盘的是它，不是令牌本身。
enum TokenFingerprint {
    static func of(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// 被拒令牌指纹的落盘读写：App 用 UserDefaults，测试注入内存版。
struct RejectedTokenStore: Sendable {
    var load: @Sendable () -> String?
    var save: @Sendable (String) -> Void

    static let userDefaultsKey = "quota.claude.rejectedToken"

    static let userDefaults = RejectedTokenStore(
        load: { UserDefaults.standard.string(forKey: userDefaultsKey) },
        save: { UserDefaults.standard.set($0, forKey: userDefaultsKey) })
}

/// 跑一次 `claude -p /usage` 的结果。只进日志：用不用缓存看缓存够不够新（同上游）。
enum ClaudeUsageRun: Equatable, Sendable {
    case finished(status: Int32)
    case notInstalled
    /// 起不来，或 45 秒没结束（已杀掉）
    case failed
}

/// 令牌被官方接口拒了（401/403）以后怎么拿额度。
///
/// - 被拒的令牌记下指纹并落盘：之后读到的还是它，就不再发注定失败的请求。接连的 401 会招来 429，连同账号的
///   Claude Code 状态栏一起拿不到数（2026-11-22）；令牌一换立刻恢复直接查询。上游每次照查，这一条是本应用加的。
/// - 请 Claude Code 自己刷新：在默认的 `~/.claude` 里跑一次 `claude -p /usage`（同一账号 10 分钟最多一次，失败也算；
///   一次只跑一个，正在跑就等它），再读它缓存进全局配置的额度，10 分 45 秒内的才用。CC Usage 自己从不刷新令牌。
actor ClaudeLoginRecovery {
    static let shared = ClaudeLoginRecovery(store: .userDefaults, readProfile: { ClaudeConfigReader.profileData() },
                                            runUsage: { ClaudeUsageRunner.run() })

    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "quota")

    private var rejected: String?
    /// 上次跑 `/usage` 是为哪个账号、在什么时候。只在内存里（同上游 LAST_RUN）。
    private var lastRun: (account: String, at: Date)?
    private var running: Task<Void, Never>?
    private let store: RejectedTokenStore
    private let readProfile: @Sendable () -> Data?
    private let runUsage: @Sendable () -> ClaudeUsageRun
    private let now: @Sendable () -> Date

    init(store: RejectedTokenStore, readProfile: @escaping @Sendable () -> Data?,
         runUsage: @escaping @Sendable () -> ClaudeUsageRun, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.readProfile = readProfile
        self.runUsage = runUsage
        self.now = now
        rejected = store.load()
    }

    func isRejected(_ fingerprint: String) -> Bool {
        rejected == fingerprint
    }

    func reject(_ fingerprint: String) {
        guard rejected != fingerprint else { return }
        rejected = fingerprint
        store.save(fingerprint)
        Self.log.error("Claude 令牌被拒（HTTP 401/403），这份令牌不再直接查询，改请 Claude Code 刷新")
    }

    /// 令牌被拒以后的额度。配置里没有登录账号就不跑 claude（同上游 default_owner 为空）；该跑就跑一次 `/usage`；
    /// 再读这个账号的缓存，够新才用。读不到返回 nil，原因进日志。
    func recover() async -> [QuotaTier]? {
        guard let account = await Self.offloaded(readProfile).flatMap(ClaudeUsageCache.accountUuid(fromProfile:)) else {
            Self.log.error("Claude Code 配置里没有登录账号，没法请它刷新令牌")
            return nil
        }
        await refreshIfDue(account)
        guard let entry = await Self.offloaded(readProfile)
            .flatMap({ ClaudeUsageCache.entry(fromProfile: $0, account: account) }) else {
            Self.log.error("Claude Code 没有这个账号的额度缓存")
            return nil
        }
        let age = Int(now().timeIntervalSince(entry.fetchedAt))
        guard ClaudeUsageCache.isFresh(entry, now: now()) else {
            Self.log.error("Claude Code 的额度缓存是 \(age) 秒前的，太旧不用（只认 \(Int(ClaudeUsageCache.maxAge)) 秒内的）")
            return nil
        }
        Self.log.info("令牌过期，用 Claude Code 缓存的额度（\(age) 秒前）")
        return entry.tiers
    }

    /// 正在跑就等它跑完（上游 RUNNING 锁让同一账号的后来者直接读缓存；这里等同一次，两边拿到的一致）。
    /// 同一账号 10 分钟内跑过就不跑；开跑前先记时刻，失败也算一次。
    private func refreshIfDue(_ account: String) async {
        if let running {
            await running.value
            return
        }
        if let lastRun, lastRun.account == account,
           now().timeIntervalSince(lastRun.at) < ClaudeUsageCLI.runInterval { return }
        lastRun = (account, now())
        let task = Task { [runUsage] in Self.note(await Self.offloaded(runUsage)) }
        running = task
        await task.value
        running = nil
    }

    private static func note(_ run: ClaudeUsageRun) {
        switch run {
        case .finished(0): log.info("已请 Claude Code 刷新令牌（claude -p /usage）")
        case .finished(let status): log.error("claude -p /usage 退出码 \(status)")
        case .notInstalled: log.error("找不到 claude 命令，没法请 Claude Code 刷新令牌")
        case .failed: log.error("claude -p /usage 没跑成（起不来或 \(Int(ClaudeUsageCLI.runTimeout)) 秒没结束）")
        }
    }

    /// 阻塞的活（起子进程、读文件）放到 GCD 线程上：Swift 并发的协作线程总共就几个，被要等几十秒的子进程占住会拖慢全应用。
    private static func offloaded<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: work()) }
        }
    }
}

/// 起 `claude -p /usage`：找到 claude → 白名单环境 → 在 HOME 里跑，45 秒上限。阻塞，只在 GCD 线程上调。
enum ClaudeUsageRunner {
    static func run() -> ClaudeUsageRun {
        let home = NSHomeDirectory()
        let inherited = ProcessInfo.processInfo.environment
        guard let claude = locate(home: home, shell: inherited["SHELL"]) else { return .notInstalled }
        let env = ClaudeUsageCLI.environment(inherited: inherited, home: home,
                                             executableDir: (claude as NSString).deletingLastPathComponent)
        guard let output = ProcessRunner.run(URL(fileURLWithPath: claude), ClaudeUsageCLI.arguments, environment: env,
                                             currentDirectory: URL(fileURLWithPath: home),
                                             timeout: ClaudeUsageCLI.runTimeout) else { return .failed }
        return .finished(status: output.status)
    }

    /// 固定位置里第一个能执行的；都没有再问登录 shell（15 秒）。
    private static func locate(home: String, shell: String?) -> String? {
        let files = FileManager.default
        if let found = ClaudeUsageCLI.candidates(home: home).first(where: { files.isExecutableFile(atPath: $0) }) {
            return found
        }
        let invocation = ClaudeUsageCLI.locateInvocation(shell: shell)
        guard let output = ProcessRunner.run(URL(fileURLWithPath: invocation.executable), invocation.arguments,
                                             timeout: ClaudeUsageCLI.locateTimeout),
              output.status == 0,
              let path = ClaudeUsageCLI.locatedPath(fromShellOutput: String(decoding: output.stdout, as: UTF8.self)),
              files.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}
