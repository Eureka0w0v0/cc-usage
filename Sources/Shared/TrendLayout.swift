import CoreGraphics

/// 趋势图几何（纯函数），逐条对齐主窗口实际打包的 recharts 3.5.1 / d3-shape 3.2.0：
/// - 横轴：柱形图（BarChart）是 band 刻度，取每格中心；面积图（AreaChart）是 point 刻度，首尾贴边，只有一个点时居中；
/// - 柱子：默认 barCategoryGap 10%（两侧各留格宽的 10%），上游 `maxBarSize={36}`、`radius={[3, 3, 0, 0]}`；
/// - 横轴标签：XAxis 默认 interval = preserveEnd（getTicksEnd），上游 `minTickGap={12}`；
/// - 面积曲线：`type="monotone"` 横向布局 → d3 curveMonotoneX。
enum TrendLayout {
    static let barCategoryGap: CGFloat = 0.1
    static let maxBarSize: CGFloat = 36
    static let barRadius: CGFloat = 3
    static let minTickGap: CGFloat = 12

    enum PathCommand: Equatable {
        case move(CGPoint)
        case line(CGPoint)
        case curve(CGPoint, CGPoint, CGPoint)
    }

    /// 横轴上要显示的一个标签：第几个桶、标签中心的横坐标（末尾那个可能为了不出界往里挪过）。
    struct XLabel: Equatable {
        let index: Int
        let x: CGFloat
    }

    static func bandWidth(count: Int, plot: CGRect) -> CGFloat {
        count > 0 ? plot.width / CGFloat(count) : 0
    }

    static func xPositions(count: Int, style: TrendChartStyle, plot: CGRect) -> [CGFloat] {
        guard count > 0 else { return [] }
        switch style {
        case .bar:
            let band = bandWidth(count: count, plot: plot)
            return (0..<count).map { plot.minX + (CGFloat($0) + 0.5) * band }
        case .area:
            guard count > 1 else { return [plot.midX] }
            let step = plot.width / CGFloat(count - 1)
            return (0..<count).map { plot.minX + CGFloat($0) * step }
        }
    }

    static func y(_ value: Double, axis: TrendYAxis, plot: CGRect) -> CGFloat {
        let span = axis.domain.upperBound - axis.domain.lowerBound
        guard span > 0 else { return plot.maxY }
        return plot.maxY - CGFloat((value - axis.domain.lowerBound) / span) * plot.height
    }

    /// 一根柱子的矩形；高度为 0（值等于定义域下限）时不画，返回 nil。
    /// 柱底在定义域下限（recharts getBaseValueOfBar：下限 > 0 时取下限，否则取 0；这里的定义域下限都 ≥ 0）。
    static func barRect(index: Int, count: Int, value: Double, axis: TrendYAxis, plot: CGRect) -> CGRect? {
        guard count > 0, (0..<count).contains(index), value.isFinite else { return nil }
        let band = bandWidth(count: count, plot: plot)
        var offset = band * barCategoryGap
        var width = band - 2 * offset
        if width > maxBarSize {
            offset += (width - maxBarSize) / 2
            width = maxBarSize
        }
        let top = y(value, axis: axis, plot: plot)
        guard top < plot.maxY else { return nil }
        return CGRect(x: plot.minX + CGFloat(index) * band + offset, y: top, width: width, height: plot.maxY - top)
    }

    /// recharts Rectangle 的圆角夹紧：不超过柱高，也不超过半个柱宽。
    static func barCornerRadius(_ rect: CGRect) -> CGFloat {
        min(barRadius, rect.width / 2, rect.height)
    }

    /// recharts getTicksEnd（sign = 1）：从最后一个标签往前取，最后一个超出右边界就往里挪；每取一个，
    /// 右边界收到它的左边缘再减 minTickGap；放不下（含越过左边界）的跳过。
    static func visibleXLabels(coordinates: [CGFloat], widths: [CGFloat], start: CGFloat, end: CGFloat,
                               minGap: CGFloat = minTickGap) -> [XLabel] {
        precondition(coordinates.count == widths.count, "每个标签都要有宽度")
        var shown: [XLabel] = []
        var limit = end
        for i in coordinates.indices.reversed() {
            let size = widths[i]
            var x = coordinates[i]
            if i == coordinates.count - 1 {
                let overflow = x + size / 2 - limit
                if overflow > 0 { x -= overflow }
            }
            let visible = x >= start && x <= limit && x - size / 2 >= start && x + size / 2 <= limit
            guard visible else { continue }
            limit = x - (size / 2 + minGap)
            shown.append(XLabel(index: i, x: x))
        }
        return shown.reversed()
    }

    /// 指针横坐标 → 悬停的桶：柱形按所在的格，面积按最近的点（recharts 按相邻刻度的中点分界，等距时就是这样）。
    /// 出了绘图区不显示。
    static func hoverIndex(x: CGFloat, count: Int, style: TrendChartStyle, plot: CGRect) -> Int? {
        guard count > 0, plot.width > 0, x >= plot.minX, x <= plot.maxX else { return nil }
        switch style {
        case .bar:
            let index = Int(((x - plot.minX) / bandWidth(count: count, plot: plot)).rounded(.down))
            return min(index, count - 1)
        case .area:
            guard count > 1 else { return 0 }
            let index = Int(((x - plot.minX) / (plot.width / CGFloat(count - 1))).rounded())
            return min(max(index, 0), count - 1)
        }
    }

    /// 面积图按缺值断开（recharts connectNulls 默认 false）：返回每一段连续有值的下标。
    static func segments(_ values: [Double?]) -> [[Int]] {
        var out: [[Int]] = []
        var run: [Int] = []
        for (i, value) in values.enumerated() {
            if let value, value.isFinite {
                run.append(i)
            } else if !run.isEmpty {
                out.append(run)
                run = []
            }
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// d3 curveMonotoneX（Steffen 1990 单调三次插值，换算成三次贝塞尔）。与 d3 的区别只有一处：单点线段 d3
    /// 末尾会补一个 Z（画不出东西），这里不补——调用方本来就跳过单点段。
    static func monotone(_ points: [CGPoint]) -> [PathCommand] {
        guard let first = points.first else { return [] }
        var curve = MonotoneX(start: first)
        for p in points.dropFirst() { curve.add(p) }
        return curve.finish()
    }

    /// d3 MonotoneX 的状态机：x0/y0、x1/y1 是最近两个点，t0 是上一个点的切线斜率。
    private struct MonotoneX {
        private(set) var commands: [PathCommand]
        private var x0 = CGFloat.nan, y0 = CGFloat.nan, x1: CGFloat, y1: CGFloat, t0 = CGFloat.nan
        private var pointCount = 1

        init(start: CGPoint) {
            commands = [.move(start)]
            x1 = start.x
            y1 = start.y
        }

        mutating func add(_ p: CGPoint) {
            if p.x == x1 && p.y == y1 { return }   // 重合的点忽略（d3 同样）
            var t1 = CGFloat.nan
            switch pointCount {
            case 1:
                pointCount = 2
            case 2:
                pointCount = 3
                t1 = slope3(p)
                bezier(slope2(t1), t1)
            default:
                t1 = slope3(p)
                bezier(t0, t1)
            }
            x0 = x1; x1 = p.x
            y0 = y1; y1 = p.y
            t0 = t1
        }

        mutating func finish() -> [PathCommand] {
            switch pointCount {
            case 2: commands.append(.line(CGPoint(x: x1, y: y1)))
            case 3: bezier(t0, slope2(t0))
            default: break
            }
            return commands
        }

        /// 两段割线斜率的调和组合，取三者绝对值最小者，符号不一致时为 0（不过冲）。
        private func slope3(_ p: CGPoint) -> CGFloat {
            let h0 = x1 - x0, h1 = p.x - x1
            let s0 = (y1 - y0) / (h0 != 0 ? h0 : (h1 < 0 ? -0.0 : 0))
            let s1 = (p.y - y1) / (h1 != 0 ? h1 : (h0 < 0 ? -0.0 : 0))
            let mid = (s0 * h1 + s1 * h0) / (h0 + h1)
            let slope = (sign(s0) + sign(s1)) * min(abs(s0), abs(s1), 0.5 * abs(mid))
            return slope.isNaN ? 0 : slope
        }

        /// 端点的单侧斜率。
        private func slope2(_ t: CGFloat) -> CGFloat {
            let h = x1 - x0
            return h != 0 ? (3 * (y1 - y0) / h - t) / 2 : t
        }

        private func sign(_ v: CGFloat) -> CGFloat { v < 0 ? -1 : 1 }

        /// 埃尔米特段 → 贝塞尔：控制点 p0 + m0/3、p1 − m1/3。
        private mutating func bezier(_ tStart: CGFloat, _ tEnd: CGFloat) {
            let dx = (x1 - x0) / 3
            commands.append(.curve(CGPoint(x: x0 + dx, y: y0 + dx * tStart),
                                   CGPoint(x: x1 - dx, y: y1 - dx * tEnd),
                                   CGPoint(x: x1, y: y1)))
        }
    }
}
