import XCTest

// 趋势图几何的纯函数，逐条对拍主窗口实际打包的 recharts 3.5.1 / d3-shape 3.2.0（cc-switch 目录下用 node 跑出）：
// - 横轴：柱形图是 band 刻度（每格中心），面积图是 point 刻度（首尾贴边，只有一个点时居中）；
// - 柱子：barCategoryGap 默认 10%（柱宽 = 格宽 80%），maxBarSize 36，圆角 [3, 3, 0, 0] 按柱高 / 半宽夹紧；
// - 横轴标签：interval 默认 preserveEnd → getTicksEnd，minTickGap 12；
// - 面积曲线：type="monotone" 横向布局 → d3 curveMonotoneX。
final class TrendLayoutTests: XCTestCase {
    private let plot = CGRect(x: 40, y: 10, width: 280, height: 80)

    // 负责杀的变异体：band 取格左边而不是中心 / point 刻度首尾不贴边 / 单点不居中（会除零）。
    func testXPositionsUseBandOrPointScale() {
        let band = 280.0 / 15
        let bars = TrendLayout.xPositions(count: 15, style: .bar, plot: plot)
        let points = TrendLayout.xPositions(count: 15, style: .area, plot: plot)
        for i in 0..<15 {
            XCTAssertEqual(bars[i], 40 + (CGFloat(i) + 0.5) * band, accuracy: 1e-9, "bar \(i)")
            XCTAssertEqual(points[i], 40 + CGFloat(i) * 20, accuracy: 1e-9, "point \(i)")
        }
        XCTAssertEqual(TrendLayout.xPositions(count: 1, style: .area, plot: plot), [180])
        XCTAssertEqual(TrendLayout.xPositions(count: 1, style: .bar, plot: plot), [180])
        XCTAssertEqual(TrendLayout.xPositions(count: 0, style: .bar, plot: plot), [])
    }

    // 负责杀的变异体：柱宽不留两侧 10% / 不封顶 36 / 封顶后不居中 / 0 值也画出一条线。
    func testBarRectIsEightyPercentOfBandCappedAt36() {
        let axis = TrendYAxis(ticks: [0, 65_000, 130_000], domain: 0...130_000)
        let band = 280.0 / 15
        let full = TrendLayout.barRect(index: 3, count: 15, value: 130_000, axis: axis, plot: plot)!
        XCTAssertEqual(full.minX, 40 + 3 * band + 0.1 * band, accuracy: 1e-9)
        XCTAssertEqual(full.width, 0.8 * band, accuracy: 1e-9)
        XCTAssertEqual(full.minY, plot.minY, accuracy: 1e-9)
        XCTAssertEqual(full.maxY, plot.maxY, accuracy: 1e-9)

        let half = TrendLayout.barRect(index: 0, count: 15, value: 65_000, axis: axis, plot: plot)!
        XCTAssertEqual(half.height, 40, accuracy: 1e-9)

        let wide = TrendLayout.barRect(index: 1, count: 2, value: 130_000, axis: axis, plot: plot)!
        XCTAssertEqual(wide.width, 36, accuracy: 1e-9)
        XCTAssertEqual(wide.midX, 40 + 140 + 70, accuracy: 1e-9)

        XCTAssertNil(TrendLayout.barRect(index: 0, count: 15, value: 0, axis: axis, plot: plot))
    }

    // recharts Rectangle：圆角不超过柱高、也不超过半个柱宽。负责杀的变异体：矮柱子仍画 3pt 圆角（顶出一个尖）。
    func testBarCornerRadiusClampsToHeightAndHalfWidth() {
        XCTAssertEqual(TrendLayout.barCornerRadius(CGRect(x: 0, y: 0, width: 14, height: 40)), 3)
        XCTAssertEqual(TrendLayout.barCornerRadius(CGRect(x: 0, y: 0, width: 14, height: 1.5)), 1.5)
        XCTAssertEqual(TrendLayout.barCornerRadius(CGRect(x: 0, y: 0, width: 2, height: 40)), 1)
    }

    // 负责杀的变异体：纵轴方向反了 / 不减去定义域下限（命中率下限 95% 时整条线贴顶）。
    func testYMapsDomainToPlotHeight() {
        let axis = TrendYAxis(ticks: [0.95, 0.975, 1], domain: 0.95...1)
        XCTAssertEqual(TrendLayout.y(0.95, axis: axis, plot: plot), plot.maxY, accuracy: 1e-9)
        XCTAssertEqual(TrendLayout.y(1, axis: axis, plot: plot), plot.minY, accuracy: 1e-9)
        XCTAssertEqual(TrendLayout.y(0.975, axis: axis, plot: plot), plot.midY, accuracy: 1e-9)
    }

    // 字宽打桩成 字符数 × 6（"HH:mm" = 30）喂给 recharts getTicks 得到的金标准。
    // 负责杀的变异体：末尾标签不往里挪 / minTickGap 漏算 / 从左往右取（preserveStart）/ 首个标签越过左边界仍显示。
    func testVisibleXLabelsMatchRechartsPreserveEnd() {
        struct Case { let coords: [CGFloat]; let start: CGFloat; let width: CGFloat; let want: [(Int, CGFloat)] }
        func point(_ n: Int, _ x: CGFloat, _ w: CGFloat) -> [CGFloat] {
            n == 1 ? [x + w / 2] : (0..<n).map { x + CGFloat($0) * (w / CGFloat(n - 1)) }
        }
        func band(_ n: Int, _ x: CGFloat, _ w: CGFloat) -> [CGFloat] {
            (0..<n).map { x + (CGFloat($0) + 0.5) * (w / CGFloat(n)) }
        }
        let cases = [
            Case(coords: point(15, 40, 280), start: 40, width: 280,
                 want: [(2, 80), (5, 140), (8, 200), (11, 260), (14, 305)]),
            Case(coords: band(15, 40, 280), start: 40, width: 280,
                 want: [(2, 86.66666666666667), (5, 142.66666666666669), (8, 198.66666666666669),
                        (11, 254.66666666666669), (14, 305)]),
            Case(coords: point(24, 30, 290), start: 30, width: 290,
                 want: [(2, 55.21739130434783), (6, 105.65217391304347), (10, 156.08695652173913),
                        (14, 206.52173913043478), (18, 256.9565217391304), (23, 305)]),
            Case(coords: band(24, 30, 290), start: 30, width: 290,
                 want: [(2, 60.208333333333336), (6, 108.54166666666667), (10, 156.875),
                        (14, 205.20833333333334), (18, 253.54166666666669), (23, 305)]),
            Case(coords: point(1, 40, 280), start: 40, width: 280, want: [(0, 180)]),
            Case(coords: band(1, 40, 280), start: 40, width: 280, want: [(0, 180)]),
            Case(coords: point(3, 40, 280), start: 40, width: 280, want: [(1, 180), (2, 305)]),
            Case(coords: band(2, 40, 280), start: 40, width: 280, want: [(0, 110), (1, 250)]),
        ]
        for (n, c) in cases.enumerated() {
            let got = TrendLayout.visibleXLabels(coordinates: c.coords,
                                                 widths: Array(repeating: 30, count: c.coords.count),
                                                 start: c.start, end: c.start + c.width)
            XCTAssertEqual(got.map(\.index), c.want.map(\.0), "case \(n)")
            for (g, w) in zip(got, c.want) {
                XCTAssertEqual(g.x, w.1, accuracy: 1e-9, "case \(n) index \(w.0)")
            }
        }
    }

    // 柱形按指针所在的格，面积按最近的点；出了绘图区不显示。
    // 负责杀的变异体：band 用四舍五入（右半格跳到下一格）/ 越界不返回 nil / 单点时除零。
    func testHoverIndexPicksBandOrNearestPoint() {
        XCTAssertEqual(TrendLayout.hoverIndex(x: 40, count: 15, style: .bar, plot: plot), 0)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 58, count: 15, style: .bar, plot: plot), 0)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 60, count: 15, style: .bar, plot: plot), 1)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 319.9, count: 15, style: .bar, plot: plot), 14)
        XCTAssertNil(TrendLayout.hoverIndex(x: 39, count: 15, style: .bar, plot: plot))
        XCTAssertNil(TrendLayout.hoverIndex(x: 321, count: 15, style: .bar, plot: plot))

        XCTAssertEqual(TrendLayout.hoverIndex(x: 49, count: 15, style: .area, plot: plot), 0)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 51, count: 15, style: .area, plot: plot), 1)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 320, count: 15, style: .area, plot: plot), 14)
        XCTAssertEqual(TrendLayout.hoverIndex(x: 100, count: 1, style: .area, plot: plot), 0)
        XCTAssertNil(TrendLayout.hoverIndex(x: 100, count: 0, style: .area, plot: plot))
    }

    // 面积图遇到 nil 断开（recharts connectNulls 默认 false），只有命中率会出现 nil。
    func testSegmentsSplitAtMissingValues() {
        XCTAssertEqual(TrendLayout.segments([nil, 0.9, 0.95, nil, 0.8]), [[1, 2], [4]])
        XCTAssertEqual(TrendLayout.segments([0.5]), [[0]])
        XCTAssertEqual(TrendLayout.segments([nil, nil]), [])
        XCTAssertEqual(TrendLayout.segments([]), [])
    }

    // d3 curveMonotoneX（Steffen 1990）的控制点。d3 在单点线段末尾补 Z（画不出东西），这里不补——调用方本来就跳过单点段。
    // 负责杀的变异体：首尾单侧斜率公式写错 / 三点斜率不取最小值（曲线过冲）/ 两点不退化成直线 /
    // 漏掉半割线上限（直线那组：中间点斜率会从 1 变成 2，直线被画成波浪）。
    func testMonotoneMatchesD3CurveMonotoneX() {
        typealias P = CGPoint
        let cases: [([P], [TrendLayout.PathCommand])] = [
            ([P(x: 0, y: 100), P(x: 20, y: 100), P(x: 40, y: 100), P(x: 60, y: 20)], [
                .move(P(x: 0, y: 100)),
                .curve(P(x: 6.666666666666667, y: 100), P(x: 13.333333333333332, y: 100), P(x: 20, y: 100)),
                .curve(P(x: 26.666666666666668, y: 100), P(x: 33.333333333333336, y: 100), P(x: 40, y: 100)),
                .curve(P(x: 46.666666666666664, y: 100), P(x: 53.333333333333336, y: 60), P(x: 60, y: 20)),
            ]),
            ([P(x: 0, y: 80), P(x: 10, y: 20), P(x: 20, y: 60), P(x: 30, y: 60), P(x: 40, y: 0)], [
                .move(P(x: 0, y: 80)),
                .curve(P(x: 3.3333333333333335, y: 50), P(x: 6.666666666666666, y: 20), P(x: 10, y: 20)),
                .curve(P(x: 13.333333333333334, y: 20), P(x: 16.666666666666668, y: 60), P(x: 20, y: 60)),
                .curve(P(x: 23.333333333333332, y: 60), P(x: 26.666666666666668, y: 60), P(x: 30, y: 60)),
                .curve(P(x: 33.333333333333336, y: 60), P(x: 36.666666666666664, y: 30), P(x: 40, y: 0)),
            ]),
            ([P(x: 0, y: 0), P(x: 10, y: 10), P(x: 20, y: 20), P(x: 30, y: 30)], [
                .move(P(x: 0, y: 0)),
                .curve(P(x: 3.3333333333333335, y: 3.3333333333333335), P(x: 6.666666666666666, y: 6.666666666666666),
                       P(x: 10, y: 10)),
                .curve(P(x: 13.333333333333334, y: 13.333333333333334), P(x: 16.666666666666668, y: 16.666666666666668),
                       P(x: 20, y: 20)),
                .curve(P(x: 23.333333333333332, y: 23.333333333333332), P(x: 26.666666666666668, y: 26.666666666666668),
                       P(x: 30, y: 30)),
            ]),
            ([P(x: 0, y: 0), P(x: 10, y: 10), P(x: 20, y: 40), P(x: 30, y: 90)], [
                .move(P(x: 0, y: 0)),
                .curve(P(x: 3.3333333333333335, y: 1.6666666666666667), P(x: 6.666666666666666, y: 3.333333333333333),
                       P(x: 10, y: 10)),
                .curve(P(x: 13.333333333333334, y: 16.666666666666668), P(x: 16.666666666666668, y: 26.666666666666664),
                       P(x: 20, y: 40)),
                .curve(P(x: 23.333333333333332, y: 53.333333333333336), P(x: 26.666666666666668, y: 71.66666666666666),
                       P(x: 30, y: 90)),
            ]),
            ([P(x: 0, y: 50), P(x: 25, y: 10)], [.move(P(x: 0, y: 50)), .line(P(x: 25, y: 10))]),
            ([P(x: 5, y: 5)], [.move(P(x: 5, y: 5))]),
            ([P(x: 0, y: 0), P(x: 10, y: 30), P(x: 20, y: 10), P(x: 30, y: 90), P(x: 40, y: 90), P(x: 50, y: 40)], [
                .move(P(x: 0, y: 0)),
                .curve(P(x: 3.3333333333333335, y: 15), P(x: 6.666666666666666, y: 30), P(x: 10, y: 30)),
                .curve(P(x: 13.333333333333334, y: 30), P(x: 16.666666666666668, y: 10), P(x: 20, y: 10)),
                .curve(P(x: 23.333333333333332, y: 10), P(x: 26.666666666666668, y: 90), P(x: 30, y: 90)),
                .curve(P(x: 33.333333333333336, y: 90), P(x: 36.666666666666664, y: 90), P(x: 40, y: 90)),
                .curve(P(x: 43.333333333333336, y: 90), P(x: 46.666666666666664, y: 65), P(x: 50, y: 40)),
            ]),
        ]
        for (n, (points, want)) in cases.enumerated() {
            let got = TrendLayout.monotone(points)
            XCTAssertEqual(got.count, want.count, "case \(n)")
            for (g, w) in zip(got, want) {
                XCTAssertTrue(g.isClose(to: w, tolerance: 1e-9), "case \(n): \(g) ≠ \(w)")
            }
        }
    }
}

private extension TrendLayout.PathCommand {
    func isClose(to other: Self, tolerance: CGFloat) -> Bool {
        func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance }
        switch (self, other) {
        case let (.move(a), .move(b)), let (.line(a), .line(b)): return near(a, b)
        case let (.curve(a1, a2, a3), .curve(b1, b2, b3)): return near(a1, b1) && near(a2, b2) && near(a3, b3)
        default: return false
        }
    }
}
