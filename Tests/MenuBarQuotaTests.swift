import XCTest

/// 一家的额度读数 + 勾选 → 菜单栏码片。三个来源的展示规则都在这里，勾了没数据时要占位，别让段落消失。
final class MenuBarQuotaTests: XCTestCase {
    private func reading(_ key: String, _ label: String, _ pct: Double) -> QuotaReading {
        QuotaReading(key: key, label: label, usedPercent: pct, resetAt: nil)
    }

    private func reading(_ key: String, _ pct: Double) -> QuotaReading { reading(key, key, pct) }

    private func chips(_ app: MBApp, _ readings: [QuotaReading], _ selection: Set<String> = [],
                       claude5H: Bool = false, claudeWeek: Bool = false) -> [QuotaChip] {
        MenuBarQuota.chips(for: app, readings: readings, selection: selection, claude5H: claude5H, claudeWeek: claudeWeek)
    }

    func testClaudeShowsTheTwoWindowsByDurationLabel() {
        let readings = [reading("five_hour", 12), reading("seven_day", 91), reading("seven_day_opus", 3)]
        XCTAssertEqual(chips(.claude, readings, claude5H: true, claudeWeek: true),
                       [QuotaChip(label: "5H", pct: 12), QuotaChip(label: "7D", pct: 91)])
        XCTAssertEqual(chips(.claude, readings, claude5H: true), [QuotaChip(label: "5H", pct: 12)])
        XCTAssertEqual(chips(.claude, readings, claudeWeek: true), [QuotaChip(label: "7D", pct: 91)])
        XCTAssertEqual(chips(.claude, readings), [])
    }

    /// 勾了但还没读数：占位撑住宽度，别让码片消失。
    func testClaudeWithoutReadingsKeepsPlaceholders() {
        XCTAssertEqual(chips(.claude, [], claude5H: true, claudeWeek: true),
                       [QuotaChip(label: "5H", pct: nil), QuotaChip(label: "7D", pct: nil)])
    }

    func testCodexShowsOnlySelectedWindows() {
        let readings = [reading("5H", 8), reading("7D", 55), reading("30D", 99)]
        XCTAssertEqual(chips(.codex, readings, ["codex.quota.7D", "codex.quota.30D"]),
                       [QuotaChip(label: "7D", pct: 55), QuotaChip(label: "30D", pct: 99)])
        XCTAssertEqual(chips(.codex, readings), [])
    }

    /// 勾了但一条快照都没扫到：一个「—」，告诉用户这里本该有东西。
    func testSelectedButNoReadingsShowsSingleDash() {
        XCTAssertEqual(chips(.codex, [], ["codex.quota.7D"]), [QuotaChip(label: "—", pct: nil)])
        XCTAssertEqual(chips(.agy, [], ["agy.quota.3p-weekly"]), [QuotaChip(label: "—", pct: nil)])
    }

    /// 勾的那档这轮没回来，但别的档回来了：不占位，只显示勾了的。
    func testSelectedTierMissingFromReadingsIsJustSkipped() {
        XCTAssertEqual(chips(.codex, [reading("5H", 8)], ["codex.quota.30D"]), [])
    }

    /// Antigravity 的码片键用桶 id，界面文案用 label。
    func testAntigravityMatchesByBucketAndShowsLabel() {
        let readings = [reading("gemini-weekly", "Gemini 7D", 10.4), reading("3p-weekly", "Claude 7D", 85)]
        XCTAssertEqual(chips(.agy, readings, ["agy.quota.3p-weekly"]), [QuotaChip(label: "Claude 7D", pct: 85)])
    }

    func testOtherAppsHaveNoQuotaChips() {
        for app in [MBApp.gemini, .opencode, .grokbuild, .pi, .mcode, .kimi, .omp, .dsh] {
            XCTAssertEqual(chips(app, [reading("x", 1)], ["\(app.rawValue).quota.x"]), [])
        }
    }

    func testSpeech() {
        XCTAssertEqual(QuotaChip(label: "5H", pct: 12.4).speech, "5H 12% used")
        XCTAssertEqual(QuotaChip(label: "7D", pct: nil).speech, "7D unavailable")
        XCTAssertEqual(QuotaChip(label: "—", pct: nil).speech, "quota unavailable")
    }

    func testReadingsFromEachSource() {
        let reset = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(QuotaReading(QuotaTier(name: "five_hour", utilization: 12, resetsAt: reset)),
                       QuotaReading(key: "five_hour", label: "five_hour", usedPercent: 12, resetAt: reset))
        XCTAssertEqual(QuotaReading(AntigravityTier(bucketId: "3p-5h", label: "Claude 5H", usedPercent: 40, resetAt: reset)),
                       QuotaReading(key: "3p-5h", label: "Claude 5H", usedPercent: 40, resetAt: reset))
    }
}
