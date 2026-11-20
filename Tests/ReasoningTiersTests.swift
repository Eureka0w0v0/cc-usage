import XCTest
import SQLite3

// 同价推理档合并（上游 #8845，v4.0.36）的判断，以及模型筛选条件。向量照搬上游
// test_reasoning_statistics_require_equal_prices_and_known_base；筛选后缀的期望值取自 v4.0.36 金标准导出。
// 库里只放上游用例的自定义价，其余（seed）由内置表兜底——内置表就是 v4.0.36 的 seed。
final class ReasoningTiersTests: XCTestCase {
    private var dbPath = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("reasoning-tiers")
        // Flash 基础价、写法不同但同价的 high、缓存读不同的 low、缓存写不同的 minimal、没有基础价的 gemini-9-pro 两档
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million) VALUES
        ('gemini-3.8-flash', '0.75', '3.75', '0.075', '0'),
        ('gemini-3.8-flash-high', '0.750', '3.750', '0.0750', '0.0'),
        ('gemini-3.8-flash-low', '0.75', '3.75', '0.15', '0'),
        ('gemini-3.8-flash-minimal', '0.75', '3.75', '0.075', '1'),
        ('gemini-9-pro-low', '1', '5', '0.1', '0'),
        ('gemini-9-pro-high', '2', '10', '0.2', '0'),
        ('claude-opus-5-5', '4', '20', '0.2', '5');
        """)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func table() throws -> PricingTable {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        return try XCTUnwrap(PricingTable.load(try XCTUnwrap(db)))
    }

    private func stat(_ t: PricingTable, _ id: String) -> String {
        ReasoningTiers.statisticsModel(id, price: t.find, directPrice: t.findDirect)
    }

    private func suffixes(_ t: PricingTable, _ id: String) -> [String] {
        ReasoningTiers.mergedSuffixes(for: id, price: t.find, directPrice: t.findDirect)
    }

    // 负责杀的变异体：不比价直接合并 / 只比部分单价 / 基础模型用完整候选链取价（gemini-9-pro 经前缀借到 -low 的价）/
    // 合并目标丢了原写法（路径、大小写）/ tiered 加档位只剥一层 / 推理档后缀区分大小写 / tiered 不认版本直接剥。
    func testMergesOnlyEqualPricesWithAKnownBase() throws {
        let t = try table()
        let merged: [(String, String)] = [
            ("gemini-3.8-flash-high", "gemini-3.8-flash"), ("gemini-3.8-flash-medium", "gemini-3.8-flash"),
            ("gemini-3.8-flash-tiered", "gemini-3.8-flash"), ("gemini-3.8-flash-tiered-high", "gemini-3.8-flash"),
            ("models/gemini-3.8-flash-tiered", "models/gemini-3.8-flash"),
            ("google/GEMINI-3.8-FLASH-TIERED", "google/GEMINI-3.8-FLASH"),
            ("gemini-4-hydrogen-high", "gemini-4-hydrogen"), ("gemini-4-hydrogen-tiered", "gemini-4-hydrogen"),
            ("gemini-4-hydrogen-tiered-high", "gemini-4-hydrogen"),
            ("models/gemini-4-hydrogen-tiered-HIGH", "models/gemini-4-hydrogen"),
            ("gemini-4-neon-high", "gemini-4-neon"), ("gemini-4-neon-xhigh", "gemini-4-neon"),
            ("claude-opus-5.5-medium", "claude-opus-5.5"), ("GPT-5.5-HIGH", "GPT-5.5"),
        ]
        for (id, expected) in merged { XCTAssertEqual(stat(t, id), expected, id) }
        for id in ["gemini-3.8-flash-low", "gemini-3.8-flash-minimal", "gemini-9-pro-low", "gemini-9-pro-medium",
                   "gemini-9-pro-high", "devstral-medium", "magistral-medium", "missing-high",
                   "gemini-3.5-flash-lite", "gemini-3.1-flash-tiered", "custom-tiered", "gemini-4-argon-tiered"] {
            XCTAssertEqual(stat(t, id), id, id)
        }
    }

    // 负责杀的变异体：只比缓存两项（输入、输出有差价也合并了）。
    func testInputOrOutputPriceDifferenceKeepsTheTierApart() throws {
        for column in ["input_cost_per_million", "output_cost_per_million"] {
            try Fixture.exec(dbPath, "UPDATE model_pricing SET \(column) = '99' WHERE model_id = 'gemini-3.8-flash-high'")
            XCTAssertEqual(stat(try table(), "gemini-3.8-flash-high"), "gemini-3.8-flash-high", column)
            try Fixture.exec(dbPath, """
            UPDATE model_pricing SET input_cost_per_million = '0.75', output_cost_per_million = '3.75'
            WHERE model_id = 'gemini-3.8-flash-high'
            """)
        }
        XCTAssertEqual(stat(try table(), "gemini-3.8-flash-high"), "gemini-3.8-flash")
    }

    // 给 `-tiered` 单独定了差价：`-tiered` 自成一行，`-tiered-high` 只并到 `-tiered`。
    // 负责杀的变异体：不比价直接合并（`-tiered-high` 会越过有差价的 `-tiered` 并到基础模型）/ 后缀不逐个验价。
    func testCustomTieredPriceKeepsTieredSeparate() throws {
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million)
        VALUES ('gemini-4-hydrogen-tiered', '2', '10', '0.1', '0');
        """)
        let t = try table()
        XCTAssertEqual(stat(t, "gemini-4-hydrogen-tiered"), "gemini-4-hydrogen-tiered")
        XCTAssertEqual(stat(t, "gemini-4-hydrogen-tiered-high"), "gemini-4-hydrogen-tiered")
        XCTAssertEqual(suffixes(t, "gemini-4-hydrogen"), ["-minimal", "-low", "-medium", "-high", "-xhigh"])
    }

    // `-tiered` 单独定的价和基础模型一样时，`-tiered-high` 直接并到基础模型：先试剥掉 tiered 的那个候选。
    // 负责杀的变异体：候选基础模型的先后反了（会停在 `-tiered`）。
    func testSamePricedTieredRowStillMergesIntoTheBase() throws {
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million)
        VALUES ('gemini-4-hydrogen-tiered', '1.50', '7.50', '0.075', '0');
        """)
        let t = try table()
        XCTAssertEqual(stat(t, "gemini-4-hydrogen-tiered-high"), "gemini-4-hydrogen")
        XCTAssertEqual(stat(t, "gemini-4-hydrogen-tiered"), "gemini-4-hydrogen")
    }

    // 只有已知会出 tiered 变体的模型（Gemini 4 Hydrogen、各版本 Gemini Flash）才剥 `-tiered`：库里给
    // `gemini-4-argon-tiered` 定了和 Argon 一模一样的价，也不合并、也不进 Argon 的筛选后缀。价格从内置表现取，
    // Argon 介绍价到期改价后用例照样成立。
    // 负责杀的变异体：任何 `-tiered` 都剥。
    func testOnlyKnownTieredFamiliesAreMerged() throws {
        let argon = try XCTUnwrap(ModelPricing.lookup("gemini-4-argon"))
        try Fixture.exec(dbPath, """
        INSERT INTO model_pricing(model_id, input_cost_per_million, output_cost_per_million,
          cache_read_cost_per_million, cache_creation_cost_per_million)
        VALUES ('gemini-4-argon-tiered', '\(argon.input)', '\(argon.output)', '\(argon.cacheRead)', '\(argon.cacheCreation)');
        """)
        let t = try table()
        XCTAssertEqual(t.find("gemini-4-argon-tiered"), t.findDirect("gemini-4-argon"), "前提：两者同价")
        XCTAssertEqual(stat(t, "gemini-4-argon-tiered"), "gemini-4-argon-tiered")
        XCTAssertEqual(suffixes(t, "gemini-4-argon"), ["-minimal", "-low", "-medium", "-high", "-xhigh"])
    }

    // 筛选基础模型时一并匹配的后缀；被并到别处的模型只做精确匹配。期望值 = v4.0.36 金标准。
    // 负责杀的变异体：自己会被合并的模型仍出后缀 / 不认识 tiered 的模型也加 tiered 后缀 / 后缀不逐个验价。
    func testFilterSuffixesMatchUpstream() throws {
        let t = try table()
        let efforts = ["-minimal", "-low", "-medium", "-high", "-xhigh"]
        let tiered = ["-tiered", "-tiered-minimal", "-tiered-low", "-tiered-medium", "-tiered-high", "-tiered-xhigh"]
        XCTAssertEqual(suffixes(t, "gemini-3.8-flash"), ["-medium", "-high", "-xhigh"] + tiered)
        XCTAssertEqual(suffixes(t, "gemini-4-hydrogen"), efforts + tiered)
        XCTAssertEqual(suffixes(t, "gpt-6.2-sol"), efforts)
        XCTAssertEqual(suffixes(t, "gemini-4-argon-high"), [])
        XCTAssertEqual(suffixes(t, "gemini-3.8-flash-high"), [], "自己有精确价、但会并到 Flash 的档位")
        XCTAssertEqual(suffixes(t, "gemini-4-hydrogen-tiered"), [])
        XCTAssertEqual(suffixes(t, "no-such-model"), [])
    }

    private func sqlMatches(_ match: ModelMatch, _ value: String) throws -> Bool {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let (condition, binds) = match.sql("v.m")
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM (SELECT ? AS m) v WHERE \(condition)"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, value, -1, transient)
        for (i, b) in binds.enumerated() {
            switch b {
            case .text(let s): sqlite3_bind_text(stmt, Int32(i + 2), s, -1, transient)
            case .int(let n): sqlite3_bind_int64(stmt, Int32(i + 2), n)
            }
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int64(stmt, 0) == 1
    }

    // 库里的行走 SQL、叠加行走 Swift，两边对任何值都要给出同一个结果。
    // 负责杀的变异体：Swift 侧后缀比较区分大小写 / 前缀不区分大小写 / 按字符数而不是字节截取 / 没有后缀时也放宽。
    func testModelMatchSQLAndSwiftAgree() throws {
        let matches = [
            ModelMatch(model: "gemini-4-argon", suffixes: ["-low", "-high", "-tiered-high"]),
            ModelMatch(model: "模型-x", suffixes: ["-high"]),
            ModelMatch(model: "gemini-4-argon", suffixes: []),
        ]
        let values = ["gemini-4-argon", "gemini-4-argon-high", "gemini-4-argon-HIGH", "gemini-4-argon-High",
                      "gemini-4-argon-tiered-HIGH", "gemini-4-argon-highx", "gemini-4-argon-preview",
                      "GEMINI-4-argon-high", "gemini-4-argo", "", "gemini-4-argon-", "gemini-4-argon-low",
                      "模型-x", "模型-x-HIGH", "模型-X-high", "模型-x-H\u{130}GH", "模型-x-high-high"]
        for m in matches {
            for v in values {
                XCTAssertEqual(m.matches(v), try sqlMatches(m, v), "\(m.model) \(m.suffixes) ← \(v)")
            }
        }
        XCTAssertTrue(matches[0].matches("gemini-4-argon-HIGH"))
        XCTAssertFalse(matches[0].matches("GEMINI-4-argon-high"), "模型名部分要逐字节相等")
        XCTAssertFalse(matches[2].matches("gemini-4-argon-high"), "没有后缀时只精确匹配")
    }
}
