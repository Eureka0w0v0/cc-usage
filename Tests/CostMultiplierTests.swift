import XCTest
import SQLite3

// 计费倍率的读法（见 CostMultiplier）：十进制写法取值，认不出的按 1 倍，0 就是免费。
// 回归背景：汇总侧写的是 `COALESCE(NULLIF(CAST(cost_multiplier AS REAL), 0), 1.0)`、请求日志侧写的是
// `multiplier == 0 ? 1 : multiplier`，两处都把「倍率 0」当成 1 倍，零倍率的零成本行被内置表按全价补上；
// 上游（v4.0.36 b044f4b0）这种行总价恒为 0、补价直接跳过。
final class CostMultiplierTests: XCTestCase {
    private var dbPath = ""

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("cost-multiplier")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// 写法 → 期望倍率。
    private let cases: [(raw: String, expected: Double)] = [
        ("0", 0), ("0.0", 0), ("0.5", 0.5), ("0.07", 0.07), ("1", 1), ("1.0", 1), ("2.", 2), ("10", 10),
        ("", 1), ("abc", 1), (" 1", 1), ("1 ", 1), ("-1", 1), ("+1", 1), (".5", 1), ("1e3", 1),
        ("1.2.3", 1), ("1,5", 1), ("NaN", 1), ("inf", 1), ("0x1", 1),
    ]

    private func evalSQL(_ raw: String?) throws -> Double {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT \(CostMultiplier.sql("?1"))", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        if let raw {
            sqlite3_bind_text(stmt, 1, raw, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, 1)
        }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_double(stmt, 0)
    }

    // Swift 与 SQL 两种写法对每种写法给出同一个数。
    // 负责杀的变异体：SQL 侧留着 NULLIF（0 → 1）/ Swift 侧留着 `== 0 ? 1` / 不查小数点个数（`1.2.3` 在 SQL 里
    // CAST 成 1.2）/ 不查首字符（`.5` 取 0.5、` 1` 取 1）/ 放过字母（`1e3` 取 1000）。
    func testSwiftAndSQLAgreeOnEveryForm() throws {
        for c in cases {
            XCTAssertEqual(CostMultiplier.value(c.raw), c.expected, "Swift \(c.raw.debugDescription)")
            XCTAssertEqual(try evalSQL(c.raw), c.expected, "SQL \(c.raw.debugDescription)")
        }
        XCTAssertEqual(CostMultiplier.value(nil), 1)
        XCTAssertEqual(try evalSQL(nil), 1)
    }

    private func insert(_ id: String, multiplier: String, at t: Int64) throws {
        // gpt-6.2-sol：$2 / $10 每百万（内置表），库里成本记 0，等兜底补价。
        try Fixture.insertLog(dbPath, id: id, app: "codex", model: "gpt-6.2-sol",
                              input: 1_000_000, output: 100_000, cost: 0, createdAt: t,
                              dataSource: "proxy", providerId: "relay", semantics: 2)
        try Fixture.exec(dbPath, "UPDATE proxy_request_logs SET cost_multiplier = '\(multiplier)' WHERE request_id = '\(id)'")
    }

    // 端到端：同一行在汇总和请求日志里是同一个数；倍率 0 两处都是 0，0.5 补半价，认不出的按 1 倍。
    // 负责杀的变异体：只修了一处（汇总或请求日志仍把 0 当 1 倍）/ 请求日志对零倍率行仍去补价。
    func testZeroMultiplierRowsStayFreeInAggregatesAndRequestLogs() throws {
        let t = Fixture.ts(2026, 11, 20, 12)
        let full = 1.0 * 2 + 0.1 * 10   // 1M 输入 × $2 + 0.1M 输出 × $10
        let rows: [(id: String, multiplier: String, expected: Double)] = [
            ("free", "0", 0), ("free-dotted", "0.0", 0), ("half", "0.5", full / 2),
            ("garbled", "abc", full), ("empty", "", full), ("one", "1.0", full),
            // Swift 的 Double("1e3") 能解析出 1000，SQL 的 GLOB 规则不认：两处必须都按 1 倍
            ("scientific", "1e3", full),
        ]
        for (i, r) in rows.enumerated() { try insert(r.id, multiplier: r.multiplier, at: t + Int64(i) * 600) }

        let store = try Fixture.store(dbPath)
        for (i, r) in rows.enumerated() {
            let at = t + Int64(i) * 600
            let summary = try store.rangeSummary(UsageFilter(start: at - 60, end: at + 60), calendar: Fixture.cal)
            XCTAssertEqual(summary.cost, r.expected, accuracy: 1e-9, "汇总 \(r.id)")
            let detail = try XCTUnwrap(try store.requestDetail(r.id), r.id)
            XCTAssertEqual(Double(detail.totalCostUsd) ?? -1, r.expected, accuracy: 1e-6, "请求日志 \(r.id)")
        }
        // 零倍率行不补价：分项和总价都保持库里的原样字符串（补价会格式化成 6 位小数），同上游跳过补价
        let free = try XCTUnwrap(try store.requestDetail("free"))
        XCTAssertEqual(free.inputCostUsd, "0")
        XCTAssertEqual(free.totalCostUsd, "0.0")
    }
}
