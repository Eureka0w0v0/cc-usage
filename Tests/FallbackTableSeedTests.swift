import XCTest
import SQLite3

// 内置定价兜底表：同一连接重复安装时，别名预解析必须每次都跑。
// 负责杀的变异体：`alreadyFilled` 分支直接 `return true`（新出现的命名空间 id 永远进不了兜底表，
// 聚合侧精确匹配命不中 → Hero 记 $0、明细表却有价）。
final class FallbackTableSeedTests: XCTestCase {
    private var dbPath = ""
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("fallback-seed")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func fallbackInput(_ id: String) -> Double? {
        var st: OpaquePointer?
        let sql = "SELECT inp FROM \(ModelPricing.fallbackTable) WHERE model_id = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(st) }
        sqlite3_bind_text(st, 1, id, -1, SQLITE_TRANSIENT_DEST)
        return sqlite3_step(st) == SQLITE_ROW ? sqlite3_column_double(st, 0) : nil
    }

    func testReinstallOnSameConnectionSeedsNewlySeenAliases() throws {
        XCTAssertTrue(ModelPricing.installFallbackTable(db))
        XCTAssertNil(fallbackInput("anthropic/claude-opus-5"), "库里还没出现过该 id，不该预解析")

        // 库里新出现一个带命名空间的 id（只能靠候选链剥前缀才查得到价）
        try Fixture.insertLog(dbPath, id: "n1", model: "anthropic/claude-opus-5",
                              input: 100, output: 10, createdAt: Fixture.ts(2026, 6, 1, 12))
        XCTAssertTrue(ModelPricing.installFallbackTable(db))

        let expected = try XCTUnwrap(ModelPricing.lookup("claude-opus-5")).input
        XCTAssertEqual(fallbackInput("anthropic/claude-opus-5"), expected,
                       "二次安装必须把新别名灌进兜底表")
    }
}
