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
}
