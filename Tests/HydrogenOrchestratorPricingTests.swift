import XCTest
import SQLite3

// Antigravity 的 Orchestrator 执行步骤导入后模型名是 `gemini-4-hydrogen-orchestrator`，没有自己的价。
// 上游 v4.0.33（#9542）在查价候选里加了一条：这个 id 再按 `gemini-4-hydrogen` 查。向量照搬上游的
// test_hydrogen_orchestrator_pricing_preserves_exact_overrides / _backfills_without_transcripts。
final class HydrogenOrchestratorPricingTests: XCTestCase {
    private var dbPath = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("hydrogen-orchestrator")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// 四种写法都落到 Hydrogen 的价。
    private let orchestratorIds = [
        "gemini-4-hydrogen-orchestrator",
        "google/GEMINI-4-HYDROGEN-ORCHESTRATOR",
        "google.gemini-4-hydrogen-orchestrator:free",
        "gemini-4-hydrogen-orchestrator-high",
    ]
    /// 长得像、但不是这一条规则管的：Orchestrator 不是任何模型都能剥的后缀。
    private let lookalikes = [
        "gemini-4-carbon-orchestrator",
        "gemini-4-hydrogen-orchestrator-preview",
        "orchestrator-carbon",
    ]

    // 负责杀的变异体：删掉这条候选规则 / 回落的基础模型没标成「只精确匹配」（v4.0.36 #9686）/
    // 规则排到推理档之前（候选顺序变了）。
    func testCandidatesAppendBaseModelAfterTheRawId() {
        typealias C = ModelId.Candidate
        XCTAssertEqual(ModelId.pricingCandidates("gemini-4-hydrogen-orchestrator"),
                       [C(id: "gemini-4-hydrogen-orchestrator", allowsPrefixMatch: true),
                        C(id: "gemini-4-hydrogen", allowsPrefixMatch: false)])
        // 带档位：原始 id → 去档位 → 基础模型，自定义的带档位价和 Orchestrator 价都排在回落价前面。
        XCTAssertEqual(ModelId.pricingCandidates("gemini-4-hydrogen-orchestrator-high"),
                       [C(id: "gemini-4-hydrogen-orchestrator-high", allowsPrefixMatch: true),
                        C(id: "gemini-4-hydrogen-orchestrator", allowsPrefixMatch: true),
                        C(id: "gemini-4-hydrogen", allowsPrefixMatch: false)])
    }

    // 负责杀的变异体：规则写成后缀剥离（任何 `-orchestrator` 结尾都剥）/ 写成前缀判断（`hasPrefix`）。
    func testLookalikesGetNoExtraCandidate() {
        for id in lookalikes {
            let ids = ModelId.pricingCandidates(id).map(\.id)
            XCTAssertFalse(ids.contains("gemini-4-hydrogen"), id)
            XCTAssertFalse(ids.contains("gemini-4-carbon"), id)
        }
    }

    // 负责杀的变异体：删掉候选规则 / 内置表缺 gemini-4-hydrogen 行。
    func testBuiltinLookupFallsBackToHydrogen() throws {
        let base = try XCTUnwrap(ModelPricing.lookup("gemini-4-hydrogen"))
        for id in orchestratorIds {
            let row = try XCTUnwrap(ModelPricing.lookup(id), id)
            XCTAssertEqual(row.input, base.input, id)
            XCTAssertEqual(row.output, base.output, id)
            XCTAssertEqual(row.cacheRead, base.cacheRead, id)
            XCTAssertEqual(row.cacheCreation, base.cacheCreation, id)
        }
        for id in lookalikes { XCTAssertNil(ModelPricing.lookup(id), id) }
    }

    private func loadPricing() throws -> PricingTable {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return try XCTUnwrap(PricingTable.load(try XCTUnwrap(db)))
    }

    private func insertPrice(_ id: String, _ input: String, _ output: String, _ cacheRead: String) throws {
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million)
        VALUES('\(id)', '\(input)', '\(output)', '\(cacheRead)', '0');
        """)
    }

    // 库里的价（用户在 cc-switch 里定的）永远优先：先是基础模型的库价，再是原始 id 的，再是带档位的。
    // 负责杀的变异体：回落候选排到原始 id 前面 / 规则直接改写 id 而不是追加候选。
    func testDatabasePricesWinInUpstreamOrder() throws {
        try insertPrice("gemini-4-hydrogen", "9", "9", "9")
        var table = try loadPricing()
        XCTAssertEqual(table.find("gemini-4-hydrogen-orchestrator")?.input, 9, "库里基础模型的价")
        XCTAssertEqual(table.find("gemini-4-hydrogen-orchestrator-high")?.input, 9)

        try insertPrice("gemini-4-hydrogen-orchestrator", "3", "12", "0.2")
        table = try loadPricing()
        XCTAssertEqual(table.find("gemini-4-hydrogen-orchestrator"),
                       PricingTable.Price(input: 3, output: 12, cacheRead: 0.2, cacheCreation: 0))
        XCTAssertEqual(table.find("gemini-4-hydrogen-orchestrator-high")?.input, 3, "去掉档位后先命中 Orchestrator 的库价")

        try insertPrice("gemini-4-hydrogen-orchestrator-high", "4", "16", "0.3")
        table = try loadPricing()
        XCTAssertEqual(table.find("gemini-4-hydrogen-orchestrator-high"),
                       PricingTable.Price(input: 4, output: 16, cacheRead: 0.3, cacheCreation: 0))
    }

    // 端到端：库里成本记成 0 的 Orchestrator 行，聚合时经兜底表补出成本；认不出的照旧是 0，已有成本的不动。
    // 负责杀的变异体：候选规则只接进了叠加层的查价、没接进兜底表的别名预解析。
    func testZeroCostRowsAreRepricedInAggregates() throws {
        let t = Fixture.ts(2026, 11, 14, 12)
        func insert(_ id: String, _ model: String, cost: Double, at offset: Int64) throws {
            try Fixture.insertLog(dbPath, id: id, app: "agy", model: model,
                                  input: 1_000_000, output: 100_000, cacheRead: 1_000_000, cacheCreation: 0,
                                  cost: cost, createdAt: t + offset, dataSource: "agy_session",
                                  providerId: "_agy_session", semantics: 2, requestModel: "Orchestrator (Carbon)")
        }
        try insert("hydrogen-history", "gemini-4-hydrogen-orchestrator", cost: 0, at: 0)
        try insert("unresolved-mode", "orchestrator-carbon", cost: 0, at: 3600)
        try insert("already-priced", "gemini-4-hydrogen-orchestrator", cost: 9, at: 7200)

        let store = try Fixture.store(dbPath)
        func cost(at offset: Int64) throws -> Double {
            try store.rangeSummary(UsageFilter(start: t + offset - 60, end: t + offset + 60), calendar: Fixture.cal).cost
        }
        // 1M × 1.50 + 0.1M × 7.50 + 1M × 0.075，每百万
        XCTAssertEqual(try cost(at: 0), 1.5 + 0.75 + 0.075, accuracy: 1e-9)
        XCTAssertEqual(try cost(at: 3600), 0, "认不出的模式名不补价")
        XCTAssertEqual(try cost(at: 7200), 9, "库里已有成本的行不动")
    }
}
