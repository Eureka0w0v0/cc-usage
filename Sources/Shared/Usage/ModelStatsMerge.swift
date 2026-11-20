import Foundation

/// 模型统计的最后一步（纯函数，不碰库）：库内各有效计价模型的合计、叠加行分组、两组首字样本，按统计口径
/// （`statisticsModel`：同价推理档并到基础模型）归并成行，再按总成本降序、同成本按模型名升序排（对齐上游 v4.0.36
/// get_model_stats）。首字中位数按归并后的全部样本重新取，不是平均各档的中位数（上游 #8845）。
enum ModelStatsMerge {
    /// 库内一个有效计价模型的合计（主查询的一行）。`speed` 只用四个速度累计字段，首字中位数另算。
    struct DBTotals {
        var requests: Int64 = 0
        var tokens: Int64 = 0
        var cost: Double = 0
        var successes: Int64 = 0
        var speed = StatsPerformance()

        mutating func add(_ o: DBTotals) {
            requests += o.requests
            tokens += o.tokens
            cost += o.cost
            successes += o.successes
            speed.speedOutputTokens += o.speed.speedOutputTokens
            speed.speedGenerationMs += o.speed.speedGenerationMs
            speed.estSpeedOutputTokens += o.speed.estSpeedOutputTokens
            speed.estSpeedDurationMs += o.speed.estSpeedDurationMs
        }
    }

    /// 键都是原始的有效计价模型；`estimatedSamples` 里已经并进了叠加行估出的首字。
    static func rows(db: [String: DBTotals], overlay: [String: OverlayStats.Group],
                     exactSamples: [String: [Int64]], estimatedSamples: [String: [Int64]],
                     statisticsModel: (String) -> String) -> [ModelStatRow] {
        var keyOf: [String: String] = [:]
        func key(_ raw: String) -> String {
            if let k = keyOf[raw] { return k }
            let k = statisticsModel(raw)
            keyOf[raw] = k
            return k
        }
        var totals: [String: DBTotals] = [:]
        for (raw, t) in db { totals[key(raw), default: DBTotals()].add(t) }
        var groups: [String: OverlayStats.Group] = [:]
        for (raw, g) in overlay { groups[key(raw), default: OverlayStats.Group()].merge(g) }
        let exact = pooled(exactSamples, key)
        let estimated = pooled(estimatedSamples, key)

        let rows = Set(totals.keys).union(groups.keys).map { model -> ModelStatRow in
            let t = totals[model] ?? DBTotals()
            let g = groups[model] ?? OverlayStats.Group()
            var performance = t.speed
            performance.firstTokenMedianMs = exact[model].map(OverlayStats.median)
            performance.estFirstTokenMedianMs = estimated[model].map(OverlayStats.median)
            g.addEstimatedSpeed(to: &performance)
            let requests = t.requests + g.requests
            let cost = t.cost + g.cost
            return ModelStatRow(model: model, requestCount: requests, totalTokens: t.tokens + g.tokens,
                                totalCost: cost, avgCostPerRequest: requests > 0 ? cost / Double(requests) : 0,
                                successRate: UsageStore.successRate(t.successes + g.successes, of: requests),
                                performance: performance)
        }
        return rows.sorted { $0.totalCost != $1.totalCost ? $0.totalCost > $1.totalCost : $0.model < $1.model }
    }

    /// 样本按归并后的键合到一起，重新升序（中位数要求有序）。
    private static func pooled(_ samples: [String: [Int64]], _ key: (String) -> String) -> [String: [Int64]] {
        var out: [String: [Int64]] = [:]
        for (raw, values) in samples { out[key(raw), default: []] += values }
        for k in out.keys { out[k]?.sort() }
        return out
    }
}
