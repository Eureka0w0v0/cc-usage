import XCTest

/// MBApp 上的声明：设置面板靠它们循环成分组，持久化键和显示顺序都不能跟着重构漂。
final class MBAppTests: XCTestCase {
    /// rawValue 必须等于库里的 app_type，顺序就是菜单栏里各段的排列。
    func testMenuBarOrderIsUnchanged() {
        XCTAssertEqual(MBApp.allCases.map(\.rawValue),
                       ["claude", "codex", "gemini", "opencode", "agy", "grokbuild", "pi", "mcode", "kimi", "omp", "dsh"])
    }

    /// 负责杀的变异体：设置面板直接 ForEach(allCases)，Antigravity 跑到 OpenCode 后面。
    func testSettingsOrderKeepsAntigravityAfterMiniMax() {
        XCTAssertEqual(MBApp.settingsOrder.map(\.title),
                       ["Claude", "Codex", "Gemini", "OpenCode", "Grok", "Pi", "MiniMax Code", "Antigravity",
                        "Kimi Code", "Oh My Pi", "DeepSeek Harness"])
    }

    func testSettingsOrderListsEveryAppOnce() {
        XCTAssertEqual(MBApp.settingsOrder.count, MBApp.allCases.count)
        XCTAssertEqual(Set(MBApp.settingsOrder), Set(MBApp.allCases))
    }

    /// 展开状态的持久化键逐字保留：agy → mb.group.antigravity、grokbuild → mb.group.grok 是历史名。
    func testExpansionKeysKeepTheirPersistedStrings() {
        let keys = Dictionary(uniqueKeysWithValues: MBApp.allCases.map { ($0, $0.expansionKey) })
        XCTAssertEqual(keys, [.claude: "mb.group.claude", .codex: "mb.group.codex", .gemini: "mb.group.gemini",
                              .opencode: "mb.group.opencode", .agy: "mb.group.antigravity", .grokbuild: "mb.group.grok",
                              .pi: "mb.group.pi", .mcode: "mb.group.mcode", .kimi: "mb.group.kimi", .omp: "mb.group.omp",
                              .dsh: "mb.group.dsh"])
    }

    func testQuotaNotes() {
        for app in [MBApp.claude, .codex, .agy] { XCTAssertNil(app.quotaNote, "\(app) 有额度数据") }
        for app in [MBApp.gemini, .opencode, .grokbuild, .pi, .mcode] { XCTAssertEqual(app.quotaNote, "No quota API") }
        for app in [MBApp.kimi, .omp, .dsh] { XCTAssertEqual(app.quotaNote, "Not supported") }
    }

    /// 其余持久化键：重构时最容易顺手「修」掉的就是这些字符串。
    func testPersistedSettingKeys() {
        XCTAssertEqual(MBKey.appChips, "mb.appChips")
        XCTAssertEqual(MBKey.groupAll, "mb.group.all")
        XCTAssertEqual(MBKey.quota5H, "mb.quota.5h")
        XCTAssertEqual(MBKey.quotaWeek, "mb.quota.week")
        XCTAssertEqual(MBKey.tokToday, "mb.tokens.today")
        XCTAssertEqual(MBKey.costMonth, "mb.cost.month")
    }
}
