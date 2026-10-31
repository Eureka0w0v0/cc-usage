import XCTest

// 「按来源」分组（get_usage_data_sources）与 v3.19 新增的 _grok_session 供应商映射。
// 回归背景：旧实现把全部明细行硬贴成 'session_log'（PanelWebView.dataSources），
// 库里已有的 codex_session 行会被误算进 Claude 会话。
final class DataSourceBreakdownTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("dsbreakdown")
        store = try Fixture.store(dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testBreakdownGroupsByDataSourceInsteadOfLumpingIntoSessionLog() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "s1", cost: 1.0, createdAt: t)
        try Fixture.insertLog(dbPath, id: "s2", cost: 2.0, createdAt: t)
        try Fixture.insertLog(dbPath, id: "c1", app: "codex", cost: 4.0, createdAt: t,
                              dataSource: "codex_session", providerId: "_codex_session")
        try Fixture.insertLog(dbPath, id: "g1", app: "grokbuild", cost: 8.0, createdAt: t,
                              dataSource: "grok_session", providerId: "_grok_session")

        let rows = try store.dataSourceBreakdown()
        let byKey = Dictionary(uniqueKeysWithValues: rows.map { ($0.dataSource, $0) })

        XCTAssertEqual(Set(byKey.keys), ["session_log", "codex_session", "grok_session"])
        XCTAssertEqual(byKey["session_log"]?.requestCount, 2)
        XCTAssertEqual(byKey["session_log"]?.totalCost ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(byKey["codex_session"]?.requestCount, 1)
        XCTAssertEqual(byKey["codex_session"]?.totalCost ?? 0, 4.0, accuracy: 1e-9)
        XCTAssertEqual(byKey["grok_session"]?.requestCount, 1)
        XCTAssertEqual(byKey["grok_session"]?.totalCost ?? 0, 8.0, accuracy: 1e-9)
    }

    /// 上游此接口是全表口径（不吃日期选择器），且按请求数降序。
    func testBreakdownIgnoresDateRangeAndSortsByRequestCount() throws {
        let old = Fixture.ts(2025, 1, 1, 12)
        let recent = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "old1", cost: 1.0, createdAt: old)
        for i in 0..<3 {
            try Fixture.insertLog(dbPath, id: "c\(i)", app: "codex", cost: 0.1, createdAt: recent,
                                  dataSource: "codex_session", providerId: "_codex_session")
        }

        let rows = try store.dataSourceBreakdown()
        XCTAssertEqual(rows.map(\.dataSource), ["codex_session", "session_log"])
        XCTAssertEqual(rows.first?.requestCount, 3)
        // 2025 年那行没有被任何时间窗剔除
        XCTAssertEqual(rows.last?.requestCount, 1)
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
}
