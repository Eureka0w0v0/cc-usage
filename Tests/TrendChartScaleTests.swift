import XCTest

// 菜单栏小窗口（SwiftUI TrendChart）与主窗口（嵌入的 cc-switch 前端，Recharts 绘制）
// 的走势图都是双纵轴：tokens 与花费各自取整定轴顶。两边取整规则不一致，两条线的
// 相对高低就对不上——2026-09-23 截图里小窗口红虚线高过紫线，主窗口恰好相反。
// 期望值全部取自主窗口实际打包的 recharts 3.5.1（cc-switch 目录下执行）：
//   node -e 'const {getNiceTickValues} = require("./node_modules/recharts/lib/util/
//            scale/getNiceTickValues.js"); console.log(getNiceTickValues([0, x], 5, true))'
final class TrendChartScaleTests: XCTestCase {

    // 复现截图现象的示例数据：峰值小时缓存读 10.5M / $4.9。
    // 主窗口轴顶 12M / $8（紫线 88%、红虚线 61%）；旧规则是 20M / $5（53% / 98%），高低反了。
    // 负责杀的变异体：小窗口仍用旧取整 / 两根轴的数据源互换。
    func testAxisMaxesMatchMainWindow() {
        let buckets = [
            TrendBucket(startTs: 0, output: 70_000, creation: 280_000, hit: 10_500_000, cost: 4.9),
            TrendBucket(startTs: 3600, output: 40_000, creation: 50_000, hit: 7_000_000, cost: 2.4),
        ]
        let axes = TrendChart.axisMaxes(buckets)
        XCTAssertEqual(axes.tokens, 12_000_000)
        XCTAssertEqual(axes.cost, 8)
    }

    // 主窗口 tokens 轴挂着 input / output / cacheCreation / cacheRead 四个 Area，
    // 轴顶取四条线的最大值。逐条单独当最大值，确认一条都没漏。
    // 负责杀的变异体：tokens 轴只看 hit（或漏掉任意一条）。
    func testTokenAxisCoversAllFourTokenLines() {
        let lines: [(String, TrendBucket)] = [
            ("input", TrendBucket(startTs: 0, input: 3_000_000, hit: 1_000_000)),
            ("output", TrendBucket(startTs: 0, output: 3_000_000, hit: 1_000_000)),
            ("creation", TrendBucket(startTs: 0, creation: 3_000_000, hit: 1_000_000)),
            ("hit", TrendBucket(startTs: 0, input: 1_000_000, hit: 3_000_000)),
        ]
        for (name, b) in lines {
            XCTAssertEqual(TrendChart.axisMaxes([b]).tokens, 3_000_000, name)
        }
    }

    // 全 0（今天还没用量 / 全是未定价模型）：Recharts 走 getTickOfSingleValue(0)，
    // 刻度 0…4，轴顶 4。花费轴同理——小窗口曲线贴底，与主窗口一致。
    func testAllZeroDataUsesRechartsSingleValueTicks() {
        let axes = TrendChart.axisMaxes([TrendBucket(startTs: 0), TrendBucket(startTs: 3600)])
        XCTAssertEqual(axes.tokens, 4)
        XCTAssertEqual(axes.cost, 4)
    }
}
