import XCTest

/// 菜单栏一轮刷新的取数：窗口口径、只查勾了的 (app, 周期)。
final class MenuBarDataLoaderTests: XCTestCase {
    private var dbPath = ""
    private var loader: MenuBarDataLoader!
    private let cal = Fixture.cal
    private let now = Date(timeIntervalSince1970: TimeInterval(Fixture.ts(2026, 6, 10, 12)))

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("menubar-loader")
        loader = MenuBarDataLoader(store: try Fixture.store(dbPath))
        try Fixture.insertLog(dbPath, id: "today", input: 1, createdAt: Fixture.ts(2026, 6, 10, 9))
        try Fixture.insertLog(dbPath, id: "week", input: 10, createdAt: Fixture.ts(2026, 6, 5, 9))
        try Fixture.insertLog(dbPath, id: "month", input: 100, createdAt: Fixture.ts(2026, 5, 20, 9))
        try Fixture.insertLog(dbPath, id: "old", input: 1000, createdAt: Fixture.ts(2026, 4, 1, 9))
        try Fixture.insertLog(dbPath, id: "codex", app: "codex", input: 5, createdAt: Fixture.ts(2026, 6, 10, 10))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testAllSourcesTodayWeekAndMonthWindows() throws {
        let out = try loader.load(chips: [], now: now, calendar: cal)
        XCTAssertEqual(out.today.input, 6)
        XCTAssertEqual(out.week?.input, 16)
        XCTAssertEqual(out.month?.input, 116)
        XCTAssertEqual(out.snap.today.input, out.today.input, "今日直接复用快照")
        XCTAssertEqual(out.snap.cumulative.requests, 0, "菜单栏不要累计，那次全库聚合要跳过")
    }

    /// 负责杀的变异体：没勾的 app / 周期也查（每 5 秒白跑 SQL）。
    func testOnlyCheckedChipsAreQueried() throws {
        let out = try loader.load(chips: ["claude.tokens.today", "codex.cost.week", "gemini.quota.x"], now: now, calendar: cal)
        XCTAssertEqual(Set(out.appSummaries.keys), ["claude", "codex"])
        XCTAssertEqual(out.appSummaries["claude"]?.today?.input, 1)
        XCTAssertNil(out.appSummaries["claude"]?.week)
        XCTAssertNil(out.appSummaries["claude"]?.month)
        XCTAssertEqual(out.appSummaries["codex"]?.week?.input, 5)
        XCTAssertNil(out.appSummaries["codex"]?.today)
    }

    func testNoAppChipsMeansNoPerAppQueries() throws {
        XCTAssertTrue(try loader.load(chips: [], now: now, calendar: cal).appSummaries.isEmpty)
    }

    func testMissingDatabaseThrows() {
        let broken = MenuBarDataLoader(store: UsageStore(path: "/nonexistent/x.db", sources: []))
        XCTAssertThrowsError(try broken.load(chips: [], now: now, calendar: cal))
    }
}
