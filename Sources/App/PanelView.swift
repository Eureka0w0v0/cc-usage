import SwiftUI

/// 1:1 复刻 cc-switch「Usage Trends」整块面板（字号/间距/配色对齐 UsageHero + UsageDashboard）。
public struct PanelView: View {
    let snap: UsageSnapshot
    let rangeLabel: String
    let interactive: Bool
    public init(snap: UsageSnapshot, rangeLabel: String = "Today", interactive: Bool = true) {
        self.snap = snap; self.rangeLabel = rangeLabel; self.interactive = interactive
    }

    private var s: UsageSummary { snap.today }

    public var body: some View {
        VStack(alignment: .leading, spacing: 32) {   // UsageDashboard space-y-8 = 32
            // ── 面板 1：Hero 汇总（Card rounded-lg 12 / bg-card/60 / p-5 20）──
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    SummaryHeader(tokens: s.tokensProcessed)
                    Spacer()
                    RequestsCostBox(requests: s.requests, cost: s.cost)
                }
                HStack(spacing: 12) {
                    MetricCard(icon: "arrow.down.to.line", tint: Theme.appleBlue, title: "Fresh Input", value: Fmt.tokens(s.input))
                    MetricCard(icon: "arrow.up.to.line", tint: Theme.hit, title: "Output", value: Fmt.tokens(s.output))
                    MetricCard(icon: "cylinder.split.1x2", tint: Theme.amber, title: "Creation", value: Fmt.tokens(s.creation))
                    MetricCard(icon: "sparkles", tint: Theme.emerald, title: "Hit", value: Fmt.tokens(s.hit))
                    HitRateCard(ratio: s.cacheHitRate)
                }
            }
            .padding(20)
            .background(panelBox(radius: 12, fill: Theme.card.opacity(0.6)))

            // ── 面板 2：Usage Trends（rounded-xl 14 / bg-card/40 / p-6 24）──
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Usage Trends").font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.textMain)
                    Spacer()
                    Text(rangeLabel).font(.system(size: 14)).foregroundStyle(Theme.textDim)
                }
                .padding(.bottom, 24)   // title row mb-6 = 24

                ChartWebView(trend: snap.trend)
                    .frame(maxHeight: .infinity)
            }
            .padding(24)
            .frame(maxHeight: .infinity)
            .background(panelBox(radius: 14, fill: Theme.card.opacity(0.4)))
        }
        .padding(16)
        .background(Theme.bg)
    }

    private func panelBox(radius: CGFloat, fill: Color) -> some View {
        RoundedRectangle(cornerRadius: radius).fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.track.opacity(0.6), lineWidth: 1))
    }
}

// MARK: - 顶部左：Tokens Processed

struct SummaryHeader: View {
    let tokens: Int64
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.06)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "bolt.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("Tokens Processed").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Fmt.grouped(tokens))
                        .font(.system(size: 30, weight: .bold)).tracking(-0.75).monospacedDigit()
                        .foregroundStyle(Theme.textMain)
                    Text("≈ \(Fmt.tokens(tokens))")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textDim)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.muted.opacity(0.4)))
                }
            }
        }
    }
}

// MARK: - 顶部右：Requests / Cost 框

struct RequestsCostBox: View {
    let requests: Int
    let cost: Double
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("TOTAL REQUESTS").font(.system(size: 10, weight: .medium)).tracking(0.5)
                    .foregroundStyle(Theme.textDim)
                HStack(spacing: 6) {
                    Image(systemName: "waveform.path.ecg").font(.system(size: 14)).foregroundStyle(Theme.appleBlue)
                    Text(Fmt.grouped(Int64(requests))).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.textMain)
                }
            }
            Rectangle().fill(Theme.track.opacity(0.6)).frame(width: 1, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text("TOTAL COST").font(.system(size: 10, weight: .medium)).tracking(0.5)
                    .foregroundStyle(Theme.textDim)
                Text(Fmt.costPrecise(cost)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14).fill(Theme.bg.opacity(0.5))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.track.opacity(0.4), lineWidth: 1))
        )
    }
}

// MARK: - 卡片

struct MetricCard: View {
    let icon: String, tint: Color, title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textMain.opacity(0.72))
            }
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.textMain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBg)
    }
}

struct HitRateCard: View {
    let ratio: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Cache Hit Rate").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textDim)
                Spacer()
                Text(Fmt.percent(ratio)).font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(Theme.emerald)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.muted.opacity(0.6))
                    Capsule().fill(Theme.emerald)
                        .frame(width: geo.size.width * max(0, min(1, ratio)))
                }
            }.frame(height: 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(cardBg)
    }
}

private var cardBg: some View {
    RoundedRectangle(cornerRadius: 14).fill(Theme.bg.opacity(0.4))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.track.opacity(0.4), lineWidth: 1))
}
