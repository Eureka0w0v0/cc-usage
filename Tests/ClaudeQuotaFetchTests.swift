import XCTest

/// 官方额度的一次查询：失败时缓存层保留旧值，但原因不能丢。
final class ClaudeQuotaFetchTests: XCTestCase {
    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [QuotaStatus] = []
        func add(_ s: QuotaStatus) { lock.withLock { items.append(s) } }
        var all: [QuotaStatus] { lock.withLock { items } }
    }

    private let log = Log()
    private let credential = ClaudeCredential(accessToken: "t", subscriptionType: "max", rateLimitTier: nil)

    private func fetch(credential: Result<ClaudeCredential, QuotaStatus>,
                       query: Result<[QuotaTier], QuotaStatus> = .success([])) -> ClaudeQuotaFetch {
        let log = log
        return ClaudeQuotaFetch(readCredential: { credential }, planDisplayName: { "Ultra" }, query: { _ in query },
                                report: { log.add($0) })
    }

    func testSuccessAttachesThePlanAndReportsNothing() async {
        let tier = QuotaTier(name: "five_hour", utilization: 1, resetsAt: nil)
        let tiers = await fetch(credential: .success(credential), query: .success([tier])).run()
        XCTAssertEqual(tiers?.first?.planLabel, "Ultra")
        XCTAssertEqual(log.all, [])
    }

    /// 负责杀的变异体：读不到凭据时原因被丢掉，额度徽标一直是「—」却无从排查。
    func testMissingCredentialIsReported() async {
        let tiers = await fetch(credential: .failure(.noCredential)).run()
        XCTAssertNil(tiers)
        XCTAssertEqual(log.all, [.noCredential])
    }

    func testExpiredTokenIsReported() async {
        let tiers = await fetch(credential: .success(credential), query: .failure(.expired)).run()
        XCTAssertNil(tiers)
        XCTAssertEqual(log.all, [.expired])
    }

    func testNetworkFailureKeepsItsReason() async {
        _ = await fetch(credential: .success(credential), query: .failure(.failed("API 错误 (HTTP 429)"))).run()
        XCTAssertEqual(log.all, [.failed("API 错误 (HTTP 429)")])
    }
}
