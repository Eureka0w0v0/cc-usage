import XCTest

/// 官方额度查询的失败路径：网络、401、解析失败要说得清原因，401 要作废缓存的 access_token。
final class AntigravityQuotaTests: XCTestCase {
    private enum Route { case token, project, summary }

    private struct Reply: Sendable {
        var status = 200
        var body = "{}"
        var error: URLError.Code?
    }

    /// 按路径回话，记下每条路径被打了几次。
    private final class Fake: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [Route: Reply] = [
            .token: Reply(body: #"{"access_token":"t","expires_in":3600}"#),
            .project: Reply(body: #"{"cloudaicompanionProject":"p"}"#),
            .summary: Reply(body: AntigravityQuotaTests.goodSummary),
        ]
        private var counts: [Route: Int] = [:]
        private var failures: [AntigravityQuota.Failure] = []

        func set(_ route: Route, _ reply: Reply) { lock.withLock { replies[route] = reply } }
        func count(_ route: Route) -> Int { lock.withLock { counts[route] ?? 0 } }
        func record(_ f: AntigravityQuota.Failure) { lock.withLock { failures.append(f) } }
        var reported: [AntigravityQuota.Failure] { lock.withLock { failures } }

        func handle(_ req: URLRequest) throws -> (Data, URLResponse) {
            let url = try XCTUnwrap(req.url)
            let route: Route = url.host == "oauth2.googleapis.com" ? .token
                : url.path.hasSuffix("loadCodeAssist") ? .project : .summary
            let reply: Reply = lock.withLock {
                counts[route, default: 0] += 1
                return replies[route]!
            }
            if let code = reply.error { throw URLError(code) }
            let resp = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
            return (Data(reply.body.utf8), resp)
        }
    }

    private static let goodSummary = #"{"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":0.75}]}]}"#

    private let fake = Fake()

    private func quota(refreshToken: String? = "1//stored") -> AntigravityQuota {
        let fake = fake
        return AntigravityQuota(transport: { try fake.handle($0) }, refreshToken: { refreshToken },
                                agyVersion: { "1.4.6" }, minInterval: 0, onFailure: { fake.record($0) })
    }

    func testHappyPathReturnsTiersAndReportsNothing() async {
        let tiers = await quota().latest()
        XCTAssertEqual(tiers.map(\.bucketId), ["gemini-weekly"])
        XCTAssertEqual(tiers.first?.usedPercent, 25)
        XCTAssertEqual(fake.reported, [])
    }

    func testAccessTokenIsReusedUntilItExpires() async {
        let q = quota()
        _ = await q.latest()
        _ = await q.latest()
        XCTAssertEqual(fake.count(.token), 1)
    }

    /// 负责杀的变异体：401 不作废缓存的 access_token，到过期前每轮都拿同一个失效令牌去撞。
    func testUnauthorizedDropsTheCachedTokenSoTheNextRoundRefreshes() async {
        let q = quota()
        _ = await q.latest()
        XCTAssertEqual(fake.count(.token), 1)
        fake.set(.summary, Reply(status: 401))
        _ = await q.latest()
        fake.set(.summary, Reply(body: Self.goodSummary))
        let tiers = await q.latest()
        XCTAssertEqual(fake.count(.token), 2, "401 之后要重新换令牌")
        XCTAssertEqual(tiers.count, 1)
    }

    func testFailureReasonsAreReported() async {
        fake.set(.summary, Reply(error: .notConnectedToInternet))
        let q = quota()
        _ = await q.latest()
        fake.set(.summary, Reply(status: 500))
        _ = await q.latest()
        fake.set(.summary, Reply(status: 401))
        _ = await q.latest()
        fake.set(.summary, Reply(body: "not json"))
        _ = await q.latest()
        fake.set(.summary, Reply(body: #"{"groups":[]}"#))
        _ = await q.latest()
        XCTAssertEqual(fake.reported.count, 5)
        guard case .network = fake.reported.first else { return XCTFail("\(fake.reported)") }
        XCTAssertEqual(Array(fake.reported.dropFirst()), [.http(500), .unauthorized, .badResponse, .unrecognizedSummary])
    }

    func testMissingCredentialIsReported() async {
        _ = await quota(refreshToken: nil).latest()
        XCTAssertEqual(fake.reported, [.noCredential])
    }

    /// 每 30 秒一轮：断网一整天不能写几千条一样的日志；恢复后再坏要重新记。
    func testSameFailureIsReportedOnceUntilItRecovers() async {
        fake.set(.summary, Reply(status: 500))
        let q = quota()
        _ = await q.latest()
        _ = await q.latest()
        XCTAssertEqual(fake.reported, [.http(500)])
        fake.set(.summary, Reply(body: Self.goodSummary))
        _ = await q.latest()
        fake.set(.summary, Reply(status: 500))
        _ = await q.latest()
        XCTAssertEqual(fake.reported, [.http(500), .http(500)])
    }

    /// stale-if-error：失败时保留上次结果，不闪空。
    func testFailureKeepsTheLastGoodTiers() async {
        let q = quota()
        _ = await q.latest()
        fake.set(.summary, Reply(status: 500))
        let tiers = await q.latest()
        XCTAssertEqual(tiers.map(\.bucketId), ["gemini-weekly"])
    }
}
