import XCTest

// NiceScale 逐行移植 recharts 3.5.1 的 getNiceTickValues([0, x], 5, true)。期望值全部由
// 主窗口实际打包的那份 Recharts 算出（cc-switch 目录下执行）：
//   node -e 'const {getNiceTickValues} = require("./node_modules/recharts/lib/util/scale/
//            getNiceTickValues.js"); for (const x of [...]) console.log(x, getNiceTickValues([0, x], 5, true))'
// 负责杀的变异体：步长档位 0.05 / 0.1 的条件写反 / getDigitCount 少 +1 / ceil 写成四舍五入 /
// 全 0 分支不返回 4。
final class NiceScaleTests: XCTestCase {

    func testAxisMaxMatchesRechartsGoldenValues() {
        let golden: [(Double, Double)] = [
            (10_500_000, 12_000_000), (4.9, 8),                      // 复现截图现象的量级
            (12_000_000, 12_000_000), (12_000_001, 14_000_000),      // 恰在边界 / 刚越过边界
            (7_000_000, 8_000_000), (27_000_000, 28_000_000), (2.4, 2.4), (2.45, 2.6),
            (1, 1), (10, 12), (100, 100), (1000, 1000), (1_000_000, 1_000_000),
            (4, 4), (40, 40), (400, 400), (4000, 4000), (4_000_000, 4_000_000),  // 粗步长恰为 10ⁿ
            (0.4, 0.4), (0.004, 0.004),
            (3, 3), (2.5, 2.6), (99, 100), (101, 120), (45.5, 60),
            (0.3, 0.3), (0.35, 0.36), (0.07, 0.08), (0.0003, 0.0003), (0.00001, 0.00001),
            (8.000001, 12),
        ]
        for (x, want) in golden {
            XCTAssertEqual(NiceScale.axisMax(x), want, accuracy: want * 1e-12, "axisMax(\(x))")
        }
    }

    // getTickOfSingleValue(0, 5)：全 0 数据刻度为 0…4
    func testZeroMatchesRechartsSingleValueTicks() {
        XCTAssertEqual(NiceScale.axisMax(0), 4)
    }

    // 防御：数据不会出现这些值，但万一出现也要给出有限轴顶，不能死循环或除零
    func testInvalidInputFallsBackToFiniteMax() {
        for x in [Double.nan, .infinity, -1] {
            XCTAssertEqual(NiceScale.axisMax(x), 4, "\(x)")
        }
    }
}
