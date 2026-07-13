import SwiftUI
import WidgetKit

struct UsageWidgetEntryView: View {
    var entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let snap = entry.snapshot {
            switch family {
            case .systemSmall:  SmallView(snap: snap)
            case .systemMedium: MediumView(snap: snap)
            default:            LargeView(snap: snap)
            }
        } else {
            ErrorView(text: entry.errorText ?? "No data")
        }
    }
}

// MARK: - 小尺寸

struct SmallView: View {
    let snap: UsageSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(lastEvent: snap.lastEventAt)
            Spacer(minLength: 0)
            Text(Fmt.tokens(snap.today.tokensProcessed))
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textMain)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text("Tokens today").font(.system(size: 10)).foregroundStyle(Theme.textDim)
            HStack(spacing: 6) {
                Text(Fmt.cost(snap.today.cost)).foregroundStyle(Theme.output)
                Text("·").foregroundStyle(Theme.textDim)
                Text("\(snap.today.requests) req").foregroundStyle(Theme.textDim)
            }.font(.system(size: 11, weight: .medium))
            HitRateBar(ratio: snap.today.cacheHitRate)
        }
        .padding(14)
    }
}

// MARK: - 中尺寸

struct MediumView: View {
    let snap: UsageSnapshot
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HeaderRow(lastEvent: snap.lastEventAt)
                Spacer(minLength: 0)
                Text(Fmt.tokens(snap.today.tokensProcessed))
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textMain)
                    .minimumScaleFactor(0.6).lineLimit(1)
                Text("Tokens today").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                HStack(spacing: 6) {
                    Text(Fmt.cost(snap.today.cost)).foregroundStyle(Theme.output)
                    Text("·").foregroundStyle(Theme.textDim)
                    Text("\(snap.today.requests) req").foregroundStyle(Theme.textDim)
                }.font(.system(size: 11, weight: .medium))
                HitRateBar(ratio: snap.today.cacheHitRate)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text("Today's trend").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                TrendChart(buckets: snap.trend, showAxes: false)
                    .frame(maxHeight: .infinity)
                Text("Total \(Fmt.tokens(snap.cumulative.tokensProcessed)) · \(Fmt.cost(snap.cumulative.cost))")
                    .font(.system(size: 9)).foregroundStyle(Theme.textDim)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(14)
    }
}

// MARK: - 大尺寸

struct LargeView: View {
    let snap: UsageSnapshot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HeaderRow(lastEvent: snap.lastEventAt)
                    Text(Fmt.tokens(snap.today.tokensProcessed))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textMain)
                    Text("Tokens today").font(.system(size: 10)).foregroundStyle(Theme.textDim)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Stat(label: "TOTAL COST", value: Fmt.cost(snap.today.cost), color: Theme.output)
                    Stat(label: "REQUESTS", value: "\(snap.today.requests)", color: Theme.accent)
                    Stat(label: "HIT RATE", value: Fmt.percent(snap.today.cacheHitRate), color: Theme.hit)
                }
            }

            MetricStrip(today: snap.today)

            TrendChart(buckets: snap.trend, showAxes: true)
                .frame(maxHeight: .infinity)

            ChartLegend()
        }
        .padding(16)
    }
}

// MARK: - 复用小组件

/// 顶部：闪电图标 + Today + 更新时间
struct HeaderRow: View {
    let lastEvent: Date?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
            Text("Today").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMain)
            Spacer(minLength: 0)
            Text(Fmt.relative(lastEvent)).font(.system(size: 9)).foregroundStyle(Theme.textDim)
        }
    }
}

/// 缓存命中率进度条
struct HitRateBar: View {
    let ratio: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Cache Hit").font(.system(size: 9)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(Fmt.percent(ratio)).font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.hit)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    Capsule().fill(Theme.hit)
                        .frame(width: geo.size.width * max(0, min(1, ratio)))
                }
            }.frame(height: 5)
        }
    }
}

struct Stat: View {
    let label: String; let value: String; let color: Color
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(label).font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
    }
}

/// 大尺寸中部：Input / Output / Creation / Hit 四小块
struct MetricStrip: View {
    let today: UsageSummary
    var body: some View {
        HStack(spacing: 8) {
            cell("Fresh Input", Fmt.tokens(today.input), Theme.input)
            cell("Output", Fmt.tokens(today.output), Theme.output)
            cell("Creation", Fmt.tokens(today.creation), Theme.creation)
            cell("Hit", Fmt.tokens(today.hit), Theme.hit)
        }
    }
    private func cell(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 8)).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ErrorView: View {
    let text: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            Text("Failed to read cc-switch data").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textMain)
            Text(text).font(.system(size: 8)).foregroundStyle(Theme.textDim).lineLimit(3)
        }
        .padding()
    }
}
