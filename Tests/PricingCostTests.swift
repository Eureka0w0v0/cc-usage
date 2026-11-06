import XCTest

/// 成本公式只有一份（PricingTable.Price.cost），各调用方的字段不能错位，运算次序也不能变。
final class PricingCostTests: XCTestCase {
    func testFourCostsUseTheirOwnPrice() {
        let price = PricingTable.Price(input: 1, output: 2, cacheRead: 3, cacheCreation: 4)
        let c = price.cost(input: 1_000_000, output: 2_000_000, cacheRead: 3_000_000, cacheCreation: 4_000_000)
        XCTAssertEqual(c.input, 1)
        XCTAssertEqual(c.output, 4)
        XCTAssertEqual(c.cacheRead, 9)
        XCTAssertEqual(c.cacheCreation, 16)
    }

    /// 负责杀的变异体：先除后乘（这组数两种次序差一个 ulp）。
    func testMultipliesBeforeDividing() {
        let tokens = 3.0, price = 1.25
        XCTAssertEqual(PricingTable.Price.cost(tokens, perMillion: price), tokens * price / 1_000_000)
        XCTAssertNotEqual(tokens * price / 1_000_000, tokens * (price / 1_000_000), "前提：这组数两种次序结果不同")
    }

    func testRowConvertsFieldByField() {
        let row = ModelPricing.Row(input: 1, output: 2, cacheRead: 3, cacheCreation: 4)
        XCTAssertEqual(PricingTable.Price(row),
                       PricingTable.Price(input: 1, output: 2, cacheRead: 3, cacheCreation: 4))
    }

    /// 上游给「input 含 cache」的应用名单加一项时最容易只改一处：fresh input 和计价 input 必须用同一份名单，
    /// 不然同一行在用量和成本里按两种口径算。两处的字符串分别对齐 sql_helpers.rs 的两个函数，所以不合并，这里盯着。
    func testBillableInputUsesTheSameCacheInclusiveListAsFreshInput() {
        let fragment = "l.app_type IN \(UsageStore.cacheInclusiveApps)"
        XCTAssertTrue(ModelPricing.billableInputSQL("l", hasSemantics: true).contains(fragment))
        XCTAssertTrue(ModelPricing.billableInputSQL("l", hasSemantics: false).contains(fragment))
    }

    func testMoneyWireFormatHasSixDecimals() {
        XCTAssertEqual(Fmt.usd6(1.5), "1.500000")
        XCTAssertEqual(Fmt.usd6(0), "0.000000")
        XCTAssertEqual(Fmt.usd6(1.2345678), "1.234568", "四舍五入到第 6 位")
    }
}
