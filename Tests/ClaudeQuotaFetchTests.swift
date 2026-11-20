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
        let tiers = try? await fetch(credential: .success(credential), query: .success([tier])).run().get()
        XCTAssertEqual(tiers?.first?.planLabel, "Ultra")
        XCTAssertEqual(log.all, [])
    }

    /// 负责杀的变异体：读不到凭据时原因被丢掉，额度徽标一直是「—」却无从排查。
    func testMissingCredentialIsReported() async {
        let result = await fetch(credential: .failure(.noCredential)).run()
        XCTAssertEqual(result, .failure(.noCredential))
        XCTAssertEqual(log.all, [.noCredential])
    }

    func testExpiredTokenIsReported() async {
        let result = await fetch(credential: .success(credential), query: .failure(.expired)).run()
        XCTAssertEqual(result, .failure(.expired))
        XCTAssertEqual(log.all, [.expired])
    }

    func testNetworkFailureKeepsItsReason() async {
        _ = await fetch(credential: .success(credential), query: .failure(.failed("API 错误 (HTTP 500)"))).run()
        XCTAssertEqual(log.all, [.failed("API 错误 (HTTP 500)")])
    }

    /// 响应分类（ClaudeUsageAPI.interpret）。负责杀的变异体：429 当成一般的 HTTP 错误（拿不到 Retry-After）/
    /// 401、403 不算令牌问题 / 2xx 的坏响应体不报解析失败。
    func testResponsesAreClassified() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let body = Data(#"{"seven_day":{"utilization":42,"resets_at":null}}"#.utf8)
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 429, retryAfter: "1800", body: Data(), now: now),
                       .failure(.rateLimited(retryAfter: 1800)))
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 429, retryAfter: nil, body: Data(), now: now),
                       .failure(.rateLimited(retryAfter: nil)))
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 401, retryAfter: nil, body: Data(), now: now), .failure(.expired))
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 403, retryAfter: nil, body: Data(), now: now), .failure(.expired))
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 500, retryAfter: "60", body: Data(), now: now),
                       .failure(.failed("API 错误 (HTTP 500)")))
        XCTAssertEqual(ClaudeUsageAPI.interpret(status: 200, retryAfter: nil, body: Data("x".utf8), now: now),
                       .failure(.failed("解析 API 响应失败")))
        let tiers = try? ClaudeUsageAPI.interpret(status: 200, retryAfter: nil, body: body, now: now).get()
        XCTAssertEqual(tiers?.map(\.name), ["seven_day"])
        XCTAssertEqual(tiers?.first?.utilization, 42)
    }

    /// 负责杀的变异体：429 被吞成一般失败（QuotaCache 拿不到 Retry-After，退回每 5 分钟打一次）。
    func testRateLimitIsPassedOnWithItsRetryAfter() async {
        let result = await fetch(credential: .success(credential), query: .failure(.rateLimited(retryAfter: 900))).run()
        XCTAssertEqual(result, .failure(.rateLimited(retryAfter: 900)))
        XCTAssertEqual(log.all, [.rateLimited(retryAfter: 900)])
    }
}
