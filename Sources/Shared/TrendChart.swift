import SwiftUI
import Charts

/// 多线趋势图。interactive=true 时叠一层**独立**十字光标覆盖层：
/// 图表本身在悬停期间零重绘，光标吸附到最近数据点并用缓动滑行 → 复刻原生丝滑手感。
struct TrendChart: View {
    let buckets: [TrendBucket]
    var showAxes: Bool = true
    var interactive: Bool = false

    // 只在布局变化时更新（非悬停），供覆盖层做坐标换算
    @State private var plotRect: CGRect = .zero

    // 取整齐的坐标轴上限
    private func niceCeil(_ x: Double) -> Double {
        guard x > 0 else { return 1 }
        let e = floor(log10(x)); let base = pow(10, e); let f = x / base
        let nice: Double = f <= 1 ? 1 : f <= 2 ? 2 : f <= 2.5 ? 2.5 : f <= 3 ? 3 : f <= 4 ? 4 : f <= 5 ? 5 : f <= 6 ? 6 : f <= 8 ? 8 : 10
        return nice * base
    }
    private var tokenMax: Double {
        let m = buckets.map { max(max($0.hit, $0.creation), max($0.input, $0.output)) }.max() ?? 1
        return niceCeil(max(1, Double(m)))
    }
    private var costMax: Double { niceCeil(max(0.0001, buckets.map { $0.cost }.max() ?? 0.0001)) }
    private var factor: Double { tokenMax / costMax }
    private var yTicks: [Double] { (0...4).map { tokenMax * Double($0) / 4 } }

    private func date(_ b: TrendBucket) -> Date { Date(timeIntervalSince1970: TimeInterval(b.startTs)) }
    private var xStart: Double { Double(buckets.first?.startTs ?? 0) }
    private var xEnd: Double { max(xStart + 1, Double(buckets.last?.startTs ?? 1)) }
    private var xDomain: ClosedRange<Date> {
        Date(timeIntervalSince1970: xStart)...Date(timeIntervalSince1970: xEnd)
    }

    static func xLabel(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MM/dd, h a"
        return f.string(from: d)
    }

    var body: some View {
        chart
            .chartOverlay { proxy in
                // 用 preference 可靠上报 plot 区域（布局完成/尺寸变化都会触发，悬停不触发）
                GeometryReader { geo in
                    Color.clear.preference(key: PlotFrameKey.self,
                                           value: proxy.plotFrame.map { geo[$0] } ?? .zero)
                }
            }
            .onPreferenceChange(PlotFrameKey.self) { plotRect = $0 }
            .overlay {
                if interactive && plotRect != .zero {
                    CrosshairLayer(buckets: buckets, plot: plotRect,
                                   tokenMax: tokenMax, xStart: xStart, xEnd: xEnd)
                }
            }
    }

    // 静态图表：不含任何悬停状态，故悬停期间不会重绘
    private var chart: some View {
        Chart {
            ForEach(Array(buckets.enumerated()), id: \.offset) { _, b in
                let x = date(b)
                AreaMark(x: .value("时间", x), y: .value("Hit", b.hit))
                    .foregroundStyle(.linearGradient(colors: [Theme.hit.opacity(0.28), Theme.hit.opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                lineMark(x, b.hit, "Cache Hit", Theme.hit)
                lineMark(x, b.creation, "Cache Creation", Theme.creation)
                lineMark(x, b.input, "Input", Theme.input)
                lineMark(x, b.output, "Output", Theme.output)
                LineMark(x: .value("时间", x), y: .value("Cost", b.cost * factor), series: .value("系列", "Cost"))
                    .foregroundStyle(Theme.cost)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: 0...tokenMax)
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .leading, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [3, 3])).foregroundStyle(Theme.track)
                    AxisValueLabel {
                        if let t = value.as(Double.self) {
                            Text(Fmt.tokensAxis(Int64(t))).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
                AxisMarks(position: .trailing, values: yTicks) { value in
                    AxisValueLabel {
                        if let t = value.as(Double.self) {
                            Text("$\(Int((t / factor).rounded()))").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
            } else { AxisMarks { _ in } }
        }
        .chartXAxis {
            if showAxes {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let d = value.as(Date.self) {
                            Text(Self.xLabel(d)).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                        }
                    }
                }
            } else { AxisMarks { _ in } }
        }
        .chartLegend(.hidden)
    }

    private func lineMark(_ x: Date, _ y: Int64, _ name: String, _ color: Color) -> some ChartContent {
        LineMark(x: .value("时间", x), y: .value(name, y), series: .value("系列", name))
            .foregroundStyle(color)
            .lineStyle(StrokeStyle(lineWidth: 1.6))
            .interpolationMethod(.monotone)
    }
}

// plot 区域上报（布局时触发，悬停不触发）
struct PlotFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}

// MARK: - 独立十字光标层（图表零重绘，即时吸附数据点）

struct CrosshairLayer: View {
    let buckets: [TrendBucket]
    let plot: CGRect
    let tokenMax: Double
    let xStart: Double
    let xEnd: Double

    @State private var snapX: CGFloat?
    @State private var bucket: TrendBucket?

    private func pxForTs(_ ts: Double) -> CGFloat {
        guard xEnd > xStart else { return plot.minX }
        return plot.minX + CGFloat((ts - xStart) / (xEnd - xStart)) * plot.width
    }
    private func pyForToken(_ v: Double) -> CGFloat {
        plot.maxY - CGFloat(min(1, max(0, v / tokenMax))) * plot.height
    }
    private func nearest(atX x: CGFloat) -> TrendBucket? {
        guard plot.width > 0, xEnd > xStart else { return buckets.last }
        let frac = Double((x - plot.minX) / plot.width)
        let t = xStart + max(0, min(1, frac)) * (xEnd - xStart)
        return buckets.min { abs(Double($0.startTs) - t) < abs(Double($1.startTs) - t) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        if let b = nearest(atX: p.x) {
                            bucket = b
                            snapX = pxForTs(Double(b.startTs))
                        }
                    case .ended:
                        bucket = nil; snapX = nil
                    }
                }

            if let sx = snapX, let b = bucket {
                Rectangle().fill(Color.white.opacity(0.28))
                    .frame(width: 1, height: plot.height)
                    .position(x: sx, y: plot.midY)
                    .allowsHitTesting(false)

                Circle().fill(Theme.hit)
                    .frame(width: 9, height: 9)
                    .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                    .position(x: sx, y: pyForToken(Double(b.hit)))
                    .allowsHitTesting(false)

                let tipW: CGFloat = 210
                let rawX = sx + 14
                let x = (rawX + tipW > plot.maxX + 32) ? sx - tipW - 14 : rawX
                TrendTooltip(bucket: b)
                    .frame(width: tipW)
                    .offset(x: max(4, x), y: max(4, plot.minY + 6))
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - 悬停提示框

struct TrendTooltip: View {
    let bucket: TrendBucket
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(timeLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textMain)
            row(Theme.input, "Input", Fmt.grouped(bucket.input))
            row(Theme.output, "Output", Fmt.grouped(bucket.output))
            row(Theme.creation, "Cache Creation", Fmt.grouped(bucket.creation))
            row(Theme.hit, "Cache Hit", Fmt.grouped(bucket.hit))
            row(Theme.cost, "Cost", Fmt.cost6(bucket.cost))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0x16161C))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.14), lineWidth: 1))
        )
    }
    private var timeLabel: String {
        let d = Date(timeIntervalSince1970: TimeInterval(bucket.startTs))
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.dateFormat = "MM/dd, hh:mm a"
        return f.string(from: d)
    }
    private func row(_ c: Color, _ name: String, _ val: String) -> some View {
        HStack(spacing: 7) {
            Circle().fill(c).frame(width: 8, height: 8)
            Text("\(name):").foregroundStyle(c)
            Text(val).foregroundStyle(c.opacity(0.85))
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
    }
}

// MARK: - 图例（—o— 标记 + 同色名称）

struct ChartLegend: View {
    var fontSize: CGFloat = 13
    var body: some View {
        HStack(spacing: 18) {
            item("Cache Creation", Theme.creation)
            item("Cache Hit", Theme.hit)
            item("Cost", Theme.cost)
            item("Input", Theme.input)
            item("Output", Theme.output)
        }
        .font(.system(size: fontSize))
    }
    private func item(_ name: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Capsule().fill(color).frame(width: 16, height: 2)
                Circle().fill(Theme.bg).overlay(Circle().stroke(color, lineWidth: 1.5)).frame(width: 7, height: 7)
            }
            Text(name).foregroundStyle(color)
        }
    }
}
