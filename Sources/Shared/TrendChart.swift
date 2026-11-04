import SwiftUI
import CoreText

/// 今日小时趋势图（菜单栏弹窗、Widget 共用）——主窗口 v4 趋势图（cc-switch `UsageTrendChart.tsx`）的迷你版：
/// 单指标、单色、柱形或面积、3 档纵轴、只有横向网格。刻度与几何在 TrendYAxis / NiceScale / TrendLayout 里，
/// 都是逐条对拍上游的纯函数；这里只排版和绘制。横轴按小时写标签：两个调用方给的都是今天的小时桶。
///
/// 悬停（interactive）：图画在 Equatable 的 Canvas 里，悬停只重画指示层和提示框，图表本身不重绘。
struct TrendChart: View {
    let buckets: [TrendBucket]
    var metric: TrendMetric = .tokens
    var style: TrendChartStyle = .bar
    var showAxes: Bool = true
    var interactive: Bool = false

    @State private var hoverIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let model = TrendChartModel(buckets: buckets, metric: metric, style: style,
                                        showAxes: showAxes, size: geo.size)
            ZStack(alignment: .topLeading) {
                if let index = hoverIndex, index < model.count {
                    TrendHoverCursor(model: model, index: index)   // 画在图下面，同 recharts 的 cursor
                }
                TrendCanvas(model: model).equatable()
                if let index = hoverIndex, index < model.count {
                    TrendHoverMarker(model: model, index: index)
                }
                if interactive {
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point): hoverIndex = model.hoverIndex(at: point.x)
                            case .ended: hoverIndex = nil
                            }
                        }
                }
            }
        }
    }
}

// MARK: - 排版

/// 一次排版的结果：各桶的值、纵轴、绘图区、横轴标签。Equatable——Canvas 靠它判断要不要重画。
struct TrendChartModel: Equatable {
    static let fontSize: CGFloat = 10
    /// 纵轴文字右边缘到绘图区的距离（recharts 默认 tickSize 6 + tickMargin 2）。
    static let yLabelGap: CGFloat = 8
    /// 横轴文字顶边到绘图区底边的距离。
    static let xLabelGap: CGFloat = 4
    /// 绘图区上方留白（上游 margin.top = 6），最上面一档刻度文字的上半截要放得下。
    static let topInset: CGFloat = 6
    /// 绘图区右侧留白：面积图最后一个点的描边和悬停圆点不被切掉。
    static let rightInset: CGFloat = 4
    /// 不画坐标轴时上方留的一点空，顶满的柱子 / 描边不贴边。
    static let bareTopInset: CGFloat = 2

    struct PlacedLabel: Equatable {
        let x: CGFloat
        let text: String
    }

    let metric: TrendMetric
    let style: TrendChartStyle
    let showAxes: Bool
    let size: CGSize
    let values: [Double?]
    let hourLabels: [String]
    let axis: TrendYAxis
    let tickLabels: [String]
    let plot: CGRect
    let xs: [CGFloat]
    let xLabels: [PlacedLabel]

    var count: Int { values.count }

    init(buckets: [TrendBucket], metric: TrendMetric, style: TrendChartStyle, showAxes: Bool, size: CGSize,
         timeZone: TimeZone = .current) {
        self.metric = metric
        self.style = style
        self.showAxes = showAxes
        self.size = size
        values = buckets.map { metric.value(of: $0) }
        hourLabels = buckets.map { TrendFormat.hourLabel($0.startTs, timeZone: timeZone) }
        axis = TrendYAxis.make(metric: metric, values: values)
        tickLabels = axis.ticks.map { TrendFormat.tick($0, metric: metric) }

        if showAxes {
            let yLabelWidth = tickLabels.map { TextMeasure.width($0, font: TextMeasure.axisFont) }.max() ?? 0
            let left = yLabelWidth + Self.yLabelGap
            let bottom = Self.xLabelGap + TextMeasure.lineHeight(TextMeasure.axisFont)
            plot = CGRect(x: left, y: Self.topInset,
                          width: max(0, size.width - left - Self.rightInset),
                          height: max(0, size.height - Self.topInset - bottom))
        } else {
            plot = CGRect(x: 0, y: Self.bareTopInset, width: max(0, size.width),
                          height: max(0, size.height - Self.bareTopInset))
        }
        xs = TrendLayout.xPositions(count: values.count, style: style, plot: plot)

        if showAxes {
            let widths = hourLabels.map { TextMeasure.width($0, font: TextMeasure.axisFont) }
            let labels = hourLabels
            xLabels = TrendLayout.visibleXLabels(coordinates: xs, widths: widths, start: plot.minX, end: plot.maxX)
                .map { PlacedLabel(x: $0.x, text: labels[$0.index]) }
        } else {
            xLabels = []
        }
    }

    func hoverIndex(at x: CGFloat) -> Int? {
        TrendLayout.hoverIndex(x: x, count: count, style: style, plot: plot)
    }

    func y(_ value: Double) -> CGFloat {
        TrendLayout.y(value, axis: axis, plot: plot)
    }
}

// MARK: - 图表本体（悬停期间不重绘）

private struct TrendCanvas: View, Equatable {
    let model: TrendChartModel

    var body: some View {
        Canvas { context, _ in
            if model.showAxes { drawAxes(&context) }
            switch model.style {
            case .bar: drawBars(&context)
            case .area: drawArea(&context)
            }
        }
        .allowsHitTesting(false)
    }

    /// 横向网格线在每档刻度上（上游 `<CartesianGrid vertical={false}>`），纵轴文字右对齐，横轴文字居中。
    private func drawAxes(_ context: inout GraphicsContext) {
        let plot = model.plot
        for (tick, label) in zip(model.axis.ticks, model.tickLabels) {
            let y = model.y(tick)
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(Theme.chartGrid), lineWidth: 1)
            context.draw(axisText(label), at: CGPoint(x: plot.minX - TrendChartModel.yLabelGap, y: y), anchor: .trailing)
        }
        for label in model.xLabels {
            context.draw(axisText(label.text), at: CGPoint(x: label.x, y: plot.maxY + TrendChartModel.xLabelGap),
                         anchor: .top)
        }
    }

    private func axisText(_ text: String) -> Text {
        Text(text).font(.system(size: TrendChartModel.fontSize)).foregroundStyle(Theme.chartAxis)
    }

    private func drawBars(_ context: inout GraphicsContext) {
        for (index, value) in model.values.enumerated() {
            guard let value,
                  let rect = TrendLayout.barRect(index: index, count: model.count, value: value,
                                                 axis: model.axis, plot: model.plot) else { continue }
            let radius = TrendLayout.barCornerRadius(rect)
            let shape = UnevenRoundedRectangle(topLeadingRadius: radius, topTrailingRadius: radius, style: .circular)
            context.fill(shape.path(in: rect), with: .color(Theme.chartUsage))
        }
    }

    /// 上游 `<Area type="monotone" strokeWidth={2} fillOpacity={0.16}>`：每段连续有值的点画一块面积 + 顶边描边；
    /// 只有一个桶时画个小圆点（上游 `dot={chartData.length === 1 ? { r: 3 } : false}`）。
    private func drawArea(_ context: inout GraphicsContext) {
        let baseY = model.plot.maxY
        for run in TrendLayout.segments(model.values) where run.count >= 2 {
            let points = run.compactMap { index in model.values[index].map { CGPoint(x: model.xs[index], y: model.y($0)) } }
            guard let first = points.first, let last = points.last else { continue }
            let top = Path(TrendLayout.monotone(points))
            var fill = top
            fill.addLine(to: CGPoint(x: last.x, y: baseY))
            fill.addLine(to: CGPoint(x: first.x, y: baseY))
            fill.closeSubpath()
            context.fill(fill, with: .color(Theme.chartUsage.opacity(0.16)))
            context.stroke(top, with: .color(Theme.chartUsage), lineWidth: 2)
        }
        if model.count == 1, let value = model.values[0], let x = model.xs.first {
            let dot = Path(ellipseIn: CGRect(x: x - 3, y: model.y(value) - 3, width: 6, height: 6))
            context.fill(dot, with: .color(Theme.chartUsage.opacity(0.16)))
            context.stroke(dot, with: .color(Theme.chartUsage), lineWidth: 2)
        }
    }
}

private extension Path {
    init(_ commands: [TrendLayout.PathCommand]) {
        self.init()
        for command in commands {
            switch command {
            case .move(let p): move(to: p)
            case .line(let p): addLine(to: p)
            case .curve(let c1, let c2, let p): addCurve(to: p, control1: c1, control2: c2)
            }
        }
    }
}

// MARK: - 悬停

/// 悬停指示（画在图下面）：柱形图整格浅底，面积图虚线竖线——同上游 Tooltip 的 cursor。
private struct TrendHoverCursor: View {
    let model: TrendChartModel
    let index: Int

    var body: some View {
        Canvas { context, _ in
            let plot = model.plot
            switch model.style {
            case .bar:
                let band = TrendLayout.bandWidth(count: model.count, plot: plot)
                let rect = CGRect(x: plot.minX + CGFloat(index) * band, y: plot.minY, width: band, height: plot.height)
                context.fill(Path(rect), with: .color(Theme.chartCursor))
            case .area:
                let x = model.xs[index]
                var line = Path()
                line.move(to: CGPoint(x: x, y: plot.minY))
                line.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(line, with: .color(Theme.chartAxis), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        .allowsHitTesting(false)
    }
}

/// 悬停标记（画在图上面）：面积图当前点的圆点（recharts activeDot：r 4、白描边 2）+ 一行提示
/// 「14:00 ■ Tokens 123,148」。提示放在指针右边 10pt，放不下就放左边。
private struct TrendHoverMarker: View {
    let model: TrendChartModel
    let index: Int

    private static let pointerOffset: CGFloat = 10
    private static let fontSize: CGFloat = 11
    private static let spacing: CGFloat = 6
    private static let swatch: CGFloat = 8
    private static let padding = EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)

    var body: some View {
        let x = model.xs[index]
        let value = model.values[index]
        let hour = model.hourLabels[index]
        let text = TrendFormat.value(value, metric: model.metric)
        ZStack(alignment: .topLeading) {
            if model.style == .area, let value {
                Circle()
                    .fill(Theme.chartUsage)
                    .overlay(Circle().stroke(Color.white, lineWidth: 2))
                    .frame(width: 8, height: 8)
                    .position(x: x, y: model.y(value))
            }
            tooltip(hour: hour, value: text)
                .offset(x: tooltipX(pointer: x, width: tooltipWidth(hour: hour, value: text)), y: model.plot.minY)
        }
        .allowsHitTesting(false)
    }

    private func tooltip(hour: String, value: String) -> some View {
        HStack(spacing: Self.spacing) {
            Text(hour).font(.system(size: Self.fontSize, weight: .semibold)).foregroundStyle(Theme.tooltipText)
            RoundedRectangle(cornerRadius: 2).fill(Theme.chartUsage).frame(width: Self.swatch, height: Self.swatch)
            Text(model.metric.title).foregroundStyle(Theme.tooltipDim)
            Text(value).monospacedDigit().foregroundStyle(Theme.tooltipText)
        }
        .font(.system(size: Self.fontSize))
        .lineLimit(1)
        .padding(Self.padding)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.tooltipBg)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.track, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        )
        .fixedSize()
    }

    /// 提示框宽度（粗体按 emphasized 字体量，偏宽一点，只用来决定放左还是放右）。
    private func tooltipWidth(hour: String, value: String) -> CGFloat {
        TextMeasure.width(hour, font: TextMeasure.tipBoldFont)
            + TextMeasure.width(model.metric.title, font: TextMeasure.tipFont)
            + TextMeasure.width(value, font: TextMeasure.tipFont)
            + Self.swatch + 3 * Self.spacing + Self.padding.leading + Self.padding.trailing + 2
    }

    private func tooltipX(pointer: CGFloat, width: CGFloat) -> CGFloat {
        let right = pointer + Self.pointerOffset
        let x = right + width <= model.size.width ? right : pointer - Self.pointerOffset - width
        return min(max(0, x), max(0, model.size.width - width))
    }
}

// MARK: - 文字度量

/// 用 CoreText 量系统字体下的文字宽度（菜单栏与 Widget 共用，不依赖 AppKit）。
private enum TextMeasure {
    static let axisFont = font(.system, TrendChartModel.fontSize)
    static let tipFont = font(.system, 11)
    static let tipBoldFont = font(.emphasizedSystem, 11)

    static func width(_ text: String, font: CTFont) -> CGFloat {
        let attributed = NSAttributedString(string: text,
                                            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        return CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed), nil, nil, nil))
    }

    static func lineHeight(_ font: CTFont) -> CGFloat {
        ceil(CTFontGetAscent(font) + CTFontGetDescent(font))
    }

    private static func font(_ type: CTFontUIFontType, _ size: CGFloat) -> CTFont {
        CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }
}
