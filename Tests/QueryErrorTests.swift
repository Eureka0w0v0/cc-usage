import XCTest
import SQLite3

/// 查询半路出错（库损坏、读到一半被占用）不能当成「没有更多行」：部分聚合会被当真值显示。
/// 只写坏数据表的页：schema 读得出来，prepare 能过，第一次 step 才报错。
final class QueryErrorTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!
    private let cal = Fixture.cal
    private let start = Fixture.ts(2026, 6, 1)
    private let end = Fixture.ts(2026, 6, 20)
    private let hourEnd = Fixture.ts(2026, 6, 1, 1)

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("query-error")
        store = try Fixture.store(dbPath)
        try Fixture.insertLog(dbPath, id: "r1", input: 100, createdAt: Fixture.ts(2026, 6, 10, 12))
        try Fixture.insertRollup(dbPath, date: "2026-06-09", requests: 2, input: 50)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// 把某张表（连同它的索引）的根页写成垃圾。
    private func corrupt(table: String) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &db), SQLITE_OK)
        var stmt: OpaquePointer?
        let sql = "SELECT rootpage FROM sqlite_master WHERE tbl_name = '\(table)' AND rootpage > 0"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        var pages: [Int64] = []
        while sqlite3_step(stmt) == SQLITE_ROW { pages.append(sqlite3_column_int64(stmt, 0)) }
        sqlite3_finalize(stmt)
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA page_size", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        let pageSize = sqlite3_column_int64(stmt, 0)
        sqlite3_finalize(stmt)
        sqlite3_close(db)

        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: dbPath))
        defer { try? fh.close() }
        XCTAssertFalse(pages.isEmpty)
        for page in pages {
            try fh.seek(toOffset: UInt64((page - 1) * pageSize))
            try fh.write(contentsOf: Data(repeating: 0xFF, count: Int(pageSize)))
        }
    }

    private func assertStepError(_ label: String, _ body: () throws -> Void) {
        XCTAssertThrowsError(try body(), label) { error in
            guard case UsageStoreError.step = error else {
                return XCTFail("\(label)：应该抛 .step，实际 \(error)")
            }
        }
    }

    private var wide: UsageFilter { UsageFilter(start: start, end: end) }
    private var hour: UsageFilter { UsageFilter(start: start, end: hourEnd) }

    func testDetailTableErrorsSurface() throws {
        try corrupt(table: "proxy_request_logs")
        assertStepError("rangeSummary") { _ = try store.rangeSummary(wide, calendar: cal) }
        assertStepError("summaryByApp") { _ = try store.summaryByApp(wide) }
        assertStepError("hourly trend") { _ = try store.trendBuckets(filter: hour, calendar: cal) }
        assertStepError("daily trend") { _ = try store.trendBuckets(filter: wide, calendar: cal) }
        assertStepError("requestLogs") { _ = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20) }
        assertStepError("providerStats") { _ = try store.providerStats(LogQueryFilter(), calendar: cal) }
        assertStepError("modelStats") { _ = try store.modelStats(LogQueryFilter(), calendar: cal) }
        assertStepError("dataSourceBreakdown") { _ = try store.dataSourceBreakdown() }
        assertStepError("firstUsageDate") { _ = try store.firstUsageDate(UsageFilter(), calendar: cal) }
    }

    func testRollupTableErrorsSurface() throws {
        try corrupt(table: "usage_daily_rollups")
        assertStepError("rangeSummary") { _ = try store.rangeSummary(wide, calendar: cal) }
        assertStepError("summaryByApp") { _ = try store.summaryByApp(wide) }
        assertStepError("daily trend") { _ = try store.trendBuckets(filter: wide, calendar: cal) }
        assertStepError("providerStats") { _ = try store.providerStats(LogQueryFilter(), calendar: cal) }
        assertStepError("modelStats") { _ = try store.modelStats(LogQueryFilter(), calendar: cal) }
        assertStepError("firstUsageDate") { _ = try store.firstUsageDate(UsageFilter(), calendar: cal) }
    }

    /// 负责杀的变异体：统计主查询之前的首字样本查询不抛。只写坏明细时它先撞上错误；
    /// 这里让明细完好、把 SUM 撑到溢出，错误出在主查询（SUM 的整数溢出是 step 时的 SQLITE_ERROR）。
    func testAggregateOverflowInMainStatsQuerySurfaces() throws {
        try Fixture.insertLog(dbPath, id: "big1", output: Int64.max, createdAt: Fixture.ts(2026, 6, 10, 13))
        try Fixture.insertLog(dbPath, id: "big2", output: Int64.max, createdAt: Fixture.ts(2026, 6, 10, 14))
        assertStepError("providerStats") { _ = try store.providerStats(LogQueryFilter(), calendar: cal) }
        assertStepError("modelStats") { _ = try store.modelStats(LogQueryFilter(), calendar: cal) }
        assertStepError("rangeSummary") { _ = try store.rangeSummary(wide, calendar: cal) }
    }
}
