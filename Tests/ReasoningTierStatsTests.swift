import XCTest

// 同价推理档合并在各查询里的表现（上游 #8845）。主体照搬上游
// test_merged_reasoning_models_keep_totals_filters_and_pooled_medians：Argon 的基础档、两条 high（大小写不同）、
// 三条 medium（其中一条是路由别名 + pricing_model）加一条整日 rollup，统计里并成一行、筛选基础模型能选中全部，
// 请求日志仍是原始模型名；首字中位数按合并后的全部样本取。另补叠加行（未入库）同样参与合并和筛选。
final class ReasoningTierStatsTests: XCTestCase {
    private var dbPath = ""
    private let cal = Fixture.cal
    private lazy var ts = Fixture.ts(2026, 6, 10, 12)

    private final class Fake: PendingUsageSource {
        let rows: [OverlayRow]
        init(_ rows: [OverlayRow]) { self.rows = rows }
        func pendingRows(db: OpaquePointer) -> [OverlayRow] { rows }
    }

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("reasoning-tier-stats")
        // 首字样本分布在三个档位：base=[10]、high=[20, 30]、medium=[1000, 2000, 3000]。
        // 全样本中位数 = (30 + 1000) / 2 = 515；各档中位数 [10, 25, 2000] 的中位数 25、均值 678，都不一样。
        for (id, model, first, cost) in [("base", "gemini-4-argon", 10, 1.0), ("high-1", "gemini-4-argon-high", 20, 2),
                                         ("high-2", "gemini-4-argon-HIGH", 30, 3),
                                         ("medium-1", "gemini-4-argon-medium", 1000, 4),
                                         ("medium-2", "gemini-4-argon-medium", 2000, 5),
                                         ("medium-3", "gemini-4-argon-medium", 3000, 6)] as [(String, String, Int64, Double)] {
            try Fixture.insertLog(dbPath, id: id, app: "agy", model: model, input: 100, output: 200, cost: cost,
                                  createdAt: ts, dataSource: "proxy", providerId: "_agy_session",
                                  requestModel: model, latencyMs: first + 1000, firstTokenMs: first)
        }
        try Fixture.exec(dbPath, """
        UPDATE proxy_request_logs SET model = 'routed-alias', pricing_model = 'gemini-4-argon-medium'
        WHERE request_id = 'medium-1'
        """)
        try Fixture.insertRollup(dbPath, date: "2026-06-08", app: "agy", model: "gemini-4-argon-high", requests: 2,
                                 input: 200, output: 400, cost: 5, successes: 1, providerId: "_agy_session",
                                 avgLatencyMs: 1000)
        // 带路径前缀的 tiered 也要能合并、能按合并后的名字筛回来
        try Fixture.insertLog(dbPath, id: "prefixed-tiered", app: "agy", model: "models/gemini-3.8-flash-tiered",
                              input: 100, output: 200, cost: 1, createdAt: ts, dataSource: "agy_session",
                              providerId: "_agy_session")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private var window: (start: Int64, end: Int64) { (Fixture.ts(2026, 6, 1), ts + 3600) }

    // 负责杀的变异体：统计不合并 / 首字取各档中位数的平均或中位数 / 合并时漏加 rollup 或速度累计 /
    // 合并键用 model 而不是有效计价模型（路由别名那条落单）。
    func testModelStatsMergeTiersAndPoolFirstTokenSamples() throws {
        let store = try Fixture.store(dbPath)
        let stats = try store.modelStats(LogQueryFilter(start: window.start, end: window.end, appType: "agy"),
                                         calendar: cal)
        XCTAssertEqual(stats.map(\.model), ["gemini-4-argon", "models/gemini-3.8-flash"])
        let argon = stats[0]
        XCTAssertEqual(argon.requestCount, 8)
        XCTAssertEqual(argon.totalTokens, 2400)
        XCTAssertEqual(argon.totalCost, 26, accuracy: 1e-9)
        XCTAssertEqual(argon.avgCostPerRequest, 3.25, accuracy: 1e-9)
        XCTAssertEqual(argon.successRate, 700.0 / 8.0, accuracy: 1e-9)
        XCTAssertEqual(argon.performance.speedOutputTokens, 1200)
        XCTAssertEqual(argon.performance.speedGenerationMs, 6000)
        XCTAssertEqual(argon.performance.firstTokenMedianMs, 515)
        XCTAssertEqual(stats[1].requestCount, 1)
    }

    // 筛选基础模型：汇总、按 app、供应商 / 模型统计、最早日期、按日和按小时走势都把各档算进来；
    // 请求日志只有明细（rollup 没有逐行），显示原始模型名。
    // 负责杀的变异体：只改了某一条查询的模型条件（其余仍精确匹配）/ rollup 侧没接上 / 请求日志改写了模型名。
    func testFilteringTheBaseModelSelectsEveryMergedTier() throws {
        let store = try Fixture.store(dbPath)
        let model = "gemini-4-argon"
        let scope = UsageFilter(start: window.start, end: window.end, appType: "agy", model: model)
        let summary = try store.rangeSummary(scope, calendar: cal)
        XCTAssertEqual(summary.requests, 8)
        XCTAssertEqual(summary.cost, 26, accuracy: 1e-9)
        XCTAssertEqual(try store.summaryByApp(UsageFilter(start: window.start, end: window.end, model: model),
                                              calendar: cal).first?.summary.requests, 8)
        let logFilter = LogQueryFilter(start: window.start, end: window.end, appType: "agy", model: model)
        XCTAssertEqual(try store.providerStats(logFilter, calendar: cal).first?.requestCount, 8)
        XCTAssertEqual(try store.modelStats(logFilter, calendar: cal).first?.requestCount, 8)
        XCTAssertEqual(try store.firstUsageDate(UsageFilter(appType: "agy", model: model), calendar: cal), "2026-06-08")

        let daily = try store.trendBuckets(filter: UsageFilter(start: Fixture.ts(2026, 6, 8), end: ts + 1,
                                                               appType: "agy", model: model), calendar: cal)
        XCTAssertEqual(daily.map(\.requestCount).reduce(0, +), 8)
        let hourly = try store.trendBuckets(filter: UsageFilter(start: ts - 3600, end: ts + 1, appType: "agy",
                                                                model: model), calendar: cal)
        XCTAssertEqual(hourly.map(\.requestCount).reduce(0, +), 6)

        let logs = try store.requestLogs(LogQueryFilter(model: model), page: 0, pageSize: 10)
        XCTAssertEqual(logs.total, 6)
        XCTAssertEqual(Set(logs.rows.map(\.model)),
                       ["gemini-4-argon", "gemini-4-argon-high", "gemini-4-argon-HIGH", "routed-alias",
                        "gemini-4-argon-medium"])
    }

    // 被并到别处的档位只精确匹配：筛 `gemini-4-argon-high` 只选中写法完全一样的那条明细和 rollup。
    // 负责杀的变异体：会被合并的模型也按后缀放宽（把 HIGH 也选进来）。
    func testFilteringAMergedTierMatchesOnlyItself() throws {
        let store = try Fixture.store(dbPath)
        let logs = try store.requestLogs(LogQueryFilter(model: "gemini-4-argon-high"), page: 0, pageSize: 10)
        XCTAssertEqual(logs.rows.map(\.requestId), ["high-1"])
        let summary = try store.rangeSummary(UsageFilter(start: window.start, end: window.end,
                                                         model: "gemini-4-argon-high"), calendar: cal)
        XCTAssertEqual(summary.requests, 3, "1 条明细 + rollup 的 2 次")
    }

    // 带路径前缀的 tiered：并到 `models/gemini-3.8-flash`，按这个名字能筛回来。
    func testPrefixedTieredMergesAndFiltersBack() throws {
        let store = try Fixture.store(dbPath)
        let stats = try store.modelStats(LogQueryFilter(appType: "agy", model: "models/gemini-3.8-flash"),
                                         calendar: cal)
        XCTAssertEqual(stats.map(\.model), ["models/gemini-3.8-flash"])
        XCTAssertEqual(stats.first?.requestCount, 1)
    }

    private func overlayRow(_ id: String, _ model: String, cost: Double) -> OverlayRow {
        var r = OverlayRow(requestId: id, model: model, createdAt: ts + 60, input: 100, output: 200,
                           cacheRead: 0, cacheCreation: 0, inputCost: 0, outputCost: 0, cacheReadCost: 0,
                           cacheCreationCost: 0, totalCost: cost, hasStopReason: true, sourceFile: "f")
        r.appType = "agy"
        r.providerId = "_agy_session"
        r.providerName = "Antigravity (Session)"
        return r
    }

    // 未入库的叠加行同样参与合并和筛选：同价档位并进基础模型那一行，认不出价的照旧单列。
    // 负责杀的变异体：叠加行没走统计口径（xhigh 单列）/ 叠加行的模型过滤仍是精确匹配（筛基础模型漏掉 xhigh）。
    func testOverlayRowsMergeAndFilterLikeDatabaseRows() throws {
        let store = UsageStore(path: dbPath, sources: [Fake([overlayRow("ov-xhigh", "gemini-4-argon-xhigh", cost: 10),
                                                             overlayRow("ov-preview", "gemini-4-argon-preview", cost: 1)])])
        let stats = try store.modelStats(LogQueryFilter(start: window.start, end: window.end, appType: "agy"),
                                         calendar: cal)
        let argon = try XCTUnwrap(stats.first { $0.model == "gemini-4-argon" })
        XCTAssertEqual(argon.requestCount, 9)
        XCTAssertEqual(argon.totalCost, 36, accuracy: 1e-9)
        XCTAssertNotNil(stats.first { $0.model == "gemini-4-argon-preview" }, "没有价的变体不合并")
        XCTAssertNil(stats.first { $0.model == "gemini-4-argon-xhigh" })

        let filtered = try store.rangeSummary(UsageFilter(start: window.start, end: window.end, appType: "agy",
                                                          model: "gemini-4-argon"), calendar: cal)
        XCTAssertEqual(filtered.requests, 9)
        XCTAssertEqual(try store.requestLogs(LogQueryFilter(model: "gemini-4-argon"), page: 0, pageSize: 20).total, 7)
    }
}
