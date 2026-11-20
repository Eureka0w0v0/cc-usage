import XCTest
import SQLite3

// v4.0.36 起几类模型变体按基础模型计价：Gemini Flash 的 tiered（#9600）、Hydrogen 的 tiered（#9706）、
// Orchestrator 执行步的 worker 别名（#9686）、Claude 的 Thinking 版（56c8945f）；查价候选也从栈式展开改成队列，
// 并带上「能不能做前缀匹配」的标志。向量照搬上游 test_gemini_flash_tiered_pricing_preserves_exact_overrides /
// test_hydrogen_tiered_pricing_preserves_exact_overrides / test_orchestrator_cli_worker_alias_pricing_and_orphan_backfill /
// test_claude_thinking_pricing_matches_base_model，期望值取自 v4.0.36 seed 上跑出来的金标准。
final class ModelVariantPricingTests: XCTestCase {
    private var dbPath = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("model-variant-pricing")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private let flash: [Double] = [0.75, 3.75, 0.075, 0]          // gemini-3.8-flash
    private let hydrogen: [Double] = [1.5, 7.5, 0.075, 0]         // gemini-4-hydrogen

    private func builtin(_ id: String) -> [Double]? {
        ModelPricing.lookup(id).map { [$0.input, $0.output, $0.cacheRead, $0.cacheCreation] }
    }

    private func price(_ table: PricingTable, _ id: String) -> [Double]? {
        table.find(id).map { [$0.input, $0.output, $0.cacheRead, $0.cacheCreation] }
    }

    private func insertPrice(_ id: String, _ p: [Double]) throws {
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million)
        VALUES('\(id)', '\(p[0])', '\(p[1])', '\(p[2])', '\(p[3])');
        """)
    }

    private func loadPricing() throws -> PricingTable {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return try XCTUnwrap(PricingTable.load(try XCTUnwrap(db)))
    }

    // 负责杀的变异体：删掉 Flash tiered 规则 / 版本段校验放宽（`3..8`、`pro`、空版本也剥）/
    // 规则改成 `hasSuffix("-tiered")` 通剥（`step-3.7-flash-tiered`、`custom` 也会命中）。
    func testFlashTieredUsesBaseFlashPrice() {
        for id in ["gemini-3.8-flash-tiered", "gemini-3.8-flash-tiered-high", "models/gemini-3.8-flash-tiered",
                   "google/GEMINI-3.8-FLASH-TIERED", "google.gemini-3.8-flash-tiered:free",
                   "claude-gemini-3.8-flash-tiered", "gemini-3.8-flash-tiered-2026-09-02",
                   "gemini-3.8-flash@tiered", "gemini-3.7-flash-tiered"] {
            XCTAssertEqual(builtin(id), flash, id)
        }
        for id in ["gemini-3.8-flash-tiered-preview", "gemini-3.5-flash-lite-tiered", "gemini-3..8-flash-tiered",
                   "gemini-pro-flash-tiered", "step-3.7-flash-tiered", "custom-flash-tiered"] {
            XCTAssertNil(builtin(id), id)
        }
    }

    // 版本段不是点分数字时不剥 tiered——即使库里恰好有 `gemini-pro-flash`、`gemini-3..8-flash` 这样的行。
    // 负责杀的变异体：Flash tiered 不校验版本段。
    func testFlashTieredRequiresANumericVersion() throws {
        try insertPrice("gemini-pro-flash", [5, 5, 0.5, 0])
        try insertPrice("gemini-3..8-flash", [5, 5, 0.5, 0])
        let table = try loadPricing()
        XCTAssertNil(price(table, "gemini-pro-flash-tiered"))
        XCTAssertNil(price(table, "gemini-3..8-flash-tiered"))
    }

    // 基础 Flash 没有精确价时（内置表没有 gemini-3.1-flash），宁可不定价，也不能借前缀撞上的 `gemini-3.1-flash-lite`。
    // 负责杀的变异体：派生出来的基础模型允许前缀匹配（#9600 的 allow_prefix_match=false）。
    func testFlashTieredNeverBorrowsAPrefixMatch() {
        XCTAssertNotNil(builtin("gemini-3.1-flash-lite"), "前提：内置表有 3.1 Flash Lite")
        XCTAssertNil(builtin("gemini-3.1-flash-tiered"))
        XCTAssertNil(builtin("gemini-3.1-flash-tiered-high"))
    }

    // 负责杀的变异体：删掉 Hydrogen tiered 规则 / 规则写成前缀判断（carbon、argon 的 tiered 也会落到 Hydrogen）。
    func testHydrogenTieredUsesHydrogenPrice() {
        for id in ["gemini-4-hydrogen-tiered", "gemini-4-hydrogen-tiered-high", "gemini-4-hydrogen-tiered-medium",
                   "gemini-4-hydrogen-tiered-low", "gemini-4-hydrogen-tiered-xhigh",
                   "models/gemini-4-hydrogen-tiered-high", "google/GEMINI-4-HYDROGEN-TIERED-HIGH",
                   "google.gemini-4-hydrogen-tiered-high:free", "claude-gemini-4-hydrogen-tiered-high",
                   "gemini-4-hydrogen-tiered-high-2026-11-18"] {
            XCTAssertEqual(builtin(id), hydrogen, id)
        }
        for id in ["gemini-4-hydrogen-tiered-preview", "gemini-4-carbon-tiered-high",
                   "gemini-4-argon-tiered-high", "custom-tiered-high"] {
            XCTAssertNil(builtin(id), id)
        }
    }

    // 负责杀的变异体：删掉 worker 别名 / 别名写成前缀判断（`gemini-flash-worker` 也会落到 Hydrogen）。
    func testOrchestratorWorkerAliasUsesHydrogenPrice() {
        for id in ["gemini-flash-worker-agy", "gemini-flash-worker-agy-high", "google/GEMINI-FLASH-WORKER-AGY",
                   "google.gemini-flash-worker-agy:free", "google.gemini-flash-worker-agy-low",
                   "models/gemini-flash-worker-agy-high", "claude-gemini-flash-worker-agy"] {
            XCTAssertEqual(builtin(id), hydrogen, id)
        }
        for id in ["gemini-flash-worker-agy-preview", "gemini-flash-worker", "gemini-flash"] {
            XCTAssertNil(builtin(id), id)
        }
    }

    // 负责杀的变异体：删掉 thinking 规则 / 不限 `claude-` 开头（`kimi-k2-thinking` 会被剥成 kimi-k2）/
    // 不排除 Desktop 的第三方前缀（`claude-kimi-k2-thinking` 会被剥）/ 去掉长度判断（`claude-thinking` 剥成 `claude`）。
    func testClaudeThinkingUsesBaseModelPrice() throws {
        let opus46 = try XCTUnwrap(builtin("claude-opus-4-6"))
        for id in ["claude-opus-4.6-thinking", "claude-opus-4-6-thinking", "models/claude-opus-4.6-thinking",
                   "anthropic.claude-opus-4-6-thinking"] {
            XCTAssertEqual(builtin(id), opus46, id)
        }
        XCTAssertEqual(builtin("claude-sonnet-4.6-thinking"), builtin("claude-sonnet-4-6"))
        XCTAssertEqual(builtin("claude-haiku-4.5-thinking"), builtin("claude-haiku-4-5"))
        let kimi: [Double] = [0.55, 2.2, 0.1, 0]
        XCTAssertEqual(builtin("kimi-k2-thinking"), kimi)
        XCTAssertEqual(builtin("claude-kimi-k2-thinking"), kimi)
        XCTAssertNotEqual(builtin("kimi-k2-thinking"), builtin("kimi-k2"))
        XCTAssertNil(builtin("claude-thinking"))
        XCTAssertNil(builtin("claude-opus-9-9-thinking"))
        // 剥完只剩 `claude` 不算基础模型；基础名比 `claude-` 长的第三方 thinking 型号也不剥
        //（kimi-k2 恰好 7 个字符，单靠它挡不住「去掉 claude- 开头的判断」）。
        XCTAssertEqual(ModelId.pricingCandidates("claude-thinking").map(\.id), ["claude-thinking"])
        XCTAssertEqual(ModelId.pricingCandidates("deepseek-reasoner-thinking").map(\.id), ["deepseek-reasoner-thinking"])
        try insertPrice("acme-reasoner", [1, 2, 0.1, 0])
        XCTAssertNil(price(try loadPricing(), "acme-reasoner-thinking"))
    }

    // Claude Desktop 接第三方模型时 id 是 `claude-<第三方模型>`，按第三方模型自己的价算。
    // 负责杀的变异体：删掉 Desktop 前缀规则（之前没移植，这几个 id 全记 $0）/ 标记表漏掉 deepseek、gpt、qwen。
    func testClaudeDesktopThirdPartyPrefixUsesProviderPrice() {
        XCTAssertEqual(builtin("claude-deepseek-v4.1-flash"), builtin("deepseek-v4.1-flash"))
        XCTAssertEqual(builtin("claude-gpt-6.1-sol"), builtin("gpt-6.1-sol"))
        XCTAssertEqual(builtin("claude-qwen4-max"), builtin("qwen4-max"))
        XCTAssertNotNil(builtin("claude-deepseek-v4.1-flash"))
    }

    // 库里给变体单独定的价永远优先；带档位的先命中最具体的那一行。
    // 负责杀的变异体：tiered / thinking 的回落排到原始 id 前面（应追加在后）。
    func testDatabaseVariantPricesWin() throws {
        try insertPrice("gemini-4-hydrogen-tiered-high", [3, 12, 0.2, 0])
        try insertPrice("gemini-4-hydrogen-tiered", [2, 10, 0.1, 0])
        try insertPrice("claude-opus-4-6-thinking", [9, 45, 0.9, 11.25])
        let table = try loadPricing()
        XCTAssertEqual(price(table, "gemini-4-hydrogen-tiered-high"), [3, 12, 0.2, 0])
        XCTAssertEqual(price(table, "google.gemini-4-hydrogen-tiered-high"), [3, 12, 0.2, 0])
        XCTAssertEqual(price(table, "gemini-4-hydrogen-tiered-medium"), [2, 10, 0.1, 0])
        XCTAssertEqual(price(table, "claude-opus-4.6-thinking"), [9, 45, 0.9, 11.25])
    }

    // 库里没有基础价时，不能经前缀借 `-preview` 或别的档位的价（回落到内置表的基础价，或者干脆不定价）。
    // 负责杀的变异体：派生候选允许前缀匹配 / tiered 原名没排除出前缀匹配（会撞上 `-tiered-preview`）。
    func testDerivedBasesNeverBorrowAPrefixMatchFromTheDatabase() throws {
        try insertPrice("gemini-4-hydrogen-preview", [4, 16, 0.3, 0])
        try insertPrice("gemini-4-hydrogen-tiered-low", [1, 5, 0.1, 0])
        try insertPrice("gemini-3.1-flash-tiered-preview", [9, 9, 0.9, 0])
        let table = try loadPricing()
        XCTAssertEqual(price(table, "gemini-4-hydrogen-tiered-high"), hydrogen, "库里没有 Hydrogen → 内置表的基础价")
        XCTAssertEqual(price(table, "gemini-flash-worker-agy"), hydrogen)
        XCTAssertNil(price(table, "gemini-3.1-flash-tiered"))
    }

    // 库里缺 seed 行（用户的 cc-switch 比内置表老）、另有一条能被前缀撞上的自定义行时：内置表的精确价先于
    // 库里的前缀价——上游的库总带着 seed，精确匹配先命中。查的是「内置表 ∪ 库」，同名时库里的优先。
    // 负责杀的变异体：查价改回「库精确 → 库前缀 → 内置表」/ 同名时内置表盖过库里的价。
    func testBuiltinExactPriceBeatsADatabasePrefixMatch() throws {
        try insertPrice("gemini-4-hydrogen-tiered", [2, 10, 0.1, 0])
        var table = try loadPricing()
        XCTAssertEqual(price(table, "gemini-4-hydrogen"), hydrogen)
        XCTAssertEqual(price(table, "gemini-4-hydrogen-low"), hydrogen)
        XCTAssertEqual(price(table, "gemini-4-hydrogen-tiered"), [2, 10, 0.1, 0], "同名时库里的价优先")
        try insertPrice("gemini-4-hydrogen", [9, 9, 0.9, 0])
        table = try loadPricing()
        XCTAssertEqual(price(table, "gemini-4-hydrogen-low"), [9, 9, 0.9, 0])
        XCTAssertEqual(PricingTable().find("gemini-4-hydrogen-high").map(\.input), 1.5, "还没读库时只用内置表")
    }

    // 候选按队列展开：`claude-opus-4.6-<日期>` 先去日期得到 `claude-opus-4.6`，再点转横线得到 `claude-opus-4-6`。
    // 两个都在库里且价不同时，取前者（v4.0.34 的栈式展开会先取后者）。
    // 负责杀的变异体：展开顺序改回栈（后进先出）。
    func testCandidatesExpandBreadthFirst() throws {
        try insertPrice("claude-opus-4.6", [7, 35, 0.7, 8.75])
        try insertPrice("claude-opus-4-6", [5, 25, 0.5, 6.25])
        let table = try loadPricing()
        XCTAssertEqual(price(table, "claude-opus-4.6-20250101"), [7, 35, 0.7, 8.75])
        XCTAssertEqual(ModelId.pricingCandidates("claude-opus-4.6-20250101").map(\.id),
                       ["claude-opus-4.6-20250101", "claude-opus-4-6-20250101", "claude-opus-4.6", "claude-opus-4-6"])
    }

    // 只做精确匹配的取价（同价推理档合并用）：不剥推理档 / tiered / thinking，不做前缀。
    // 负责杀的变异体：直接价走了完整候选链（剥档位或前缀匹配）。
    func testDirectLookupDoesNotStripVariants() throws {
        XCTAssertNotNil(ModelPricing.lookupDirect("gemini-4-hydrogen"))
        XCTAssertNotNil(ModelPricing.lookupDirect("anthropic/claude-opus-4.6"), "命名空间、点转横线照常")
        for id in ["gemini-4-hydrogen-high", "gemini-4-hydrogen-tiered", "claude-opus-4-6-thinking",
                   "gemini-3.8-flash-tiered", "gemini-3.1-flash"] {
            XCTAssertNil(ModelPricing.lookupDirect(id), id)
        }
        XCTAssertNotNil(ModelPricing.lookup("gemini-3.1-flash"), "前提：完整候选链经前缀能撞上 3.1 Flash Lite")
        try insertPrice("gemini-4-hydrogen-high", [2, 9, 0.1, 0])
        let table = try loadPricing()
        XCTAssertEqual(table.findDirect("gemini-4-hydrogen-high").map(\.input), 2, "库里的精确价优先")
        XCTAssertEqual(table.findDirect("gemini-4-hydrogen").map(\.input), 1.5, "库里没有 → 内置表的精确价")
        XCTAssertNil(table.findDirect("gemini-4-hydrogen-medium"))
    }
}
