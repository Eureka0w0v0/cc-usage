import XCTest
import SQLite3

// 内置定价兜底：cc-switch 的 seed 还没收录新模型时（例如 Opus 5 发布后、上游
// v3.18.0 仍未收录），它入库会把成本写成 0，面板显示「未定价」。ModelPricing
// 让 CC Usage 用内置表现场补算，不必干等上游——本组用例锁住这个行为，以及
// 「库里已有的价永远优先」这条底线。
final class ModelPricingFallbackTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!
    private let cal = Fixture.cal

    // Opus 5：$5 / $25 / $0.50 / $6.25 每百万 token
    private let inTok: Int64 = 1_000
    private let outTok: Int64 = 2_000
    private let crTok: Int64 = 100_000
    private let ccTok: Int64 = 10_000
    /// 1000×5 + 2000×25 + 100000×0.5 + 10000×6.25，再 ÷1e6
    private let expected = 0.005 + 0.05 + 0.05 + 0.0625

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("pricing-fallback")
        store = try Fixture.store(dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    // MARK: - 内置表查找

    func testBuiltinTableHasOpus5() throws {
        let row = try XCTUnwrap(ModelPricing.lookup("claude-opus-5"))
        XCTAssertEqual(row.input, 5)
        XCTAssertEqual(row.output, 25)
        XCTAssertEqual(row.cacheRead, 0.5)
        XCTAssertEqual(row.cacheCreation, 6.25)
    }

    func testLookupNormalizesVariants() throws {
        // [1m] 上下文标记：Opus 5 的 1M 上下文无溢价，命中同一行
        XCTAssertEqual(ModelPricing.lookup("claude-opus-5[1m]")?.output, 25)
        // 命名空间前缀 / 大小写
        XCTAssertEqual(ModelPricing.lookup("anthropic.claude-opus-5")?.output, 25)
        XCTAssertEqual(ModelPricing.lookup("openrouter/anthropic/claude-opus-5")?.output, 25)
        // 未知模型不瞎猜
        XCTAssertNil(ModelPricing.lookup("totally-unknown-model"))
        XCTAssertNil(ModelPricing.lookup("unknown"))
    }

    // MARK: - 聚合成本补算

    func testUnpricedRowGetsFallbackCost() throws {
        try Fixture.insertLog(dbPath, id: "p1", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12))
        let s = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(s.cost, expected, accuracy: 1e-9)
    }

    func testExistingCostIsNeverOverwritten() throws {
        // 库里已有成本（用户可能在 cc-switch 里改过价）→ 原样保留，不被内置表覆盖
        try Fixture.insertLog(dbPath, id: "p2", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 99.0, createdAt: Fixture.ts(2026, 6, 10, 12))
        let s = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(s.cost, 99.0, accuracy: 1e-9)
    }

    func testUnknownModelStaysZero() throws {
        // 内置表也没有的模型 → 保持 0，不瞎补
        try Fixture.insertLog(dbPath, id: "p3", model: "some-unlisted-model",
                              input: inTok, output: outTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12))
        let s = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(s.cost, 0, accuracy: 1e-9)
    }

    func testRollupsSideAlsoBackfilled() throws {
        try Fixture.insertRollup(dbPath, date: "2026-06-09", model: "claude-opus-5",
                                 requests: 1, input: inTok, output: outTok,
                                 cacheRead: crTok, cacheCreation: ccTok, cost: 0)
        // 区间要跨过整个 6/9 本地日，rollup 才被纳入（不足整日的边界交给 logs，不双算）
        let s = try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, 9), end: Fixture.ts(2026, 6, 10, 23)),
            calendar: cal)
        XCTAssertEqual(s.cost, expected, accuracy: 1e-9)
    }

    // MARK: - 明细表（面板「请求日志」那张表的数据源）

    func testRequestLogDetailBackfilled() throws {
        try Fixture.insertLog(dbPath, id: "p4", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12))
        let page = try store.requestLogs(
            LogQueryFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            page: 0, pageSize: 20)
        let row = try XCTUnwrap(page.rows.first { $0.requestId == "p4" })
        // 前端 isUnpricedUsage 判的就是 totalCostUsd == 0 → 补算后不再是「未定价」
        XCTAssertEqual(Double(row.totalCostUsd) ?? 0, expected, accuracy: 1e-6)
        XCTAssertEqual(Double(row.outputCostUsd) ?? 0, 0.05, accuracy: 1e-6)
        XCTAssertEqual(Double(row.cacheCreationCostUsd) ?? 0, 0.0625, accuracy: 1e-6)
    }

    func testRequestLogDetailKeepsExistingCost() throws {
        try Fixture.insertLog(dbPath, id: "p5", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cost: 42.0, createdAt: Fixture.ts(2026, 6, 10, 12))
        let page = try store.requestLogs(
            LogQueryFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            page: 0, pageSize: 20)
        let row = try XCTUnwrap(page.rows.first { $0.requestId == "p5" })
        XCTAssertEqual(Double(row.totalCostUsd) ?? 0, 42.0, accuracy: 1e-9)
    }
}
