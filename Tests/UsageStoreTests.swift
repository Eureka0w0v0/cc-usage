import XCTest
import SQLite3

// UsageStore 对着临时 sqlite 库的集成测试：两表合并防双算、fresh_input、跨源去重、
// 走势分桶——全部是「口径对齐 cc-switch」的核心语义。
final class UsageStoreTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!
    private let cal = Fixture.cal

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("store")
        store = try Fixture.store(dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testLogsPlusRollupsMergeWithBoundaryAlignment() throws {
        try Fixture.insertLog(dbPath, id: "r1", input: 100, output: 10, cost: 1.0,
                              createdAt: Fixture.ts(2026, 6, 10, 12))
        try Fixture.insertRollup(dbPath, date: "2026-06-09", requests: 2, input: 50, cost: 0.5)

        // 起点是本地零点 → 6/9 的 rollup 整日纳入
        let merged = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 9), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(merged.requests, 3)
        XCTAssertEqual(merged.input, 150)
        XCTAssertEqual(merged.cost, 1.5, accuracy: 1e-9)

        // 起点在 6/9 日中 → 边界不足整日，rollup 拒收该天（交给 logs 精确覆盖，不双算）
        let boundary = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 9, 6), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(boundary.requests, 1)
        XCTAssertEqual(boundary.input, 100)
    }

    func testFreshInputSubtractsCacheReadForCodex() throws {
        try Fixture.insertLog(dbPath, id: "c1", app: "codex", model: "gpt-5",
                              input: 100, output: 10, cacheRead: 30,
                              createdAt: Fixture.ts(2026, 6, 10, 12), providerId: "_codex_session")
        let s = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 11), appType: "codex"),
            calendar: cal)
        XCTAssertEqual(s.input, 70)              // codex 的 input 含 cache_read → 减去
        XCTAssertEqual(s.tokensProcessed, 110)   // 70 + 10 + 0 + 30
    }

    func testSessionRowDedupedAgainstMatchingProxyRow() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "p1", input: 100, output: 10, cacheRead: 5, cacheCreation: 2,
                              createdAt: t, dataSource: "proxy", providerId: "packy")
        try Fixture.insertLog(dbPath, id: "s1", input: 100, output: 10, cacheRead: 5, cacheCreation: 2,
                              createdAt: t + 60, dataSource: "session_log")
        let s = try store.rangeSummary(UsageFilter(start: t - 3600, end: t + 3600), calendar: cal)
        XCTAssertEqual(s.requests, 1)   // ±10min 内指纹匹配的 session 行被剔除
        XCTAssertEqual(s.input, 100)
    }

    /// 回归：created_at 恰等于 end 且区间为整桶宽时，越界行钳入末桶应「累加」而非覆盖。
    func testHourlyTrendBoundaryRowAccumulatesIntoLastBucket() throws {
        let start = Fixture.ts(2026, 6, 10, 0)
        let end = start + 7200                  // 恰好两个整桶
        try Fixture.insertLog(dbPath, id: "a", input: 10, createdAt: start + 100)
        try Fixture.insertLog(dbPath, id: "b", input: 20, createdAt: start + 4000)
        try Fixture.insertLog(dbPath, id: "c", input: 5, createdAt: end)
        let buckets = try store.trendBuckets(
            filter: UsageFilter(start: start, end: end),
            now: Date(timeIntervalSince1970: TimeInterval(end)), calendar: cal)
        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets[0].input, 10)
        XCTAssertEqual(buckets[1].input, 25)        // 20 + 5；修复前被 5 覆盖
        XCTAssertEqual(buckets[1].requestCount, 2)
    }

    /// 天桶：logs 按 SQL 'localtime'（机器时区）分组，故本测试全程用机器时区组时间，
    /// 与生产口径一致（生产里 Calendar.current 与 'localtime' 同为机器时区）。
    func testDailyTrendMergesLogsAndRollupsWithZeroFill() throws {
        var mcal = Calendar(identifier: .gregorian)
        mcal.timeZone = TimeZone.current
        func mts(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Int64 {
            var c = DateComponents(); c.year = y; c.month = mo; c.day = d; c.hour = h
            return Int64(mcal.date(from: c)!.timeIntervalSince1970)
        }
        try Fixture.insertLog(dbPath, id: "d1", input: 5, createdAt: mts(2026, 6, 8, 10))
        try Fixture.insertRollup(dbPath, date: "2026-06-09", requests: 1, input: 11)
        try Fixture.insertLog(dbPath, id: "d2", input: 7, createdAt: mts(2026, 6, 10, 9))

        let buckets = try store.trendBuckets(
            filter: UsageFilter(start: mts(2026, 6, 8), end: mts(2026, 6, 10, 12)),
            calendar: mcal)
        XCTAssertEqual(buckets.count, 3)
        XCTAssertEqual(buckets.map(\.input), [5, 11, 7])
        XCTAssertEqual(buckets[1].startTs, mts(2026, 6, 9))   // 桶时间戳 = 本地零点
        XCTAssertEqual(buckets[1].requestCount, 1)
    }

    func testClaudeDesktopFoldsIntoClaude() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "f1", app: "claude", input: 1, createdAt: t)
        try Fixture.insertLog(dbPath, id: "f2", app: "claude-desktop", input: 2, createdAt: t)
        let byApp = try store.summaryByApp(UsageFilter(start: t - 10, end: t + 10))
        XCTAssertEqual(byApp.count, 1)
        XCTAssertEqual(byApp.first?.appType, "claude")
        XCTAssertEqual(byApp.first?.summary.input, 3)
        XCTAssertEqual(byApp.first?.summary.requests, 2)
    }

    func testRequestLogsPagination() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        for i in 0..<3 {
            try Fixture.insertLog(dbPath, id: "log\(i)", input: Int64(i), createdAt: t + Int64(i))
        }
        let page = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 2)
        XCTAssertEqual(page.total, 3)
        XCTAssertEqual(page.rows.map(\.requestId), ["log2", "log1"])   // created_at DESC
    }
}
