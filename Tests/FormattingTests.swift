import XCTest

// Fmt 与 cc-switch 面板的紧凑写法对齐——菜单栏/面板/widget 三处共用。
final class FormattingTests: XCTestCase {

    func testTokens() {
        XCTAssertEqual(Fmt.tokens(999), "999")
        XCTAssertEqual(Fmt.tokens(1_500), "1.5K")
        XCTAssertEqual(Fmt.tokens(2_340_000), "2.34M")
        XCTAssertEqual(Fmt.tokens(1_500_000_000), "1.50B")
    }

    func testCostTiers() {
        XCTAssertEqual(Fmt.cost(0.5), "$0.500")
        XCTAssertEqual(Fmt.cost(5), "$5.00")
        XCTAssertEqual(Fmt.cost(150), "$150")
    }

    func testPercentClampAndRounding() {
        XCTAssertEqual(Fmt.percent(0.5), "50.0%")
        XCTAssertEqual(Fmt.percent(0.9995), "100%")   // ≥99.95 取整
        XCTAssertEqual(Fmt.percent(1.2), "100%")      // clamp 上限
        XCTAssertEqual(Fmt.percent(-0.1), "0.0%")     // clamp 下限
    }

    func testGrouped() {
        XCTAssertEqual(Fmt.grouped(1_234_567), "1,234,567")
    }

    func testTokensAxis() {
        XCTAssertEqual(Fmt.tokensAxis(0), "0k")
        XCTAssertEqual(Fmt.tokensAxis(1_000), "1k")
        XCTAssertEqual(Fmt.tokensAxis(1_500), "2k")
    }

    func testRelative() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Fmt.relative(nil, now: now), "—")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-30), now: now), "just now")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-120), now: now), "2m ago")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-7_200), now: now), "2h ago")
        XCTAssertEqual(Fmt.relative(now.addingTimeInterval(-172_800), now: now), "2d ago")
    }
}
