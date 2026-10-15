import XCTest

// Provider / Model 统计的成功率、速度、首字，以及并入日汇总（对齐 cc-switch v4.0.12 usage_stats.rs
// get_provider_stats / get_model_stats）。主窗口换成 v4 用量页后，表格里的「成功率 / 速度 / 首字」
// 三列就读这些字段。
//
// 用例按「杀变异体」设计：每个用例的注释写明它负责杀哪个变异体。
final class StatsPerformanceTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var store: UsageStore!
    private let t = Fixture.ts(2026, 10, 10, 12)
    /// 明细行的 input 依次递增，免得跨源去重把会话行当成代理行的重复。
    private var nextInput: Int64 = 1000

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("stats-perf")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-perf-\(UUID().uuidString)")
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

    private var window: LogQueryFilter { LogQueryFilter(start: t - 3600, end: t + 3600) }

    private func log(_ id: String, source: String, output: Int64, latency: Int64, firstToken: Int64?,
                     status: Int = 200, app: String = "claude", cost: Double = 1.0) throws {
        nextInput += 1
        try Fixture.insertLog(dbPath, id: id, app: app, model: "claude-sonnet-5", input: nextInput,
                              output: output, cost: cost, createdAt: t, dataSource: source,
                              status: status, providerId: "p1",
                              latencyMs: latency, firstTokenMs: firstToken)
    }

    // MARK: - 速度

    /// 精确速度只认路由记的行（有首字、输出 ≥ 100、生成窗口 = 耗时 − 首字 ≥ 100ms），估算速度只认
    /// 会话日志导入的行（输出 ≥ 200、耗时 ≥ 1s），两组分开累计，边界值都算进去。
    /// 杀变异体：四个门槛任一改成严格大于；精确组不看来源（S1 带了首字会混进来）；
    /// 生成窗口不减首字；估算组不看来源（P2、P5 会混进来）。
    func testSpeedTotalsSplitExactAndEstimatedByEligibility() throws {
        try log("P1", source: "proxy", output: 100, latency: 1100, firstToken: 1000)       // 精确，两个边界
        try log("P2", source: "proxy", output: 500, latency: 1099, firstToken: 1000)       // 生成窗口 99ms
        try log("P3", source: "proxy", output: 99, latency: 3000, firstToken: 1000)        // 输出 99
        try log("P4", source: "proxy", output: 500, latency: 3000, firstToken: nil)        // 没有首字
        try log("P5", source: "proxy", output: 300, latency: 2500, firstToken: 500)        // 精确：300 / 2000ms
        try log("S1", source: "session_log", output: 200, latency: 1000, firstToken: 800)  // 估算，两个边界
        try log("S2", source: "session_log", output: 500, latency: 999, firstToken: nil)   // 耗时 999ms
        try log("S3", source: "session_log", output: 199, latency: 5000, firstToken: nil)  // 输出 199
        try log("S4", source: "session_log", output: 400, latency: 4000, firstToken: nil)  // 估算：400 / 4s

        let perfs = [try XCTUnwrap(store.providerStats(window).first).performance,
                     try XCTUnwrap(store.modelStats(window).first).performance]
        for perf in perfs {
            XCTAssertEqual(perf.speedOutputTokens, 100 + 300)
            XCTAssertEqual(perf.speedGenerationMs, 100 + 2000)
            XCTAssertEqual(perf.estSpeedOutputTokens, 200 + 400)
            XCTAssertEqual(perf.estSpeedDurationMs, 1000 + 4000)
        }
    }

    // MARK: - 首字中位数

    /// 精确首字取路由的成功行，估算首字取会话日志导入、推出了首字的行；按 (供应商, 应用) 分开取中位数，
    /// 奇数个取中间，偶数个取中间两个的整除平均。
    /// 杀变异体：不看状态码（失败的 50ms 混进来，中位数变 150）；偶数取上中位（3000）或下中位（1000）；
    /// 分组键不带应用（desktop 的 9000 混进来）；精确、估算混在一起取（供应商表、模型表各一处）。
    func testFirstTokenMediansPerProviderAndApp() throws {
        try log("e1", source: "proxy", output: 10, latency: 900, firstToken: 300)
        try log("e2", source: "proxy", output: 10, latency: 900, firstToken: 100)
        try log("e3", source: "proxy", output: 10, latency: 900, firstToken: 200)
        try log("e4", source: "proxy", output: 10, latency: 900, firstToken: 50, status: 500)
        try log("s1", source: "session_log", output: 10, latency: 9000, firstToken: 1000)
        try log("s2", source: "session_log", output: 10, latency: 9000, firstToken: 3000)
        try log("s3", source: "session_log", output: 10, latency: 9000, firstToken: nil)
        try log("d1", source: "proxy", output: 10, latency: 9900, firstToken: 9000, app: "claude-desktop")

        let rows = try store.providerStats(
            LogQueryFilter(start: t - 3600, end: t + 3600, appType: "claude"))
        let code = try XCTUnwrap(rows.first { $0.appType == "claude" })
        let desktop = try XCTUnwrap(rows.first { $0.appType == "claude-desktop" })
        XCTAssertEqual(code.performance.firstTokenMedianMs, 200)
        XCTAssertEqual(code.performance.estFirstTokenMedianMs, 2000)
        XCTAssertEqual(desktop.performance.firstTokenMedianMs, 9000)
        XCTAssertNil(desktop.performance.estFirstTokenMedianMs)

        // 模型表同一套口径：只有一个模型，「Claude」筛选把 desktop 那行也折叠进来
        let model = try XCTUnwrap(store.modelStats(
            LogQueryFilter(start: t - 3600, end: t + 3600, appType: "claude")).first)
        XCTAssertEqual(model.performance.firstTokenMedianMs, 250, "100、200、300、9000 的中位数")
        XCTAssertEqual(model.performance.estFirstTokenMedianMs, 2000)
    }

    /// 模型表按有效计价模型分组（pricing_model 优先），并带成功率（v4 前端必填，缺了切到模型页签会白屏）。
    /// 杀变异体：中位数按原始 model 分组（别名那行对不上，变成 600）；成功率漏了失败行或没乘 100。
    func testModelStatsCarrySuccessRateAndMediansByEffectiveModel() throws {
        try Fixture.insertLog(dbPath, id: "m1", model: "alias-a", input: 1, output: 10, cost: 1,
                              createdAt: t, dataSource: "proxy", providerId: "p1",
                              pricingModel: "claude-sonnet-5", latencyMs: 900, firstTokenMs: 400)
        try Fixture.insertLog(dbPath, id: "m2", model: "claude-sonnet-5", input: 2, output: 10, cost: 1,
                              createdAt: t, dataSource: "proxy", status: 500, providerId: "p1",
                              latencyMs: 900, firstTokenMs: 100)
        try Fixture.insertLog(dbPath, id: "m3", model: "claude-sonnet-5", input: 3, output: 10, cost: 1,
                              createdAt: t, dataSource: "proxy", providerId: "p1",
                              latencyMs: 900, firstTokenMs: 600)

        let row = try XCTUnwrap(store.modelStats(window).first)
        XCTAssertEqual(row.model, "claude-sonnet-5")
        XCTAssertEqual(row.requestCount, 3)
        XCTAssertEqual(row.successRate, 200.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(row.performance.firstTokenMedianMs, 500, "400 与 600 的中位数；m2 失败不算")
    }

    // MARK: - 日汇总

    /// 区间覆盖到的整日 rollup 并进来：请求数、Tokens、成本、成功数、耗时（按请求数加权）都加，
    /// 速度只看明细。并完之后各行加起来等于顶部总数。
    /// 杀变异体：不并 rollup；rollup 的成功数没并；rollup 耗时没按请求数加权（变成 444）；
    /// rollup 混进速度。
    func testStatsMergeRollupsWithinWholeDays() throws {
        try Fixture.insertLog(dbPath, id: "d", input: 50, output: 300, cost: 1.0, createdAt: t,
                              dataSource: "proxy", providerId: "p1", latencyMs: 2500, firstTokenMs: 500)
        try Fixture.insertRollup(dbPath, date: "2026-10-08", requests: 8, input: 1000, output: 100,
                                 cost: 4.0, successes: 7, providerId: "p1", avgLatencyMs: 1500)
        try Fixture.insertRollup(dbPath, date: "2026-10-01", requests: 5, input: 1, cost: 9.0,
                                 providerId: "p1")
        let f = LogQueryFilter(start: Fixture.ts(2026, 10, 8), end: t + 3600)

        let p = try XCTUnwrap(store.providerStats(f, calendar: Fixture.cal).first)
        XCTAssertEqual(p.requestCount, 9)
        XCTAssertEqual(p.totalTokens, (50 + 300) + (1000 + 100))
        XCTAssertEqual(p.totalCost, 5.0, accuracy: 1e-9)
        XCTAssertEqual(p.successRate, 800.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(p.avgLatencyMs, (2500 + 1500 * 8) / 9)
        XCTAssertEqual(p.performance.speedOutputTokens, 300)
        XCTAssertEqual(p.performance.speedGenerationMs, 2000)

        let m = try XCTUnwrap(store.modelStats(f, calendar: Fixture.cal).first)
        XCTAssertEqual(m.requestCount, 9)
        XCTAssertEqual(m.totalCost, 5.0, accuracy: 1e-9)
        XCTAssertEqual(m.avgCostPerRequest, 5.0 / 9.0, accuracy: 1e-9)
        XCTAssertEqual(m.successRate, 800.0 / 9.0, accuracy: 1e-9)

        let hero = try store.rangeSummary(UsageFilter(start: f.start, end: f.end), calendar: Fixture.cal)
        XCTAssertEqual(hero.requests, 9, "前提：Hero 本来就并 rollup，现在两边对得上")
    }

    // MARK: - 叠加层

    /// 还没入库的叠加行计入请求数和成功率，但没有计时，不进速度、首字（界面显示「—」）。
    /// 杀变异体：叠加行按失败计（成功率 50%）；叠加行混进估算速度。
    func testOverlayRowsCountButStayOutOfPerformance() throws {
        try Fixture.insertLog(dbPath, id: "session:db1", input: 10, output: 400, cost: 1.0,
                              createdAt: t, dataSource: "session_log", providerId: "_session",
                              latencyMs: 4000, firstTokenMs: 1200)
        let line = #"{"type":"assistant","sessionId":"s1","timestamp":"2026-10-10T03:00:30Z","message":{"id":"ov1","stop_reason":"end_turn","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":500}}}"#
        try (line + "\n").write(
            toFile: ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
                .appendingPathComponent("s.jsonl"),
            atomically: true, encoding: .utf8)

        let p = try XCTUnwrap(store.providerStats(window).first)
        XCTAssertEqual(p.requestCount, 2, "前提：叠加行确实并进来了")
        XCTAssertEqual(p.successRate, 100, accuracy: 1e-9)
        XCTAssertEqual(p.performance.estSpeedOutputTokens, 400)
        XCTAssertEqual(p.performance.estSpeedDurationMs, 4000)
        XCTAssertEqual(p.performance.estFirstTokenMedianMs, 1200)

        let m = try XCTUnwrap(store.modelStats(window).first)
        XCTAssertEqual(m.requestCount, 2)
        XCTAssertEqual(m.successRate, 100, accuracy: 1e-9)
        XCTAssertEqual(m.performance.estSpeedOutputTokens, 400)
    }
}
