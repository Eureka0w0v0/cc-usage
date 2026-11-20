import XCTest

// ModelStatsMerge：模型统计最后一步的归并与排序（纯函数，不碰库）。端到端的表现见 ReasoningTierStatsTests。
final class ModelStatsMergeTests: XCTestCase {
    private func totals(_ requests: Int64, cost: Double, successes: Int64? = nil,
                        speedOutput: Int64 = 0) -> ModelStatsMerge.DBTotals {
        var t = ModelStatsMerge.DBTotals(requests: requests, tokens: requests * 10, cost: cost,
                                         successes: successes ?? requests)
        t.speed.speedOutputTokens = speedOutput
        return t
    }

    // 成本降序，同成本按模型名升序（上游 total_cmp 之后 then_with 模型名）。
    // 负责杀的变异体：同成本按模型名降序 / 只按成本排（同成本时次序跟着字典遍历走）。
    func testSortsByCostThenModelName() {
        let rows = ModelStatsMerge.rows(db: ["b": totals(1, cost: 2), "a": totals(1, cost: 2), "c": totals(1, cost: 5)],
                                        overlay: [:], exactSamples: [:], estimatedSamples: [:], statisticsModel: { $0 })
        XCTAssertEqual(rows.map(\.model), ["c", "a", "b"])
    }

    // 库内合计、叠加行分组都按统计口径相加；首字样本合到一起再取中位数（不是各档中位数的中位数或平均）。
    // 负责杀的变异体：样本没合并（只取基础档的）/ 叠加行没按统计口径归并 / 速度累计漏加 / 成功数漏加叠加行。
    func testMergesTotalsOverlayAndPooledSamples() {
        var overlay = OverlayStats.Group()
        overlay.requests = 2
        overlay.successes = 1
        overlay.tokens = 7
        overlay.cost = 1.5
        let rows = ModelStatsMerge.rows(
            db: ["m": totals(1, cost: 1, speedOutput: 100), "m-high": totals(2, cost: 2, successes: 1, speedOutput: 50)],
            overlay: ["m-low": overlay],
            exactSamples: ["m": [10], "m-high": [20, 30], "m-medium": [1000, 2000, 3000]],
            estimatedSamples: ["m-low": [5]],
            statisticsModel: { $0.hasPrefix("m") ? "m" : $0 })
        XCTAssertEqual(rows.map(\.model), ["m"])
        let r = rows[0]
        XCTAssertEqual(r.requestCount, 5)
        XCTAssertEqual(r.totalTokens, 10 + 20 + 7)
        XCTAssertEqual(r.totalCost, 4.5, accuracy: 1e-12)
        XCTAssertEqual(r.avgCostPerRequest, 0.9, accuracy: 1e-12)
        XCTAssertEqual(r.successRate, 3.0 / 5.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(r.performance.speedOutputTokens, 150)
        XCTAssertEqual(r.performance.firstTokenMedianMs, 515)
        XCTAssertEqual(r.performance.estFirstTokenMedianMs, 5)
    }
}
