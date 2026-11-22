import XCTest

// Claude Code 缓存的额度（全局配置 `~/.claude.json` 里的 cachedUsageUtilization）：只认当前账号的、够新的。
// 对齐 cc-switch `claude_account/usage.rs` 的 read_cached 用例与 `subscription.rs` 的 account_quota_with_cache。
// 夹具里的账号和百分比都是编的。
final class ClaudeUsageCacheTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func data(_ object: [String: Any]) -> Data {
        // 夹具是写死的字面量，序列化失败只可能是用例本身写错
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private func profile(cache: [String: Any]?, account: Any? = "acc-1") -> Data {
        var root: [String: Any] = ["numStartups": 3]
        if let account { root["oauthAccount"] = ["accountUuid": account, "organizationUuid": "org-1"] }
        if let cache { root["cachedUsageUtilization"] = cache }
        return data(root)
    }

    private let usage: [String: Any] = ["seven_day": ["utilization": 21, "resets_at": "2026-11-27T06:00:00Z"]]

    // 负责杀的变异体：不核对账号（别的号的额度显示成这个号的）/ 取数时刻读错 / utilization 没解析。
    func testReadsOnlyTheAccountsOwnCache() throws {
        let doc = profile(cache: ["accountUuid": "acc-1", "fetchedAtMs": 1_800_000_000_000, "utilization": usage])
        let entry = try XCTUnwrap(ClaudeUsageCache.entry(fromProfile: doc, account: "acc-1"))
        XCTAssertEqual(entry.fetchedAt, t0)
        XCTAssertEqual(entry.tiers.map(\.name), ["seven_day"])
        XCTAssertEqual(entry.tiers.first?.utilization, 21)
        XCTAssertNil(ClaudeUsageCache.entry(fromProfile: doc, account: "acc-2"))
    }

    // 负责杀的变异体：缺账号、utilization 不是对象、取数时刻缺失或是字符串 / 布尔也认了（同上游只认数字）。
    func testMalformedEntriesAreNotACache() {
        let broken: [[String: Any]] = [
            ["fetchedAtMs": 1_800_000_000_000, "utilization": usage],
            ["accountUuid": "acc-1", "fetchedAtMs": 1_800_000_000_000, "utilization": [usage]],
            ["accountUuid": "acc-1", "fetchedAtMs": 1_800_000_000_000],
            ["accountUuid": "acc-1", "utilization": usage],
            ["accountUuid": "acc-1", "fetchedAtMs": "1800000000000", "utilization": usage],
            ["accountUuid": "acc-1", "fetchedAtMs": true, "utilization": usage],
            ["accountUuid": 1, "fetchedAtMs": 1_800_000_000_000, "utilization": usage],
        ]
        for cache in broken {
            XCTAssertNil(ClaudeUsageCache.entry(fromProfile: profile(cache: cache), account: "acc-1"), "\(cache)")
        }
        XCTAssertNil(ClaudeUsageCache.entry(fromProfile: profile(cache: nil), account: "acc-1"))
    }

    // 负责杀的变异体：小数毫秒不认（上游 as_i64 不行再 as_f64）。
    func testFractionalMillisecondsAreAccepted() throws {
        let doc = profile(cache: ["accountUuid": "acc-1", "fetchedAtMs": 1_800_000_000_500.5, "utilization": usage])
        let entry = try XCTUnwrap(ClaudeUsageCache.entry(fromProfile: doc, account: "acc-1"))
        XCTAssertEqual(entry.fetchedAt.timeIntervalSince1970, 1_800_000_000.5005, accuracy: 0.0001)
    }

    // 负责杀的变异体：坏 JSON、顶层不是对象时崩溃或给出账号。
    func testUnreadableProfileHasNothing() {
        for bad in [Data("not json".utf8), Data("[1,2]".utf8), Data()] {
            XCTAssertNil(ClaudeUsageCache.accountUuid(fromProfile: bad))
            XCTAssertNil(ClaudeUsageCache.entry(fromProfile: bad, account: "acc-1"))
        }
    }

    // 当前账号：`oauthAccount.accountUuid` 去首尾空白；空串、缺失、不是字符串都当没有（同上游 identity_from_profile）。
    // 负责杀的变异体：不去空白 / 空串当成账号。
    func testAccountUuidIsTrimmedAndRequired() {
        XCTAssertEqual(ClaudeUsageCache.accountUuid(fromProfile: profile(cache: nil, account: "  acc-1\n")), "acc-1")
        XCTAssertNil(ClaudeUsageCache.accountUuid(fromProfile: profile(cache: nil, account: "   ")))
        XCTAssertNil(ClaudeUsageCache.accountUuid(fromProfile: profile(cache: nil, account: 42)))
        XCTAssertNil(ClaudeUsageCache.accountUuid(fromProfile: profile(cache: nil, account: nil)))
    }

    // 只信 10 分 45 秒内的：正好到点还算新，再晚一秒不算；取数时刻在将来（时钟回拨）同上游算新。
    // 负责杀的变异体：比较写成 <（正好到点不算）/ 时限写错 / 拿绝对值比（将来的不算）。
    func testFreshnessBoundary() {
        let entry = ClaudeUsageCache.Entry(fetchedAt: t0, tiers: [])
        XCTAssertEqual(ClaudeUsageCache.maxAge, 645)
        XCTAssertTrue(ClaudeUsageCache.isFresh(entry, now: t0.addingTimeInterval(645)))
        XCTAssertFalse(ClaudeUsageCache.isFresh(entry, now: t0.addingTimeInterval(646)))
        XCTAssertTrue(ClaudeUsageCache.isFresh(entry, now: t0.addingTimeInterval(-3600)))
    }

    // 缓存里的 utilization 和官方接口同一个结构，走同一套解析：模型专属周限额（limits[]）一样认。
    // 负责杀的变异体：缓存另写了一套只认顶层窗口的解析。
    func testUtilizationIsParsedLikeTheAPIResponse() throws {
        let utilization: [String: Any] = [
            "seven_day": ["utilization": 21, "resets_at": NSNull()],
            "limits": [["kind": "weekly_scoped", "group": "weekly", "percent": 3,
                        "scope": ["model": ["display_name": "Fable"], "surface": NSNull()]]],
        ]
        let doc = profile(cache: ["accountUuid": "acc-1", "fetchedAtMs": 1_800_000_000_000, "utilization": utilization])
        let entry = try XCTUnwrap(ClaudeUsageCache.entry(fromProfile: doc, account: "acc-1"))
        XCTAssertEqual(entry.tiers.map(\.name), ["seven_day", "seven_day_fable"])
        XCTAssertEqual(entry.tiers.map(\.utilization), [21, 3])
    }
}
