import XCTest

// rollup 整日边界对齐（compute_rollup_date_bounds 口径）——两表合并防双算的关键。
final class RollupBoundsTests: XCTestCase {
    private let store = UsageStore(path: "/nonexistent")   // 只调纯函数，不开库
    private let cal = Fixture.cal

    func testMidnightStartUsesSameDay() {
        let b = store.rollupDateBounds(Fixture.ts(2026, 6, 9), nil, cal)
        XCTAssertEqual(b.start, "2026-06-09")
        XCTAssertNil(b.end)
        XCTAssertFalse(b.isEmpty)
    }

    func testMidDayStartSkipsToNextDay() {
        let b = store.rollupDateBounds(Fixture.ts(2026, 6, 9, 6, 30), nil, cal)
        XCTAssertEqual(b.start, "2026-06-10")
    }

    func testEndAt2359UsesSameDay() {
        XCTAssertEqual(store.rollupDateBounds(nil, Fixture.ts(2026, 6, 10, 23, 59), cal).end, "2026-06-10")
        // 23:59:59 也算整日尾（口径只看时分）
        XCTAssertEqual(store.rollupDateBounds(nil, Fixture.ts(2026, 6, 10, 23, 59, 59), cal).end, "2026-06-10")
    }

    func testMidDayEndFallsBackToPreviousDay() {
        XCTAssertEqual(store.rollupDateBounds(nil, Fixture.ts(2026, 6, 10, 12), cal).end, "2026-06-09")
    }

    func testInvertedRangeIsEmpty() {
        // 起止都在同一天中段：start 对齐到次日、end 对齐到前日 → 空区间
        let b = store.rollupDateBounds(Fixture.ts(2026, 6, 10, 3), Fixture.ts(2026, 6, 10, 20), cal)
        XCTAssertTrue(b.isEmpty)
    }

    func testNilBoundsStayNil() {
        let b = store.rollupDateBounds(nil, nil, cal)
        XCTAssertNil(b.start); XCTAssertNil(b.end); XCTAssertFalse(b.isEmpty)
    }
}
