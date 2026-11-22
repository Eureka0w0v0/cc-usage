import XCTest

// 请求详情抽屉（get_request_detail）。对齐 cc-switch usage_stats.rs::get_request_detail：按 request_id 直查明细、
// 成本照列表一样补算、不套跨源去重；库里没有就找还没入库的叠加行；都没有返回 nil（前端显示 Request not found）。
// 早先原生桥没接这个命令，真机上点任何一条请求都是「找不到」（2026-10-16 修复）。
//
// 每个用例的注释写明它负责杀哪些变异体。
final class RequestDetailTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var store: UsageStore!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("detail")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-detail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        store = UsageStore(path: dbPath,
                           overlay: SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0),
                           ompOverlay: try Fixture.emptyOmpOverlay())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
        Fixture.cleanTempDirs()
    }

    /// 库内行：与 Request Logs 列表里同一行逐字段相同，含按内置定价补算的成本（cc-switch 入库时没定上价的行）。
    /// 杀变异体：详情不走成本补算（成本 0）；详情的投影或取列错位。
    func testDetailOfDBRowMatchesTheListRow() throws {
        try Fixture.insertLog(dbPath, id: "req-1", model: "claude-sonnet-5", input: 1000, output: 500,
                              cost: 0, createdAt: 1_790_000_000, latencyMs: 4200, firstTokenMs: 900)
        let listed = try XCTUnwrap(store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20).rows.first)
        let detail = try XCTUnwrap(store.requestDetail("req-1"))
        XCTAssertGreaterThan(Double(detail.totalCostUsd) ?? 0, 0, "前提：成本 0 的行按内置定价补算")
        XCTAssertEqual(detail, listed)
        XCTAssertEqual(detail.latencyMs, 4200)
        XCTAssertEqual(detail.firstTokenMs, 900)
    }

    /// 还没入库的叠加行也能打开详情，计时与列表里那一行相同。
    /// 杀变异体：库里查不到就直接返回 nil、不找叠加行。
    func testDetailOfOverlayRow() throws {
        let lines = [
            ClaudeLog.chain("user", 1, parent: nil, "2026-10-10T03:00:00.000Z"),
            ClaudeLog.thinking("msg_d", 2, parent: 1, "2026-10-10T03:00:05.000Z", durationMs: 3000,
                               model: "claude-sonnet-5"),
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            toFile: ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
                .appendingPathComponent("s.jsonl"),
            atomically: true, encoding: .utf8)
        let listed = try XCTUnwrap(store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20).rows.first)
        let detail = try XCTUnwrap(store.requestDetail("session:msg_d"))
        XCTAssertEqual(detail, listed)
        XCTAssertEqual(detail.latencyMs, 5000)
        XCTAssertEqual(detail.firstTokenMs, 2000)
        XCTAssertEqual(detail.dataSource, "session_log")
    }

    /// 新增输入（freshInputTokens，上游 v4.0.38 #8191）：后端按汇总同一口径（fresh_input_sql）算好给前端。Codex 的 input
    /// 含缓存读写，前端以前只减缓存读取，缓存写入被算成新增输入，和汇总对不上。
    /// 向量照搬上游 test_request_logs_report_fresh_input_like_the_summary。
    /// 最后一行是本地加的：input 比缓存读写之和还小时新鲜输入照上游取原值（计费输入取 0，两列只在这里不同）。
    /// 杀变异体：不按 input_token_semantics 分口径（legacy / total 两行一样）/ 列表或详情的取列错位（含错取成计费输入那一列）/
    /// 和汇总不是同一个表达式。
    func testFreshInputFollowsTheSummary() throws {
        for (id, app, semantics, input) in [("codex-legacy", "codex", Int64(0), Int64(1000)), ("codex-total", "codex", 1, 1000),
                                            ("claude", "claude", 0, 1000), ("codex-short", "codex", 1, 500)] {
            try Fixture.insertLog(dbPath, id: id, app: app, model: "test-model", input: input, output: 50,
                                  cacheRead: 300, cacheCreation: 600, cost: 0.01, createdAt: 1_790_000_000,
                                  dataSource: "proxy", providerId: "p1", semantics: semantics)
        }
        let rows = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20).rows
        let fresh = Dictionary(uniqueKeysWithValues: rows.map { ($0.requestId, $0.freshInputTokens) })
        XCTAssertEqual(fresh, ["codex-legacy": 700, "codex-total": 100, "claude": 1000, "codex-short": 500])
        let summary = try store.rangeSummaryLogsOnly(UsageFilter(start: 1_789_990_000, end: 1_790_010_000))
        XCTAssertEqual(fresh.values.reduce(0, +), summary.input, "各行之和等于汇总的输入")
        XCTAssertEqual(try store.requestDetail("codex-total")?.freshInputTokens, 100)
    }

    /// 不存在的 id → nil（前端据此显示 Request not found，而不是报错）。
    func testUnknownRequestIsNil() throws {
        XCTAssertNil(try store.requestDetail("session:nope"))
    }

    /// 详情按 id 直查、不套跨源去重（上游同样不套）：列表里被路由记录顶掉的会话行，按 id 仍能打开。
    /// 杀变异体：详情也套跨源去重（→ nil）。
    func testDetailIgnoresCrossSourceDedup() throws {
        try Fixture.insertLog(dbPath, id: "proxy-1", input: 10, output: 20, cost: 0.1,
                              createdAt: 1_790_000_000, dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "session:dup", input: 10, output: 20, cost: 0.1,
                              createdAt: 1_790_000_005)
        let listed = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20).rows.map(\.requestId)
        XCTAssertEqual(listed, ["proxy-1"], "前提：会话行在列表里被跨源去重")
        XCTAssertEqual(try store.requestDetail("session:dup")?.requestId, "session:dup")
    }
}
