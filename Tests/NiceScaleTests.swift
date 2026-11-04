import XCTest

// NiceScale 逐行移植 recharts 3.5.1 的两套取刻度算法，期望值全部由主窗口实际打包的那份 Recharts 算出
// （cc-switch 目录下执行）：
//   node -e 'const s = require("./node_modules/recharts/lib/util/scale/getNiceTickValues.js");
//            console.log(s.getNiceTickValues([0, x], n, true), s.getTickValuesFixedDomain([f, 1], 3, true))'
// - niceTicks：默认定义域 [0, 'auto'] 走 getNiceTickValues，轴顶跟着刻度往上取整；
// - fixedDomainTicks：命中率给了定义域 [下限, 1]，走 getTickValuesFixedDomain，刻度不出界。
// 刻度值逐个精确比较：十进制步长换回 Double 时差一个 ulp，金额刻度就会写成 0.35000000000000003。
final class NiceScaleTests: XCTestCase {

    // 主窗口 v4 的趋势图 `<YAxis tickCount={3}>`。
    // 负责杀的变异体：步长档位 0.05 / 0.1 的条件写反 / getDigitCount 少 +1 / ceil 写成四舍五入 /
    // 刻度数仍按 5 算 / Decimal 换 Double 不经十进制字符串（差一个 ulp）。
    func testThreeTicksMatchRechartsGolden() {
        let golden: [(Double, [Double])] = [
            (1, [0, 0.5, 1]), (2.5, [0, 2, 4]), (4.9, [0, 3, 6]), (10, [0, 5, 10]),
            (99, [0, 50, 100]), (101, [0, 55, 110]), (123_456, [0, 65_000, 130_000]),
            (98_765, [0, 50_000, 100_000]), (1250, [0, 650, 1300]), (2500, [0, 1500, 3000]),
            (0.684, [0, 0.35, 0.7]), (0.07, [0, 0.035, 0.07]), (0.3, [0, 0.15, 0.3]), (0.35, [0, 0.2, 0.4]),
            (12_000_000, [0, 6_000_000, 12_000_000]), (12_000_001, [0, 6_500_000, 13_000_000]),
            (7_000_000, [0, 3_500_000, 7_000_000]), (45.5, [0, 25, 50]), (3, [0, 2, 4]), (7, [0, 4, 8]),
            (0.00001, [0, 0.000005, 0.00001]), (0.00042, [0, 0.00025, 0.0005]),
            (999_999, [0, 500_000, 1_000_000]), (1_000_001, [0, 550_000, 1_100_000]),
        ]
        for (x, want) in golden {
            XCTAssertEqual(NiceScale.niceTicks(dataMax: x, tickCount: 3), want, "niceTicks(\(x), 3)")
        }
    }

    // 同一份移植在 tickCount 5 下的轴顶（旧版双纵轴时代对拍过的金标准，继续用来钉住通用算法）。
    func testFiveTickAxisMaxMatchesRechartsGolden() {
        let golden: [(Double, Double)] = [
            (10_500_000, 12_000_000), (4.9, 8),
            (12_000_000, 12_000_000), (12_000_001, 14_000_000),
            (7_000_000, 8_000_000), (27_000_000, 28_000_000), (2.4, 2.4), (2.45, 2.6),
            (1, 1), (10, 12), (100, 100), (1000, 1000), (1_000_000, 1_000_000),
            (4, 4), (40, 40), (400, 400), (4000, 4000), (4_000_000, 4_000_000),
            (0.4, 0.4), (0.004, 0.004),
            (3, 3), (2.5, 2.6), (99, 100), (101, 120), (45.5, 60),
            (0.3, 0.3), (0.35, 0.36), (0.07, 0.08), (0.0003, 0.0003), (0.00001, 0.00001),
            (8.000001, 12),
        ]
        for (x, want) in golden {
            let ticks = NiceScale.niceTicks(dataMax: x, tickCount: 5)
            XCTAssertEqual(ticks.count, 5, "niceTicks(\(x), 5)")
            XCTAssertEqual(ticks.last, want, "axisMax(\(x))")
        }
    }

    // 全 0 数据走 getTickOfSingleValue(0)：刻度 0…tickCount-1。数据不会出现 NaN / ∞ / 负数，
    // 万一出现也给出有限刻度，不能死循环或除零。负责杀的变异体：全 0 分支返回空数组或 [0]。
    func testZeroAndInvalidUseSingleValueTicks() {
        for x in [0, Double.nan, .infinity, -1] {
            XCTAssertEqual(NiceScale.niceTicks(dataMax: x, tickCount: 3), [0, 1, 2], "\(x)")
            XCTAssertEqual(NiceScale.niceTicks(dataMax: x, tickCount: 5), [0, 1, 2, 3, 4], "\(x)")
        }
    }

    // 命中率纵轴：定义域 [下限, 1]，下限取自 hitRateAxisFloor（0 或 0.5…0.95 的 5% 整档）。
    // 刻度可以不等距（0.55 → 0.8 → 1），最后一个永远是 1。
    // 负责杀的变异体：改用 niceTicks（会冲出 100%）/ 漏掉末尾补上的上界 / rangeStep 用 ≤ 导致末位重复。
    func testFixedDomainTicksMatchRechartsGolden() {
        let golden: [(Double, [Double])] = [
            (0, [0, 0.5, 1]), (0.5, [0.5, 0.75, 1]), (0.55, [0.55, 0.8, 1]), (0.6, [0.6, 0.8, 1]),
            (0.65, [0.65, 0.85, 1]), (0.7, [0.7, 0.85, 1]), (0.75, [0.75, 0.9, 1]), (0.8, [0.8, 0.9, 1]),
            (0.85, [0.85, 0.925, 1]), (0.9, [0.9, 0.95, 1]), (0.95, [0.95, 0.975, 1]),
        ]
        for (floor, want) in golden {
            XCTAssertEqual(NiceScale.fixedDomainTicks(min: floor, max: 1, tickCount: 3), want, "fixed([\(floor), 1])")
        }
    }

    // 上下限相同（数据退化）时只有一个刻度，与 Recharts 一致。
    func testFixedDomainWithEqualBoundsHasSingleTick() {
        XCTAssertEqual(NiceScale.fixedDomainTicks(min: 1, max: 1, tickCount: 3), [1])
    }
}
