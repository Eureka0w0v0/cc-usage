import Foundation

/// 占位 / Xcode 预览用的假数据（形状仿照真实趋势：白天爬升 + 午后尖峰）。
public extension UsageSnapshot {
    static var sample: UsageSnapshot {
        let now = Date()
        let dayStart = Calendar.current.startOfDay(for: now)
        let shape: [Double] = [0,0,0,0,0,0,0,0.02,0.03,0.05,0.35,0.55,0.72,1.0,0.66,0.28,0.42,0.9,0,0,0,0,0,0]
        var buckets: [TrendBucket] = []
        for (h, k) in shape.enumerated() {
            let ts = Int64(dayStart.timeIntervalSince1970) + Int64(h) * 3600
            let hit = Int64(k * 26_000_000)
            buckets.append(TrendBucket(
                startTs: ts,
                input: Int64(k * 40_000),
                output: Int64(k * 180_000),
                creation: Int64(k * 900_000),
                hit: hit,
                cost: k * 6.0
            ))
        }
        var today = UsageSummary()
        for b in buckets {
            today.input += b.input; today.output += b.output
            today.creation += b.creation; today.hit += b.hit
            today.cost += b.cost
        }
        today.requests = 661
        var cumulative = today
        cumulative.hit = 1_537_000_000; cumulative.cost = 1521.6; cumulative.requests = 10_947

        return UsageSnapshot(
            today: today,
            cumulative: cumulative,
            trend: buckets,
            generatedAt: now,
            lastEventAt: now.addingTimeInterval(-120)
        )
    }
}
