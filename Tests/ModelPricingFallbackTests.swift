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

    // MARK: - billable input（对齐 maybe_backfill_log_costs）
    //
    // 旧实现直接拿原始 input_tokens 计价。对 codex/gemini/grokbuild 这三个
    // cache-inclusive 应用，input_tokens 里本就含着 cache_read，于是同一批 token
    // 既按 input 单价算一遍、又按 cache 单价算一遍——实测可高出数倍。

    private func summaryCost(_ day: Int = 10) throws -> Double {
        try store.rangeSummary(
            UsageFilter(start: Fixture.ts(2026, 6, day), end: Fixture.ts(2026, 6, day, 23)),
            calendar: cal).cost
    }

    /// legacy 语义（0）：input 含 cache_read，计价前要扣掉。
    /// gpt-5.2 = $1.75 / $14 / $0.175。input=100000 含 cache_read=90000
    /// → 计价 input 应为 10000：10000×1.75 + 90000×0.175 = 0.0175 + 0.01575 = 0.03325
    /// 旧口径会算成 100000×1.75 + … = 0.19075（高 5.7 倍）。
    func testCacheInclusiveAppSubtractsCacheReadBeforePricing() throws {
        try Fixture.insertLog(dbPath, id: "b1", app: "codex", model: "gpt-5.2",
                              input: 100_000, cacheRead: 90_000,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              dataSource: "codex_session", semantics: 0)
        XCTAssertEqual(try summaryCost(), 0.03325, accuracy: 1e-9)
    }

    /// total 语义（1）：input 还含 cache_creation，两者都要扣。
    /// input=100000 含 cache_read=80000 + cache_creation=10000 → 计价 input=10000。
    /// 10000×1.75 + 80000×0.175 + 10000×0 = 0.0175 + 0.014 = 0.0315
    func testTotalSemanticsSubtractsBothCacheDimensions() throws {
        try Fixture.insertLog(dbPath, id: "b2", app: "codex", model: "gpt-5.2",
                              input: 100_000, cacheRead: 80_000, cacheCreation: 10_000,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              dataSource: "codex_session", semantics: 1)
        XCTAssertEqual(try summaryCost(), 0.0315, accuracy: 1e-9)
    }

    /// fresh 语义（2）：已归一，原样计价，不能再扣。
    func testFreshSemanticsPricesInputAsIs() throws {
        try Fixture.insertLog(dbPath, id: "b3", app: "codex", model: "gpt-5.2",
                              input: 10_000, cacheRead: 90_000,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              dataSource: "codex_session", semantics: 2)
        XCTAssertEqual(try summaryCost(), 0.0175 + 0.01575, accuracy: 1e-9)
    }

    /// Claude 的 input_tokens 本来就是 fresh，任何语义下都不许扣——
    /// 杀「把扣减套到所有 app 上」的变异体。
    func testClaudeInputIsNeverReduced() throws {
        try Fixture.insertLog(dbPath, id: "b4", app: "claude", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12), semantics: 0)
        XCTAssertEqual(try summaryCost(), expected, accuracy: 1e-9)
    }

    /// 明细表与汇总必须给出同一个数（两条路曾经各算各的）。
    func testDetailRowMatchesSummaryForCacheInclusiveApp() throws {
        try Fixture.insertLog(dbPath, id: "b5", app: "codex", model: "gpt-5.2",
                              input: 100_000, cacheRead: 90_000,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              dataSource: "codex_session", semantics: 0)
        let page = try store.requestLogs(
            LogQueryFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            page: 0, pageSize: 20)
        let row = try XCTUnwrap(page.rows.first { $0.requestId == "b5" })
        XCTAssertEqual(Double(row.totalCostUsd) ?? 0, try summaryCost(), accuracy: 1e-9)
        XCTAssertEqual(Double(row.inputCostUsd) ?? 0, 0.0175, accuracy: 1e-9)
    }

    // MARK: - 计价基准解析（对齐 get_log_model_pricing_cached）

    /// `pricing_model = 'unknown'` 是占位符，等同缺失 → 回落 model。
    /// 旧实现把 "unknown" 当真模型去查价，查不到就永远记 $0。
    func testPlaceholderPricingModelFallsBackToModel() throws {
        try Fixture.insertLog(dbPath, id: "m1", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              pricingModel: "unknown")
        XCTAssertEqual(try summaryCost(), expected, accuracy: 1e-9)
    }

    /// model 本身是占位符时才启用 request_model。
    func testRequestModelUsedOnlyWhenModelIsPlaceholder() throws {
        try Fixture.insertLog(dbPath, id: "m2", model: "unknown",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              requestModel: "claude-opus-5")
        XCTAssertEqual(try summaryCost(), expected, accuracy: 1e-9)
    }

    /// model 是真实模型名但内置表没收录 → 保持 0 等补价，**不许**拿
    /// request_model 顶上：路由接管下它只是客户端别名，按别名定价会把真实上游
    /// 模型的 token 按错价永久固化。
    func testRequestModelNotUsedWhenModelIsRealButUnpriced() throws {
        try Fixture.insertLog(dbPath, id: "m3", model: "some-unlisted-model",
                              input: inTok, output: outTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              requestModel: "claude-opus-5")
        XCTAssertEqual(try summaryCost(), 0, accuracy: 1e-9)
    }

    /// `pricing_model` 是真实模型名但没定价 → 就地记 0，**不再**往下回落 model。
    /// 三者可能各不相同，换基准等于按错误价格固化。
    func testRealPricingModelDoesNotFallThroughToModel() throws {
        try Fixture.insertLog(dbPath, id: "m4", model: "claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12),
                              pricingModel: "some-unlisted-model")
        XCTAssertEqual(try summaryCost(), 0, accuracy: 1e-9)
    }

    /// Swift 侧解析函数与 SQL 侧同一套规则。
    func testResolvePricingModelRules() {
        // 1. 非占位的 pricing_model 直接用
        XCTAssertEqual(ModelPricing.resolvePricingModel(
            pricingModel: "claude-opus-5", model: "x", requestModel: "y"), "claude-opus-5")
        // 2. 占位 → 回落 model（model 有价）
        for ph in ["", "unknown", "NULL", " None "] {
            XCTAssertEqual(ModelPricing.resolvePricingModel(
                pricingModel: ph, model: "claude-opus-5", requestModel: nil), "claude-opus-5")
        }
        // 3. model 也是占位 → 用 request_model
        XCTAssertEqual(ModelPricing.resolvePricingModel(
            pricingModel: nil, model: "unknown", requestModel: "claude-opus-5"), "claude-opus-5")
        // 4. model 是真实名但无价 → 不回落
        XCTAssertNil(ModelPricing.resolvePricingModel(
            pricingModel: nil, model: "some-unlisted-model", requestModel: "claude-opus-5"))
        // 5. request_model 与 model 相同 → 不算回落
        XCTAssertNil(ModelPricing.resolvePricingModel(
            pricingModel: nil, model: "unknown", requestModel: "unknown"))
    }

    // MARK: - 别名预解析（聚合侧精确匹配 == 逐行侧候选链）

    /// 带命名空间/点号的原始 id：`lookup` 能解析，SQL 侧的精确匹配靠
    /// seedResolvedAliases 预先塞进兜底表才能跟上。两边必须给同一个数。
    func testNamespacedModelIdPricedIdenticallyInSummaryAndDetail() throws {
        try Fixture.insertLog(dbPath, id: "a1", model: "anthropic/claude-opus-5",
                              input: inTok, output: outTok,
                              cacheRead: crTok, cacheCreation: ccTok,
                              cost: 0, createdAt: Fixture.ts(2026, 6, 10, 12))
        XCTAssertEqual(try summaryCost(), expected, accuracy: 1e-9)
        let page = try store.requestLogs(
            LogQueryFilter(start: Fixture.ts(2026, 6, 10), end: Fixture.ts(2026, 6, 10, 23)),
            page: 0, pageSize: 20)
        let row = try XCTUnwrap(page.rows.first { $0.requestId == "a1" })
        XCTAssertEqual(Double(row.totalCostUsd) ?? 0, expected, accuracy: 1e-6)
    }
}
