import XCTest

/// 码片键的持久化字符串：mb.appChips 里存的就是它们，改一个字用户的勾选就丢了。这里逐字写死。
final class ChipKeyTests: XCTestCase {
    func testUsageKeysKeepTheirPersistedStrings() {
        XCTAssertEqual(ChipKey.usage(.claude, .tokens, .today).rawValue, "claude.tokens.today")
        XCTAssertEqual(ChipKey.usage(.claude, .cost, .month).rawValue, "claude.cost.month")
        XCTAssertEqual(ChipKey.usage(.grokbuild, .tokens, .week).rawValue, "grokbuild.tokens.week")
        XCTAssertEqual(ChipKey.usage(.agy, .cost, .today).rawValue, "agy.cost.today")
    }

    func testQuotaKeysKeepTheirPersistedStrings() {
        XCTAssertEqual(ChipKey.quota(.codex, "7D").rawValue, "codex.quota.7D")
        XCTAssertEqual(ChipKey.quota(.agy, "gemini-weekly").rawValue, "agy.quota.gemini-weekly")
        XCTAssertEqual(ChipKey.quotaPrefix(.codex), "codex.quota.")
        XCTAssertEqual(ChipKey.quotaPrefix(.agy), "agy.quota.")
    }

    /// 负责杀的变异体：app 的 rawValue 不是库里的 app_type（查询按它筛）。
    func testEveryAppKeyStartsWithItsAppType() {
        for app in MBApp.allCases {
            for metric in ChipKey.Metric.allCases {
                for period in ChipKey.Period.allCases {
                    XCTAssertEqual(ChipKey.usage(app, metric, period).rawValue,
                                   "\(app.rawValue).\(metric.rawValue).\(period.rawValue)")
                }
            }
        }
        XCTAssertEqual(ChipKey.Metric.allCases.map(\.rawValue), ["tokens", "cost"])
        XCTAssertEqual(ChipKey.Period.allCases.map(\.rawValue), ["today", "week", "month"])
    }

    func testSelectionQueries() {
        let chips: Set<String> = ["claude.tokens.today", "agy.quota.3p-weekly", "codex.tokens.week", "legacy.unknown"]
        XCTAssertTrue(chips.contains(.usage(.claude, .tokens, .today)))
        XCTAssertFalse(chips.contains(.usage(.claude, .cost, .today)))
        XCTAssertTrue(chips.contains(.quota(.agy, "3p-weekly")))
        XCTAssertTrue(chips.hasQuotaChip(.agy))
        XCTAssertFalse(chips.hasQuotaChip(.codex), "codex 只勾了用量")
    }
}
