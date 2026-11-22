import XCTest

// 令牌过期以后怎么拿额度（ClaudeQuotaFetch + ClaudeLoginRecovery）：被拒的令牌不再直接查询（重启后也不），
// 请 Claude Code 跑 `claude -p /usage` 刷新（10 分钟最多一次、一次只跑一个），读它缓存的额度，够新才用。
// 回归背景（2026-11-22）：用户改用 Claude Desktop 以后，终端版 Claude Code 的令牌两天没人刷新，CC Usage 拿着过期令牌
// 每 5 分钟查一次、次次 401，又招来 429，菜单栏的 7D 一直是「—」。
// 钥匙串、全局配置、官方接口、claude 命令全换成假的：不联网、不起进程、不碰 UserDefaults。
final class ClaudeLoginRecoveryTests: XCTestCase {
    /// 外部世界：钥匙串里的令牌、Claude Code 的全局配置、官方接口、`claude -p /usage`，外加落盘的被拒指纹。
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _token = "token-A"
        private var _profile: Data?
        private var _stored: String?
        private var _queries: [String] = []
        private var _reports: [QuotaStatus] = []
        private var _runs = 0
        /// 官方接口怎么回：按令牌给结果。
        var answer: @Sendable (String) -> Result<[QuotaTier], QuotaStatus> = { _ in .failure(.expired) }
        /// `claude -p /usage` 跑的时候做什么（写缓存、换令牌、卡住…）。
        var onRun: @Sendable () -> ClaudeUsageRun = { .finished(status: 0) }

        var token: String {
            get { lock.withLock { _token } }
            set { lock.withLock { _token = newValue } }
        }
        var profile: Data? {
            get { lock.withLock { _profile } }
            set { lock.withLock { _profile = newValue } }
        }
        var stored: String? {
            get { lock.withLock { _stored } }
            set { lock.withLock { _stored = newValue } }
        }
        var queries: [String] { lock.withLock { _queries } }
        var reports: [QuotaStatus] { lock.withLock { _reports } }
        var runs: Int { lock.withLock { _runs } }

        func query(_ token: String) -> Result<[QuotaTier], QuotaStatus> {
            lock.withLock { _queries.append(token) }
            return answer(token)
        }
        func report(_ status: QuotaStatus) { lock.withLock { _reports.append(status) } }
        func run() -> ClaudeUsageRun {
            lock.withLock { _runs += 1 }
            return onRun()
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func advance(_ seconds: TimeInterval) { lock.withLock { t = t.addingTimeInterval(seconds) } }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// Claude Code 的全局配置：当前登录 acc-1；`cacheFor` 给了就带一份那个账号、在 `fetchedAt` 取的额度缓存。
    private static func profile(account: String? = "acc-1", cacheFor: String? = nil, fetchedAt: Date? = nil,
                                percent: Double = 21) -> Data {
        var root: [String: Any] = [:]
        if let account { root["oauthAccount"] = ["accountUuid": account] }
        if let cacheFor, let fetchedAt {
            root["cachedUsageUtilization"] = [
                "accountUuid": cacheFor, "fetchedAtMs": fetchedAt.timeIntervalSince1970 * 1000,
                "utilization": ["seven_day": ["utilization": percent, "resets_at": NSNull()]],
            ]
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }

    private func recovery(_ world: World, _ clock: Clock) -> ClaudeLoginRecovery {
        ClaudeLoginRecovery(store: RejectedTokenStore(load: { world.stored }, save: { world.stored = $0 }),
                            readProfile: { world.profile }, runUsage: { world.run() }, now: { clock.now })
    }

    private func fetch(_ world: World, _ recovery: ClaudeLoginRecovery) -> ClaudeQuotaFetch {
        ClaudeQuotaFetch(
            readCredential: { .success(ClaudeCredential(accessToken: world.token, subscriptionType: "max", rateLimitTier: nil)) },
            planDisplayName: { "Ultra" }, query: { world.query($0) }, report: { world.report($0) },
            recovery: recovery)
    }

    private func percents(_ result: Result<[QuotaTier], QuotaStatus>) -> [Double]? {
        try? result.get().map(\.utilization)
    }

    // 401 → 请 Claude Code 刷新 → 用它刚缓存的额度（带套餐名），不报失败；令牌换新以后恢复直接查询，不再跑 claude。
    // 负责杀的变异体：401 后不跑 claude（额度一直「—」）/ 缓存额度没带套餐名 / 换了令牌还当被拒的跳过。
    func testExpiredTokenRecoversThroughClaudeCode() async {
        let world = World(), clock = Clock(t0)
        world.profile = Self.profile()
        world.answer = { $0 == "token-B" ? .success([QuotaTier(name: "seven_day", utilization: 22, resetsAt: nil)]) : .failure(.expired) }
        world.onRun = {
            world.profile = Self.profile(cacheFor: "acc-1", fetchedAt: clock.now)
            world.token = "token-B"                             // Claude Code 刷新了令牌，写回钥匙串
            return .finished(status: 0)
        }
        let recovery = recovery(world, clock)

        let first = await fetch(world, recovery).run()
        XCTAssertEqual(percents(first), [21])
        XCTAssertEqual(try? first.get().first?.planLabel, "Ultra")
        XCTAssertEqual(world.runs, 1)
        XCTAssertEqual(world.reports, [], "恢复成功不算失败")

        clock.advance(300)
        let second = await fetch(world, recovery).run()
        XCTAssertEqual(percents(second), [22])
        XCTAssertEqual(world.queries, ["token-A", "token-B"])
        XCTAssertEqual(world.runs, 1, "令牌好了就不再跑 claude")
    }

    // 刷新不成（要重新登录）：同一份令牌之后不再直接查询，重启（新实例、同一份落盘）也不查；换了令牌立刻恢复。
    // 负责杀的变异体：被拒的令牌照查（又是一串 401 招来 429）/ 指纹不落盘（重启后先打一次 401）/ 落盘的是令牌本身。
    func testRejectedTokenIsNotQueriedAgainEvenAfterARestart() async {
        let world = World(), clock = Clock(t0)
        world.profile = Self.profile()
        world.onRun = { .finished(status: 1) }
        let first = recovery(world, clock)
        let result = await fetch(world, first).run()
        XCTAssertEqual(result, .failure(.expired))
        XCTAssertEqual(world.reports, [.expired])
        let stored = world.stored
        XCTAssertNotNil(stored)
        XCTAssertNotEqual(stored, "token-A")
        XCTAssertFalse(stored?.contains("token") ?? true)

        clock.advance(300)
        _ = await fetch(world, first).run()
        clock.advance(300)
        _ = await fetch(world, recovery(world, clock)).run()     // 重启
        XCTAssertEqual(world.queries, ["token-A"], "被拒过的令牌一次也不再查")

        world.token = "token-C"                                    // 用户重新登录了
        world.answer = { _ in .success([QuotaTier(name: "seven_day", utilization: 5, resetsAt: nil)]) }
        let back = await fetch(world, recovery(world, clock)).run()
        XCTAssertEqual(percents(back), [5])
        XCTAssertEqual(world.queries, ["token-A", "token-C"])
    }

    // claude 10 分钟最多跑一次（失败也算），中间用它上次缓存的额度；缓存过了 10 分 45 秒就报过期，不拿旧数糊弄。
    // 负责杀的变异体：每次都跑 claude / 失败的那次不算（接连重跑）/ 不看缓存新旧（登录失效了还显示老数）。
    func testRunsAtMostEveryTenMinutesAndOnlyTrustsAFreshCache() async {
        let world = World(), clock = Clock(t0)
        world.profile = Self.profile()
        world.onRun = {
            world.profile = Self.profile(cacheFor: "acc-1", fetchedAt: clock.now, percent: 30)
            return .finished(status: 0)
        }
        let recovery = recovery(world, clock)
        let fetch = fetch(world, recovery)

        var result = await fetch.run()
        XCTAssertEqual(percents(result), [30])
        clock.advance(300)
        result = await fetch.run()
        XCTAssertEqual(percents(result), [30], "缓存 300 秒前的，还新")
        XCTAssertEqual(world.runs, 1)
        clock.advance(300)
        result = await fetch.run()
        XCTAssertEqual(percents(result), [30])
        XCTAssertEqual(world.runs, 2, "满 10 分钟再跑一次")

        world.onRun = { .failed }                                  // 之后 claude 跑不成了
        clock.advance(700)
        result = await fetch.run()
        XCTAssertEqual(result, .failure(.expired), "上次的缓存已经 700 秒，不再信")
        XCTAssertEqual(world.runs, 3)
        clock.advance(300)
        _ = await fetch.run()
        XCTAssertEqual(world.runs, 3, "失败的那次也算，10 分钟内不重跑")
    }

    // 缓存是别的账号的、配置里没有登录账号：都不用；没有账号时连 claude 都不跑（同上游 default_owner 为空）。
    // 负责杀的变异体：不核对账号 / 没有账号也跑 claude。
    func testCacheOfAnotherAccountOrNoAccountIsNotUsed() async {
        let world = World(), clock = Clock(t0)
        world.profile = Self.profile(account: "acc-1", cacheFor: "acc-2", fetchedAt: t0)
        let other = await fetch(world, recovery(world, clock)).run()
        XCTAssertEqual(other, .failure(.expired))
        XCTAssertEqual(world.runs, 1)

        let nobody = World()
        nobody.profile = Self.profile(account: nil, cacheFor: "acc-1", fetchedAt: t0)
        let anonymous = await fetch(nobody, recovery(nobody, clock)).run()
        XCTAssertEqual(anonymous, .failure(.expired))
        XCTAssertEqual(nobody.runs, 0)
        let missing = World()
        let noProfile = await fetch(missing, recovery(missing, clock)).run()
        XCTAssertEqual(noProfile, .failure(.expired))
        XCTAssertEqual(missing.runs, 0)
    }

    // 只有令牌被拒才请 Claude Code：限流、网络错误、没有凭据都原样交回（429 要按 Retry-After 暂停），不跑 claude、不记指纹。
    // 负责杀的变异体：429 也去跑 claude / 网络抖一下就把令牌记成被拒的。
    func testOnlyARejectedTokenTriggersClaudeCode() async {
        for status in [QuotaStatus.rateLimited(retryAfter: 900), .failed("网络错误")] {
            let world = World(), clock = Clock(t0)
            world.profile = Self.profile(cacheFor: "acc-1", fetchedAt: t0)
            world.answer = { _ in .failure(status) }
            let result = await fetch(world, recovery(world, clock)).run()
            XCTAssertEqual(result, .failure(status))
            XCTAssertEqual(world.runs, 0)
            XCTAssertNil(world.stored)
            XCTAssertEqual(world.reports, [status])
        }
        let world = World(), clock = Clock(t0)
        let noLogin = ClaudeQuotaFetch(readCredential: { .failure(.noCredential) }, planDisplayName: { nil },
                                       query: { world.query($0) }, report: { world.report($0) },
                                       recovery: recovery(world, clock))
        let result = await noLogin.run()
        XCTAssertEqual(result, .failure(.noCredential))
        XCTAssertEqual(world.runs, 0)
        XCTAssertEqual(world.queries, [])
    }

    // 一次只跑一个：正在跑的时候又来一次，等着同一次跑完、读同一份缓存，不另起进程。
    // 负责杀的变异体：不等在跑的那次（第二个读到旧缓存报过期）/ 另起一个 claude。
    func testConcurrentRecoveriesShareOneRun() async throws {
        let world = World(), clock = Clock(t0)
        world.profile = Self.profile()
        let started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        world.onRun = {
            started.signal()
            release.wait()
            world.profile = Self.profile(cacheFor: "acc-1", fetchedAt: clock.now)
            return .finished(status: 0)
        }
        let recovery = recovery(world, clock)
        async let first = recovery.recover()
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { started.wait(); continuation.resume() }
        }
        async let second = recovery.recover()
        try await Task.sleep(nanoseconds: 200_000_000)
        release.signal()
        let (a, b) = await (first, second)
        XCTAssertEqual(a?.map(\.utilization), [21])
        XCTAssertEqual(b?.map(\.utilization), [21])
        XCTAssertEqual(world.runs, 1)
    }

    // 指纹：同一令牌稳定、不同令牌不同，16 位十六进制，看不出令牌。
    // 负责杀的变异体：指纹随进程变（重启后认不出被拒的令牌）/ 截得太短撞车。
    func testFingerprintIsStableAndHidesTheToken() {
        let a = TokenFingerprint.of("sk-ant-oat01-aaaa"), b = TokenFingerprint.of("sk-ant-oat01-aaab")
        XCTAssertEqual(a, TokenFingerprint.of("sk-ant-oat01-aaaa"))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 16)
        XCTAssertTrue(a.allSatisfy(\.isHexDigit))
        XCTAssertFalse(a.contains("sk-ant"))
    }
}
