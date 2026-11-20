import XCTest

// Claude 额度接口的查询闸门（QuotaThrottle）、Retry-After 解析、落盘快照（QuotaSnapshot）。
// 回归背景（2026-11-20）：账号被限流后，CC Usage 不看 Retry-After、照旧每 5 分钟打一次；额度只在内存里，
// 重启后限流没解除前菜单栏的 7D 码片一直是空的。
final class QuotaThrottleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // 负责杀的变异体：间隔判断写成 >（正好 5 分钟不放行）/ 从没查过也不放行 / 手动刷新也受 5 分钟限制。
    func testFiveMinuteSpacing() {
        var throttle = QuotaThrottle()
        XCTAssertTrue(throttle.mayFetch(now: t0, force: false), "从没查过")
        throttle.recordAttempt(at: t0)
        XCTAssertFalse(throttle.mayFetch(now: t0.addingTimeInterval(299), force: false))
        XCTAssertTrue(throttle.mayFetch(now: t0.addingTimeInterval(300), force: false))
        XCTAssertTrue(throttle.mayFetch(now: t0.addingTimeInterval(1), force: true), "手动刷新不受间隔限制")
    }

    // 负责杀的变异体：不读 Retry-After（固定 30 分钟）/ 暂停期间手动刷新照打 / 到点后仍不放行。
    func testRateLimitPausesForRetryAfterEvenForManualRefresh() {
        var throttle = QuotaThrottle()
        throttle.recordAttempt(at: t0)
        throttle.recordRateLimited(at: t0, retryAfter: 3600)
        XCTAssertEqual(throttle.blockedUntil, t0.addingTimeInterval(3600))
        XCTAssertFalse(throttle.mayFetch(now: t0.addingTimeInterval(3599), force: false))
        XCTAssertFalse(throttle.mayFetch(now: t0.addingTimeInterval(3599), force: true))
        XCTAssertTrue(throttle.mayFetch(now: t0.addingTimeInterval(3600), force: false))
    }

    // 负责杀的变异体：没给 Retry-After 就不暂停 / 默认时长写错 / 不钳上限（坏头把额度永久关掉）/ 负数不钳到 0。
    func testMissingOrAbsurdRetryAfterIsBounded() {
        var throttle = QuotaThrottle()
        throttle.recordRateLimited(at: t0, retryAfter: nil)
        XCTAssertEqual(throttle.blockedUntil, t0.addingTimeInterval(30 * 60))
        throttle.recordRateLimited(at: t0, retryAfter: 10 * 86_400)
        XCTAssertEqual(throttle.blockedUntil, t0.addingTimeInterval(6 * 3600))
        throttle.recordRateLimited(at: t0, retryAfter: -60)
        XCTAssertEqual(throttle.blockedUntil, t0)
        XCTAssertTrue(throttle.mayFetch(now: t0, force: false), "钳到 0 就等于不暂停")
    }

    // 负责杀的变异体：不认整数秒 / 不去空白 / 认了负数、小数或带单位的写法 / 不认 HTTP 日期 / 过去的日期给出负数。
    func testRetryAfterParsesSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 1_795_150_200)   // 2026-11-20 04:50:00 GMT
        XCTAssertEqual(RetryAfter.seconds("3135", now: now), 3135)
        XCTAssertEqual(RetryAfter.seconds("  120 ", now: now), 120)
        XCTAssertEqual(RetryAfter.seconds("0", now: now), 0)
        XCTAssertEqual(RetryAfter.seconds("Fri, 20 Nov 2026 05:00:00 GMT", now: now), 600)
        XCTAssertEqual(RetryAfter.seconds("Fri, 20 Nov 2026 04:40:00 GMT", now: now), 0)
        for bad in [nil, "", "   ", "-5", "1.5", "abc", "120s", "20 Nov 2026"] as [String?] {
            XCTAssertNil(RetryAfter.seconds(bad, now: now), String(describing: bad))
        }
    }

    // 负责杀的变异体：过了重置时刻的档照留（挂着过期百分比）/ 没有重置时刻的档被丢掉 / 正好到点算没过。
    func testSnapshotDropsTiersPastTheirReset() {
        let tiers = [
            QuotaTier(name: "five_hour", utilization: 80, resetsAt: t0.addingTimeInterval(-1)),
            QuotaTier(name: "seven_day", utilization: 40, resetsAt: t0.addingTimeInterval(3600)),
            QuotaTier(name: "seven_day_opus", utilization: 10, resetsAt: nil),
            QuotaTier(name: "seven_day_fable", utilization: 5, resetsAt: t0),
        ]
        XCTAssertEqual(QuotaSnapshot.live(tiers, now: t0).map(\.name), ["seven_day", "seven_day_opus"])
    }

    // 负责杀的变异体：落盘丢字段（套餐名、闸门状态）/ 坏数据不报错而是读成空快照。
    func testSnapshotRoundTripsThroughData() throws {
        let snapshot = QuotaSnapshot(
            tiers: [QuotaTier(name: "seven_day", utilization: 42.5, resetsAt: t0, planLabel: "Ultra")],
            lastAttempt: t0, blockedUntil: t0.addingTimeInterval(600))
        XCTAssertEqual(try QuotaSnapshot.decode(snapshot.encoded()), snapshot)
        XCTAssertThrowsError(try QuotaSnapshot.decode(Data("not json".utf8)))
    }
}
