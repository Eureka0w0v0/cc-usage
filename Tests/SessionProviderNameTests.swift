import XCTest

// 会话来源的占位 provider_id（_grok_session、_mcode_session 等）在供应商统计里显示可读名，并能按这个名字筛选。
// （这些用例原先和「按来源」分组放在 DataSourceBreakdownTests 里；get_usage_data_sources 没有调用方，已删。）
final class SessionProviderNameTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("session-provider-names")
        store = try Fixture.store(dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// v3.19 新增会话来源：Provider Stats 必须显示可读名而非裸 provider_id。
    func testGrokSessionProviderRendersReadableName() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "g1", app: "grokbuild", model: "grok-4.5-build",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "grok_session", providerId: "_grok_session")

        let stats = try store.providerStats(LogQueryFilter())
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.providerName, "Grok Build (Session)")
        XCTAssertEqual(stats.first?.requestCount, 1)
    }

    /// v3.20.3 新增会话来源（MiniMax Code）：同 Grok 那条，占位 provider_id 必须
    /// 映射成可读名，否则 Provider Stats 里会直接露出 `_mcode_session`。
    /// 负责杀的变异体：providerNameSQL 漏掉 `_mcode_session` 分支。
    func testMcodeSessionProviderRendersReadableName() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "m1", app: "mcode", model: "minimax-m2.7",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "mcode_session", providerId: "_mcode_session")

        let stats = try store.providerStats(LogQueryFilter())
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats.first?.providerName, "MiniMax Code (Session)")
        XCTAssertEqual(stats.first?.requestCount, 1)
    }

    /// Pi 会话来源（v3.20 已在 SQL 里，这里补上回归锁）。
    func testPiSessionProviderRendersReadableName() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "p1", app: "pi", model: "claude-sonnet-5",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "pi_session", providerId: "_pi_session")

        let stats = try store.providerStats(LogQueryFilter())
        XCTAssertEqual(stats.first?.providerName, "Pi (Session)")
    }

    /// v4.0.18 / v4.0.19 新增的会话来源（Antigravity、Kimi Code）：名字逐字对齐上游
    /// provider_name_coalesce，否则按 providerName 筛选时对不上上游前端传来的值。
    /// 负责杀的变异体：providerNameSQL 漏掉 `_agy_session` / `_kimi_session` 分支。
    func testAgyAndKimiSessionProvidersRenderReadableNames() throws {
        let t = Fixture.ts(2026, 10, 24, 12)
        try Fixture.insertLog(dbPath, id: "a1", app: "agy", model: "gemini-4-argon",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "agy_session", providerId: "_agy_session")
        try Fixture.insertLog(dbPath, id: "k1", app: "kimi", model: "kimi-k3.1-pro",
                              input: 100, output: 10, cost: 0.5, createdAt: t,
                              dataSource: "kimi_session", providerId: "_kimi_session")

        let names = Set(try store.providerStats(LogQueryFilter()).map(\.providerName))
        XCTAssertEqual(names, ["Antigravity (Session)", "Kimi Code (Session)"])
    }

    /// v4.0.22 新增的会话来源（Oh My Pi、DeepSeek Harness 的会话与官方账号登录）：名字逐字对齐上游
    /// provider_name_coalesce。负责杀的变异体：providerNameSQL 漏掉 `_omp_session` / `_dsh_session` /
    /// `_dsh_account_session` 任一分支。
    func testOmpAndDshSessionProvidersRenderReadableNames() throws {
        let t = Fixture.ts(2026, 10, 30, 12)
        try Fixture.insertLog(dbPath, id: "o1", app: "omp", model: "claude-opus-5-5",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "omp_session", providerId: "_omp_session")
        try Fixture.insertLog(dbPath, id: "d1", app: "dsh", model: "deepseek-v4.1-flash",
                              input: 100, output: 10, cost: 0.5, createdAt: t,
                              dataSource: "dsh_session", providerId: "_dsh_session")
        try Fixture.insertLog(dbPath, id: "d2", app: "dsh", model: "deepseek-v4.1-flash",
                              input: 100, output: 10, cost: 0.4, createdAt: t,
                              dataSource: "dsh_session", providerId: "_dsh_account_session")

        let names = Set(try store.providerStats(LogQueryFilter()).map(\.providerName))
        XCTAssertEqual(names, ["Oh My Pi (Session)", "DeepSeek Harness (Session)",
                               "DeepSeek Harness (OAuth)"])
    }

    /// v4.0.29 / v4.0.31 新增的会话来源（GitHub Copilot CLI、WorkBuddy）：名字逐字对齐上游
    /// provider_name_coalesce，并且能按这个名字筛选（Hero 与页签同口径）。
    /// 负责杀的变异体：providerNameSQL 漏掉 `_copilot_session` / `_workbuddy_session` 任一分支 / 名字抄错。
    func testCopilotAndWorkBuddySessionProvidersRenderReadableNames() throws {
        let t = Fixture.ts(2026, 11, 14, 12)
        try Fixture.insertLog(dbPath, id: "c1", app: "copilot", model: "gpt-5.6",
                              input: 100, output: 10, cost: 1.5, createdAt: t,
                              dataSource: "copilot_session", providerId: "_copilot_session", semantics: 2)
        try Fixture.insertLog(dbPath, id: "w1", app: "workbuddy", model: "kimi-k3.1-pro",
                              input: 100, output: 10, cost: 0.5, createdAt: t,
                              dataSource: "workbuddy_session", providerId: "_workbuddy_session", semantics: 2)

        let names = Set(try store.providerStats(LogQueryFilter()).map(\.providerName))
        XCTAssertEqual(names, ["Copilot CLI (Session)", "WorkBuddy (Session)"])
        for name in names {
            let filtered = try store.rangeSummary(UsageFilter(start: t - 60, end: t + 60, providerName: name),
                                                  calendar: Fixture.cal)
            XCTAssertEqual(filtered.requests, 1, name)
        }
    }
}
