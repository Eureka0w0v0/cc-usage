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
        XCTAssertEqual(out.week.input, 16)
        XCTAssertEqual(out.month.input, 116)
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

    /// 负责杀的变异体：W / M 查询失败被 try? 吞掉，界面只见「—」，error 还被清成 nil。
    /// SUM 整数溢出是 step 时的错误：这两行只落在近 7 天、不在今天，今日快照过得去，周查询才报错。
    func testWeekQueryFailureSurfaces() throws {
        try Fixture.insertLog(dbPath, id: "big1", output: Int64.max, createdAt: Fixture.ts(2026, 6, 6, 9))
        try Fixture.insertLog(dbPath, id: "big2", output: Int64.max, createdAt: Fixture.ts(2026, 6, 6, 10))
        XCTAssertThrowsError(try loader.load(chips: [], now: now, calendar: cal))
    }

    func testMonthQueryFailureSurfaces() throws {
        try Fixture.insertLog(dbPath, id: "big1", output: Int64.max, createdAt: Fixture.ts(2026, 5, 25, 9))
        try Fixture.insertLog(dbPath, id: "big2", output: Int64.max, createdAt: Fixture.ts(2026, 5, 25, 10))
        XCTAssertThrowsError(try loader.load(chips: [], now: now, calendar: cal))
    }

    /// 全部来源的累加中途抵消、不溢出，只有 Claude 自己的查询溢出：单个 app 的码片查询失败同样要报出来。
    func testPerAppQueryFailureSurfaces() throws {
        try Fixture.insertLog(dbPath, id: "c1", output: Int64.max, createdAt: Fixture.ts(2026, 6, 10, 10, 1))
        try Fixture.insertLog(dbPath, id: "x1", app: "codex", output: -Int64.max, createdAt: Fixture.ts(2026, 6, 10, 10, 2))
        try Fixture.insertLog(dbPath, id: "c2", output: Int64.max, createdAt: Fixture.ts(2026, 6, 10, 10, 3))
        XCTAssertNoThrow(try loader.load(chips: [], now: now, calendar: cal), "前提：全部来源的查询过得去")
        XCTAssertThrowsError(try loader.load(chips: ["claude.tokens.today"], now: now, calendar: cal))
    }

    func testMissingDatabaseThrows() {
        let broken = MenuBarDataLoader(store: UsageStore(path: "/nonexistent/x.db", sources: []))
        XCTAssertThrowsError(try broken.load(chips: [], now: now, calendar: cal))
    }
}
