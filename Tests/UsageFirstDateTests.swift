import XCTest

// get_usage_first_date：最早有用量记录的本地日，热力图据此决定铺几段 53 周。
// 对齐上游 v4.0.5 `get_first_usage_date`（及其用例 test_get_first_usage_date_spans_rollups_and_logs）：
// 明细表 MIN(created_at) 转本地日、rollups 表 MIN(date)，两者取早；吃 app / provider / 模型筛选，
// 不吃时间窗，也不套跨源去重。本 app 另把未入库的 overlay 行算进来（与其余查询同口径）。
//
// 每个用例注释写明它负责杀的变异体。
final class UsageFirstDateTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("firstdate")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-firstdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
        Fixture.cleanTempDirs()
    }

    private func first(_ f: UsageFilter = UsageFilter(), store: UsageStore? = nil) throws -> String? {
        try (store ?? Fixture.store(dbPath)).firstUsageDate(f, calendar: Fixture.cal)
    }

    /// 杀变异体：空库返回今天之类的占位日期，而不是 nil。
    func testEmptyDatabaseHasNoFirstDate() throws {
        XCTAssertNil(try first())
    }

    /// 杀变异体：按 UTC 取日期（JST 3/1 00:30 在 UTC 还是 2/28）/ 取 MAX 而非 MIN。
    func testDetailRowsUseTheEarliestLocalDay() throws {
        try Fixture.insertLog(dbPath, id: "a", createdAt: Fixture.ts(2026, 3, 1, 0, 30))
        try Fixture.insertLog(dbPath, id: "b", createdAt: Fixture.ts(2026, 5, 5, 12))
        XCTAssertEqual(try first(), "2026-03-01")
    }

    /// 杀变异体：只看明细表（漏 rollups）/ 只看 rollups / 两表取晚而非取早。
    func testTakesTheEarlierOfRollupsAndDetailRows() throws {
        try Fixture.insertLog(dbPath, id: "a", createdAt: Fixture.ts(2026, 9, 10, 9))
        try Fixture.insertRollup(dbPath, date: "2026-04-20")
        XCTAssertEqual(try first(), "2026-04-20")

        let other = try Fixture.makeDB("firstdate-b")
        defer { try? FileManager.default.removeItem(atPath: other) }
        try Fixture.insertLog(other, id: "a", createdAt: Fixture.ts(2026, 1, 2, 9))
        try Fixture.insertRollup(other, date: "2026-04-20")
        XCTAssertEqual(try Fixture.store(other).firstUsageDate(UsageFilter(), calendar: Fixture.cal),
                       "2026-01-02")
    }

    /// 杀变异体：明细或 rollups 任一侧没套 app / 模型筛选；app 筛选没折叠 claude-desktop。
    func testHonorsAppAndModelFiltersOnBothTables() throws {
        try Fixture.insertRollup(dbPath, date: "2026-02-01", app: "codex", model: "gpt-x")
        try Fixture.insertLog(dbPath, id: "c1", app: "claude-desktop", model: "claude-x",
                              createdAt: Fixture.ts(2026, 3, 3, 10))
        try Fixture.insertLog(dbPath, id: "c2", app: "claude", model: "claude-y",
                              createdAt: Fixture.ts(2026, 4, 4, 10))
        XCTAssertEqual(try first(), "2026-02-01")
        XCTAssertEqual(try first(UsageFilter(appType: "claude")), "2026-03-03")
        XCTAssertEqual(try first(UsageFilter(appType: "codex")), "2026-02-01")
        XCTAssertEqual(try first(UsageFilter(model: "claude-y")), "2026-04-04")
        XCTAssertNil(try first(UsageFilter(appType: "gemini")))
    }

    /// 杀变异体：provider 筛选没生效（会话占位名要映射成 "Claude (Session)" 才能匹配）。
    func testHonorsProviderNameFilter() throws {
        try Fixture.insertLog(dbPath, id: "s", createdAt: Fixture.ts(2026, 6, 6, 10),
                              providerId: "_session")
        try Fixture.insertLog(dbPath, id: "c", app: "codex", createdAt: Fixture.ts(2026, 5, 5, 10),
                              dataSource: "codex_session", providerId: "_codex_session")
        XCTAssertEqual(try first(UsageFilter(providerName: "Claude (Session)")), "2026-06-06")
        XCTAssertEqual(try first(UsageFilter(providerName: "Codex (Session)")), "2026-05-05")
    }

    /// 杀变异体：套了跨源去重（上游不套）。session 行在 3/9 23:58，与之指纹相同的 proxy 行在
    /// 3/10 00:03（±600s 内）：去重会剔掉 session 行，最早日就错成 3/10。
    func testDoesNotApplyCrossSourceDedup() throws {
        try Fixture.insertLog(dbPath, id: "proxy", app: "claude-desktop", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: Fixture.ts(2026, 3, 10, 0, 3),
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "session", app: "claude", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: Fixture.ts(2026, 3, 9, 23, 58),
                              dataSource: "session_log")
        XCTAssertEqual(try first(), "2026-03-09")
    }

    /// 杀变异体：没把未入库的 overlay 行算进来（cc-switch 没开过的新机器，库空但会话日志有数据）。
    func testCountsPendingOverlayRows() throws {
        let path = ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent("sess.jsonl")
        let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-02-14T15:30:00Z","message":{"id":"ov1","stop_reason":"end_turn","model":"claude-x","usage":{"input_tokens":100,"output_tokens":20}}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try Fixture.insertLog(dbPath, id: "late", createdAt: Fixture.ts(2026, 3, 1, 10))
        let store = UsageStore(path: dbPath,
                               overlay: SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0),
                               ompOverlay: try Fixture.emptyOmpOverlay())
        // UTC 2/14 15:30 = JST 2/15 00:30
        XCTAssertEqual(try first(store: store), "2026-02-15")
        XCTAssertNil(try first(UsageFilter(appType: "codex"), store: store), "overlay 行同样要吃筛选")
    }
}
