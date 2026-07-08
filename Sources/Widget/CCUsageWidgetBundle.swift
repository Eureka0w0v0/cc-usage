import WidgetKit
import SwiftUI

// ── WidgetKit 扩展入口 ──
@main
struct CCUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CCUsageWidget()
    }
}

struct CCUsageWidget: Widget {
    let kind = "CCUsageWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(Theme.bg.gradient, for: .widget)
        }
        .configurationDisplayName("CC Usage")
        .description("Today's tokens, cost, cache hit rate and trend from cc-switch.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// ── 时间线 ──
struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: UsageSnapshot?
    let errorText: String?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: .sample, errorText: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        if context.isPreview {
            completion(UsageEntry(date: Date(), snapshot: .sample, errorText: nil))
        } else {
            completion(load())
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = load()
        // 系统有刷新预算，15 分钟一次是稳妥节奏
        let next = Date().addingTimeInterval(15 * 60)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }

    private func load() -> UsageEntry {
        do {
            let snap = try UsageStore().snapshot()
            return UsageEntry(date: Date(), snapshot: snap, errorText: nil)
        } catch {
            return UsageEntry(date: Date(), snapshot: nil, errorText: "\(error)")
        }
    }
}
