import XCTest

// 额度缓存（QuotaCache）：查询闸门、限流暂停、落盘与重启。时钟和存储都注入，不联网、不碰 UserDefaults。
final class QuotaCacheTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: Date
        init(_ t: Date) { self.t = t }
        var now: Date { lock.withLock { t } }
        func advance(_ seconds: TimeInterval) { lock.withLock { t = t.addingTimeInterval(seconds) } }
    }

    private final class Memory: @unchecked Sendable {
        private let lock = NSLock()
        private var value: QuotaSnapshot?
        var snapshot: QuotaSnapshot? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
        var store: QuotaSnapshotStore { QuotaSnapshotStore(load: { self.snapshot }, save: { self.snapshot = $0 }) }
    }

    /// 按顺序交出预设的结果，并记下被调了几次。
    private final class Fetcher: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Result<[QuotaTier], QuotaStatus>]
        private var count = 0
        init(_ results: [Result<[QuotaTier], QuotaStatus>]) { self.results = results }
        var calls: Int { lock.withLock { count } }
        func next() -> Result<[QuotaTier], QuotaStatus> {
            lock.withLock {
                count += 1
                return results.isEmpty ? .failure(.failed("没有预设结果")) : results.removeFirst()
            }
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func tier(_ pct: Double, name: String = "seven_day", resetIn: TimeInterval = 7 * 86_400) -> QuotaTier {
        QuotaTier(name: name, utilization: pct, resetsAt: t0.addingTimeInterval(resetIn))
    }

    // 429 后按 Retry-After 暂停：暂停期间定时读取和手动刷新都不打接口，到点后恢复。
    // 负责杀的变异体：429 没进闸门（过了 5 分钟照打）/ 手动刷新绕过暂停 / 429 清空了上次的数。
    func testRateLimitPausesFetchingUntilRetryAfter() async {
        let clock = Clock(t0), memory = Memory()
        let fetcher = Fetcher([.success([tier(40)]), .failure(.rateLimited(retryAfter: 3600)), .success([tier(55)])])
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        var shown = await cache.read { fetcher.next() }
        XCTAssertEqual(shown.map(\.utilization), [40])
        clock.advance(300)
        shown = await cache.read { fetcher.next() }             // 第二次查询拿到 429
        XCTAssertEqual(shown.map(\.utilization), [40], "限流时保留上次的数")
        clock.advance(600)                                       // 过了 5 分钟间隔，但还在暂停中
        _ = await cache.read { fetcher.next() }
        _ = await cache.forceRefresh { fetcher.next() }
        XCTAssertEqual(fetcher.calls, 2, "暂停期间一次都不打")
        clock.advance(3000)                                      // 429 之后满 3600 秒
        shown = await cache.read { fetcher.next() }
        XCTAssertEqual(fetcher.calls, 3)
        XCTAssertEqual(shown.map(\.utilization), [55])
    }

    // 重启（新实例、同一份存储）：先显示上次成功的数，限流暂停跟着落盘，到点前不打接口。
    // 负责杀的变异体：额度不落盘（重启后码片空着）/ 暂停时刻不落盘（重启立刻再打）。
    func testRestartKeepsLastTiersAndThePause() async {
        let clock = Clock(t0), memory = Memory()
        let first = Fetcher([.success([tier(40)]), .failure(.rateLimited(retryAfter: 3600))])
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        _ = await cache.read { first.next() }
        clock.advance(300)
        _ = await cache.read { first.next() }                    // 429，暂停到 t0 + 3900
        clock.advance(600)
        let restarted = QuotaCache(store: memory.store, now: { clock.now })
        let second = Fetcher([.success([tier(70)])])
        var shown = await restarted.read { second.next() }
        XCTAssertEqual(shown.map(\.utilization), [40], "重启后先显示上次成功的数")
        _ = await restarted.forceRefresh { second.next() }
        XCTAssertEqual(second.calls, 0, "暂停跟着落盘，重启后也不打")
        clock.advance(3000)
        shown = await restarted.read { second.next() }
        XCTAssertEqual(second.calls, 1)
        XCTAssertEqual(shown.map(\.utilization), [70])
    }

    // 重启时上次查询还不到 5 分钟：不立刻再打（每次重启都多打一次，正是这次被限流的推手之一）。
    // 负责杀的变异体：上次查询时刻不落盘。
    func testRestartWithinTheIntervalDoesNotRefetch() async {
        let clock = Clock(t0), memory = Memory()
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        _ = await cache.read { .success([self.tier(40)]) }
        clock.advance(120)
        let restarted = QuotaCache(store: memory.store, now: { clock.now })
        let fetcher = Fetcher([.success([tier(70)])])
        let shown = await restarted.read { fetcher.next() }
        XCTAssertEqual(fetcher.calls, 0)
        XCTAssertEqual(shown.map(\.utilization), [40])
    }

    // 查询失败后马上重启：上次查询时刻在发请求前就落了盘，照样不立刻再打。
    // 负责杀的变异体：只在成功 / 429 时落盘（失败的那次查询时刻丢了，重启后立刻再打）。
    func testRestartAfterAFailedAttemptStillWaits() async {
        let clock = Clock(t0), memory = Memory()
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        _ = await cache.read { .failure(.failed("网络错误")) }
        clock.advance(60)
        let restarted = QuotaCache(store: memory.store, now: { clock.now })
        let fetcher = Fetcher([.success([tier(70)])])
        _ = await restarted.read { fetcher.next() }
        XCTAssertEqual(fetcher.calls, 0)
    }

    // 搭上一次在途请求、而那次请求失败：搭车方也拿上次成功的数，不是空数组（同一次刷新里菜单栏和主窗口要一致）。
    // 两个信号控制先后：第一次请求开始后才发第二次读取（它一定搭上在途的那次），等它搭上了再放行第一次请求。
    // 负责杀的变异体：搭车方失败时给空 / 搭车方另发一次请求。
    func testJoiningAFailedInflightRequestKeepsLastTiers() async throws {
        let clock = Clock(t0), memory = Memory()
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        _ = await cache.read { .success([self.tier(40)]) }
        clock.advance(300)
        let (started, startedSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let slow: @Sendable () async -> Result<[QuotaTier], QuotaStatus> = {
            startedSignal.yield()
            for await _ in release { break }
            return .failure(.failed("网络错误"))
        }
        async let first = cache.read(fetch: slow)
        for await _ in started { break }
        let fetcher = Fetcher([.success([tier(70)])])
        async let second = cache.read { fetcher.next() }
        try await Task.sleep(nanoseconds: 200_000_000)
        releaseSignal.yield()
        let (a, b) = await (first, second)
        XCTAssertEqual(a.map(\.utilization), [40])
        XCTAssertEqual(b.map(\.utilization), [40], "搭车方同样保留上次的数")
        XCTAssertEqual(fetcher.calls, 0, "搭车，不另发请求")
    }

    // 过了重置时刻的档不再显示（那个窗口已经结束）；其它失败和空结果都保留上次成功的数。
    // 负责杀的变异体：不按重置时刻过滤 / 空结果冲掉了上次的数 / 鉴权失败冲掉了上次的数。
    func testStaleTiersExpireAndFailuresKeepTheRest() async {
        let clock = Clock(t0), memory = Memory()
        let fetcher = Fetcher([.success([tier(80, name: "five_hour", resetIn: 600), tier(40)]),
                               .failure(.expired), .success([])])
        let cache = QuotaCache(store: memory.store, now: { clock.now })
        _ = await cache.read { fetcher.next() }
        clock.advance(300)
        var shown = await cache.read { fetcher.next() }          // 鉴权失败
        XCTAssertEqual(shown.map(\.name), ["five_hour", "seven_day"])
        clock.advance(600)                                       // five_hour 的重置时刻已过
        shown = await cache.read { fetcher.next() }              // 空结果
        XCTAssertEqual(shown.map(\.name), ["seven_day"])
        XCTAssertEqual(fetcher.calls, 3)
    }
}
