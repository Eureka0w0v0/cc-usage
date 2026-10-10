import XCTest

// Provider / Model 统计的 Tokens 列 = 真实消耗（新增输入 + 输出 + 缓存写入 + 缓存命中），
// 与 Hero 指标卡同口径，各行之和等于顶部总数。
//
// 回归背景（上游 bc4d1a50 / v4.0.3）：两张表原先只加 fresh_input + output，Hero 却含缓存；
// 缓存命中率高时，表里各行加起来只是顶部总数的零头。上游 real_total_tokens_sql 同时用于
// 明细与 rollup 两支；本 app 的 Tabs 只读明细表（见 UsageStore+Tabs 顶部注释），
// 所以这里只对齐明细 SQL 与 overlay 合并两条路径。
//
// 每个用例对应具体变异体，注释写明它负责杀哪个。
final class StatsRealTotalTokensTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("realtotal")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-realtotal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
        Fixture.cleanTempDirs()
    }

    /// 两行明细：Claude 的 input 已是新增输入；Codex 的 input 含缓存（semantics=1，total）。
    private func insertDetailRows(at t: Int64) throws {
        // 真实消耗 = 100 + 200 + 1000 + 5000 = 6300
        try Fixture.insertLog(dbPath, id: "claude-1", app: "claude", model: "claude-x",
                              input: 100, output: 200, cacheRead: 5000, cacheCreation: 1000,
                              cost: 0.10, createdAt: t, dataSource: "session_log",
                              providerId: "_session", semantics: 2)
        // 真实消耗 = (1000 - 600) + 50 + 600 + 0 = 1050（不能把 input 原样加，否则缓存算两遍）
        try Fixture.insertLog(dbPath, id: "codex-1", app: "codex", model: "gpt-x",
                              input: 1000, output: 50, cacheRead: 600, cacheCreation: 0,
                              cost: 0.05, createdAt: t + 60, dataSource: "codex_session",
                              providerId: "_codex_session", semantics: 1)
    }

    /// 杀变异体：providerStats 的 SQL 仍是 fresh_input + output（少缓存写入或缓存命中任一项）；
    /// 以及把 fresh_input 换成原始 input_tokens（Codex 行会把缓存命中算两遍：1650 而非 1050）。
    func testProviderStatsTokensIncludeCacheAndSumToSummary() throws {
        let t = Fixture.ts(2026, 10, 1, 12)
        try insertDetailRows(at: t)
        let store = try Fixture.store(dbPath)
        let f = LogQueryFilter(start: t - 600, end: t + 600)

        let rows = try store.providerStats(f)
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.providerId, $0.totalTokens) })
        XCTAssertEqual(byId["_session"], 6300)
        XCTAssertEqual(byId["_codex_session"], 1050)

        let hero = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, hero.tokensProcessed,
                       "Provider 表各行之和必须等于 Hero 的真实总 Tokens")
    }

    /// 杀变异体：modelStats 的 SQL 未改（与 providerStats 分开断言，便于定位）。
    func testModelStatsTokensIncludeCacheAndSumToSummary() throws {
        let t = Fixture.ts(2026, 10, 1, 12)
        try insertDetailRows(at: t)
        let store = try Fixture.store(dbPath)
        let f = LogQueryFilter(start: t - 600, end: t + 600)

        let rows = try store.modelStats(f)
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.model, $0.totalTokens) })
        XCTAssertEqual(byModel["claude-x"], 6300)
        XCTAssertEqual(byModel["gpt-x"], 1050)

        let hero = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.totalTokens }, hero.tokensProcessed)
    }

    /// 杀变异体：overlay 合并仍按 input + output 累加（providerStats 与 modelStats 两处各一个）。
    /// cc-switch 不开时，增量行只存在于内存叠加层，Tabs 也必须带上它们的缓存 token。
    func testOverlayRowsCountCacheTokensInBothTables() throws {
        let path = ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent("sess.jsonl")
        let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-10-01T03:00:00Z","message":{"id":"ov1","stop_reason":"end_turn","model":"claude-x","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":3000,"cache_creation_input_tokens":400}}}"#
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)

        let store = UsageStore(path: dbPath,
                               overlay: SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0),
                               ompOverlay: try Fixture.emptyOmpOverlay())
        let t = try XCTUnwrap(ISO8601Lenient.epochSeconds("2026-10-01T03:00:00Z"))
        let f = LogQueryFilter(start: t - 600, end: t + 600)

        // 真实消耗 = 100 + 20 + 400 + 3000 = 3520
        let providers = try store.providerStats(f)
        XCTAssertEqual(providers.map(\.totalTokens), [3520])
        let models = try store.modelStats(f)
        XCTAssertEqual(models.map(\.totalTokens), [3520])

        let hero = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(hero.tokensProcessed, 3520, "前提：overlay 行确实进了 Hero")
    }
}
