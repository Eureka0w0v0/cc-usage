import XCTest

// Antigravity 官方额度（retrieveUserQuotaSummary）的解析规则，对齐 cc-switch
// subscription_agy.rs 的 tier_name / sort_order / collect_tiers 与 agy_account/quota.rs 的 parse_version。
final class AntigravityQuotaParsingTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    // 两组四档：Gemini 一组，Claude 和 GPT 共用一组，各有 5 小时和每周两个窗口；
    // 不管响应里的先后，按固定顺序排（Gemini 5H、Gemini 7D、Claude 5H、Claude 7D）。
    // 负责杀的变异体：不排序（保持响应顺序）/ 已用写成剩余（不做 1 − 剩余）。
    func testFourBucketsAreLabelledAndOrdered() throws {
        let root = json("""
        {"groups":[
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","remainingFraction":0.25,"resetTime":"2026-11-02T04:08:54Z","window":"weekly"},
            {"bucketId":"3p-5h","remainingFraction":0.9,"resetTime":"2026-10-26T09:00:00.123456Z"}]},
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","remainingFraction":1,"resetTime":"2026-11-02T04:08:54Z"},
            {"bucketId":"gemini-5h","remainingFraction":0.6}]}
        ]}
        """)
        let tiers = try XCTUnwrap(AntigravityQuotaParsing.parseSummary(root))
        XCTAssertEqual(tiers.map(\.bucketId), ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(tiers.map(\.label), ["Gemini 5H", "Gemini 7D", "Claude 5H", "Claude 7D"])
        XCTAssertEqual(tiers[0].usedPercent, 40, accuracy: 1e-9)
        XCTAssertEqual(tiers[1].usedPercent, 0, accuracy: 1e-9)
        XCTAssertEqual(tiers[2].usedPercent, 10, accuracy: 1e-9)
        XCTAssertEqual(tiers[3].usedPercent, 75, accuracy: 1e-9)
        XCTAssertNil(tiers[0].resetAt)
        // 带 6 位小数秒的重置时间也要认得（protobuf Timestamp 的 JSON）
        XCTAssertEqual(tiers[2].resetAt.map { Int($0.timeIntervalSince1970) },
                       ISO8601Lenient.epochSeconds("2026-10-26T09:00:00Z").map { Int($0) })
    }

    // 免费档账号实测只回两个每周桶（10-26）：有几档就显示几档。
    func testOnlyWeeklyBucketsArePassedThrough() throws {
        let root = json("""
        {"groups":[{"buckets":[{"bucketId":"gemini-weekly","remainingFraction":1}]},
                   {"buckets":[{"bucketId":"3p-weekly","remainingFraction":0.5}]}]}
        """)
        let tiers = try XCTUnwrap(AntigravityQuotaParsing.parseSummary(root))
        XCTAssertEqual(tiers.map(\.bucketId), ["gemini-weekly", "3p-weekly"])
    }

    // 不认识的桶（以后新增的组）跳过，免得显示成没有文案的档；没有剩余比例的桶同样跳过。
    // 负责杀的变异体：未知桶照样收进来。
    func testUnknownBucketsAndMissingFractionsAreSkipped() throws {
        let root = json("""
        {"groups":[{"buckets":[
          {"bucketId":"veo-daily","remainingFraction":0.1},
          {"bucketId":"gemini-5h"},
          {"remainingFraction":0.2},
          {"bucketId":"3p-5h","remainingFraction":0.3}]}]}
        """)
        let tiers = try XCTUnwrap(AntigravityQuotaParsing.parseSummary(root))
        XCTAssertEqual(tiers.map(\.bucketId), ["3p-5h"])
    }

    // 一档都认不出 → nil（调用方保留上次结果，不把码片刷成空）。
    func testNothingRecognisedIsNil() {
        XCTAssertNil(AntigravityQuotaParsing.parseSummary(json(#"{"groups":[]}"#)))
        XCTAssertNil(AntigravityQuotaParsing.parseSummary(json(#"{"error":{"code":403}}"#)))
        XCTAssertNil(AntigravityQuotaParsing.parseSummary(json(#"{"groups":[{"buckets":[{"bucketId":"x","remainingFraction":1}]}]}"#)))
    }

    // 剩余比例越界时钳到 0…1（上游 clamp），已用不会出现负数或超过 100。
    func testRemainingFractionIsClamped() throws {
        let root = json(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":1.4},{"bucketId":"3p-5h","remainingFraction":-0.2}]}]}"#)
        let tiers = try XCTUnwrap(AntigravityQuotaParsing.parseSummary(root))
        XCTAssertEqual(tiers.map(\.usedPercent), [0, 100])
    }

    // 同一个桶出现两次只留第一次（菜单栏按桶 id 当勾选键，重复会让两个勾选框绑同一个键）。
    func testDuplicateBucketKeepsTheFirst() throws {
        let root = json(#"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.5}]},{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.1}]}]}"#)
        let tiers = try XCTUnwrap(AntigravityQuotaParsing.parseSummary(root))
        XCTAssertEqual(tiers.count, 1)
        XCTAssertEqual(tiers[0].usedPercent, 50, accuracy: 1e-9)
    }

    // MARK: - agy 版本号与 User-Agent

    // `agy --version` 输出里第一个形如 1.4.6 的词，允许 v 前缀（上游 parse_version）。
    func testVersionIsTheFirstDottedNumber() {
        XCTAssertEqual(AntigravityQuotaParsing.parseVersion("1.4.6\n"), "1.4.6")
        XCTAssertEqual(AntigravityQuotaParsing.parseVersion("agy version v1.5.0 (darwin-arm64)"), "1.5.0")
        XCTAssertNil(AntigravityQuotaParsing.parseVersion("agy dev build"))
        XCTAssertNil(AntigravityQuotaParsing.parseVersion("1.4.6-beta"))
        XCTAssertNil(AntigravityQuotaParsing.parseVersion(""))
    }

    // 服务端只在看到 `antigravity/cli/<版本>` 时才回 Gemini 那组；照实报 CC Usage，括号里补上客户端标识。
    // 负责杀的变异体：括号里只写 antigravity（10-26 实测会只回 Claude/GPT 一组）。
    func testUserAgentNamesCCUsageAndTheAgyCLIVersion() {
        XCTAssertEqual(AntigravityQuotaParsing.userAgent(appVersion: "2.1.0", agyVersion: "1.4.6"),
                       "cc-usage/2.1.0 (antigravity/cli/1.4.6)")
        XCTAssertEqual(AntigravityQuotaParsing.fallbackAgyVersion, "1.4.6")
    }

    // MARK: - 旧码片键迁移（antigravity.quota.<家族> → agy.quota.<桶>）

    // 旧数字其实是每周窗口（旧接口的重置时间与每周桶一致），所以旧的家族勾选迁到每周档。
    // 负责杀的变异体：迁移后还留着旧键 / GPT-OSS 没并进 Claude 那组 / 其它码片被误伤。
    func testLegacyAntigravityChipsMoveToTheWeeklyBuckets() {
        let old: Set<String> = ["antigravity.quota.Gemini", "antigravity.quota.Claude",
                                "antigravity.quota.GPT-OSS", "antigravity.quota.Tab",
                                "claude.tokens.today", "codex.quota.5H"]
        let migrated = MenuBarChipMigration.migrateAntigravity(old)
        XCTAssertEqual(migrated, ["agy.quota.gemini-weekly", "agy.quota.3p-weekly",
                                  "claude.tokens.today", "codex.quota.5H"])
    }

    // 单独勾了 GPT-OSS 的也要落到 Claude/GPT 那组（上面那条里三个键都在，迁错组也能凑出同一个集合）。
    // 负责杀的变异体：GPT-OSS 迁到 Gemini 组。
    func testLegacyGptOssChipAloneMovesToTheClaudeGroup() {
        XCTAssertEqual(MenuBarChipMigration.migrateAntigravity(["antigravity.quota.GPT-OSS"]),
                       ["agy.quota.3p-weekly"])
    }

    // 用量码片（理论上旧版不会有）原样换前缀；跑第二次不再变（幂等）。
    func testMigrationIsIdempotentAndRenamesUsageChips() {
        let once = MenuBarChipMigration.migrateAntigravity(["antigravity.tokens.week", "antigravity.quota.Gemini"])
        XCTAssertEqual(once, ["agy.tokens.week", "agy.quota.gemini-weekly"])
        XCTAssertEqual(MenuBarChipMigration.migrateAntigravity(once), once)
    }
}
