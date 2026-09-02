import XCTest

// Hero / 走势 / by-app 三条路径的 provider 筛选（对齐上游 push_provider_model_filters +
// providers_join）。回归背景：桥接层读了 providerName 却没传给 summaryByApp / trends，
// 工具栏选 Source 后三个 Tab 变了、Hero 与走势图纹丝不动，同屏数字打架。
// 四个用例分别负责杀：漏明细侧 / 漏 rollup 侧 / 漏 hourly / 漏 overlay 的变异体。
final class ProviderFilterTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!
    private let t = Fixture.ts(2026, 6, 10, 12)

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("provider-filter")
        store = try Fixture.store(dbPath)
        try Fixture.exec(dbPath, """
        INSERT INTO providers(id, name, app_type) VALUES('prov-a','Provider A','claude');
        INSERT INTO providers(id, name, app_type) VALUES('prov-b','Provider B','claude');
        """)
        // 明细：两条 Provider A、一条 Provider B（代理行）、一条会话占位行。token 数各不相同，
        // 免得跨源去重把会话行当成代理行的重复。
        try Fixture.insertLog(dbPath, id: "a1", input: 100, output: 10, cost: 1.0, createdAt: t,
                              dataSource: "proxy", providerId: "prov-a")
        try Fixture.insertLog(dbPath, id: "a2", input: 200, output: 20, cost: 1.0, createdAt: t,
                              dataSource: "proxy", providerId: "prov-a")
        try Fixture.insertLog(dbPath, id: "b1", input: 300, output: 30, cost: 3.0, createdAt: t,
                              dataSource: "proxy", providerId: "prov-b")
        try Fixture.insertLog(dbPath, id: "s1", input: 50, output: 5, cost: 0.5, createdAt: t)
        // 历史日聚合：整日 06-08，两个 provider 各一行
        try Fixture.insertRollup(dbPath, date: "2026-06-08", requests: 5, input: 1000, cost: 10.0,
                                 providerId: "prov-a")
        try Fixture.insertRollup(dbPath, date: "2026-06-08", requests: 7, input: 700, cost: 7.0,
                                 providerId: "prov-b")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        Fixture.cleanTempDirs()
    }

    /// 无时间窗 = 明细 + 全部 rollup；会话占位名走 CASE 映射也要能选中。
    func testSummaryPathsHonorProviderName() throws {
        let a = try store.rangeSummary(UsageFilter(providerName: "Provider A"), calendar: Fixture.cal)
        XCTAssertEqual(a.requests, 2 + 5, "明细 2 + rollup 5")
        XCTAssertEqual(a.cost, 2.0 + 10.0, accuracy: 1e-9)

        let logsOnly = try store.rangeSummaryLogsOnly(UsageFilter(providerName: "Provider A"))
        XCTAssertEqual(logsOnly.requests, 2)

        let session = try store.rangeSummary(UsageFilter(providerName: "Claude (Session)"), calendar: Fixture.cal)
        XCTAssertEqual(session.requests, 1, "_session 占位 id 必须按可读名选中")

        let byApp = try store.summaryByApp(UsageFilter(providerName: "Provider B"))
        XCTAssertEqual(byApp.count, 1)
        XCTAssertEqual(byApp.first?.appType, "claude")
        XCTAssertEqual(byApp.first?.summary.requests, 1 + 7)
    }

    /// Hero 总数必须等于 Provider Stats 里同名行的请求数——同屏两个数不能打架。
    func testHeroMatchesProviderStatsForEveryProvider() throws {
        let start = t - 3600, end = t + 3600
        let stats = try store.providerStats(LogQueryFilter(start: start, end: end))
        XCTAssertEqual(stats.count, 3)
        for row in stats {
            let hero = try store.rangeSummary(
                UsageFilter(start: start, end: end, providerName: row.providerName), calendar: Fixture.cal)
            XCTAssertEqual(hero.requests, Int(row.requestCount), "\(row.providerName) 的 Hero ≠ Provider Stats")
        }
    }

    /// 小时桶（≤24h，仅明细）与天桶（>24h，明细 + rollup）都要按 provider 过滤。
    func testTrendsHonorProviderName() throws {
        let hourly = try store.trendBuckets(
            filter: UsageFilter(start: t - 3600, end: t + 3600, providerName: "Provider A"),
            calendar: Fixture.cal)
        XCTAssertEqual(hourly.reduce(0) { $0 + $1.requestCount }, 2)

        // 06-07 00:00 → 06-10 23:59：整日 06-08 的 rollup 落在窗内，06-10 的明细也在
        let dayStart = Fixture.ts(2026, 6, 7), dayEnd = Fixture.ts(2026, 6, 10, 23, 59, 59)
        let dailyA = try store.trendBuckets(
            filter: UsageFilter(start: dayStart, end: dayEnd, providerName: "Provider A"),
            calendar: Fixture.cal)
        XCTAssertEqual(dailyA.reduce(0) { $0 + $1.requestCount }, 2 + 5)
        let dailyB = try store.trendBuckets(
            filter: UsageFilter(start: dayStart, end: dayEnd, providerName: "Provider B"),
            calendar: Fixture.cal)
        XCTAssertEqual(dailyB.reduce(0) { $0 + $1.requestCount }, 1 + 7)
        // 走势总和与同窗口 Hero 一致
        let heroA = try store.rangeSummary(
            UsageFilter(start: dayStart, end: dayEnd, providerName: "Provider A"), calendar: Fixture.cal)
        XCTAssertEqual(heroA.requests, 2 + 5)
    }

    /// 未入库的增量行（SessionOverlay，展示名 "Claude (Session)"）同样受 provider 筛选约束。
    func testOverlayRowsHonorProviderName() throws {
        let projects = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-provfilter-\(UUID().uuidString)")
        let projDir = (projects as NSString).appendingPathComponent("p1")
        try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projects) }
        let line = #"""
        {"type":"assistant","sessionId":"s1","timestamp":"2026-06-10T03:30:00Z","message":{"id":"ovl-1","stop_reason":"end_turn","model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":100}}}
        """#
        try (line + "\n").write(toFile: (projDir as NSString).appendingPathComponent("s.jsonl"),
                                atomically: true, encoding: .utf8)
        let withOverlay = UsageStore(
            path: dbPath,
            overlay: SessionOverlay(projectsDir: projects, minRefreshInterval: 0),
            ompOverlay: try Fixture.emptyOmpOverlay())

        let session = try withOverlay.rangeSummary(UsageFilter(providerName: "Claude (Session)"), calendar: Fixture.cal)
        XCTAssertEqual(session.requests, 1 + 1, "库内占位行 + overlay 行")
        let a = try withOverlay.rangeSummary(UsageFilter(providerName: "Provider A"), calendar: Fixture.cal)
        XCTAssertEqual(a.requests, 2 + 5, "overlay 行不属于 Provider A，不得混入")
    }
}
