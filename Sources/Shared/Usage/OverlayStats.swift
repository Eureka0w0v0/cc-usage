import Foundation

/// 统计表的纯聚合：叠加行按行身份汇总、估出的首字并进样本、取中位数。不碰库，查询在 UsageStore+Stats。
enum OverlayStats {
    /// 叠加行按统计表的行身份汇总。成功只认 2xx（OMP 的中断 / 报错请求是 499 / 500）；计时是叠加层现场估的（或 OMP 自己记的），
    /// 非路由来源一律按估算口径：耗时之和进平均耗时；够门槛的（输出 ≥ 200、耗时 ≥ 1s，同 speedEstimateEligibleL）
    /// 进估算速度；推出了首字的进估算首字中位数（同 estFirstTokenEligibleL）。没有计时的行（耗时 0）只算请求数、
    /// Tokens、成本，平均耗时里按 0 计——与库里没有计时的行同一口径。
    struct Group {
        /// 供应商分组用的身份与展示名，取这组第一条叠加行的。
        var providerId = ""
        var appType = ""
        var providerName = ""
        var requests: Int64 = 0
        var successes: Int64 = 0
        var tokens: Int64 = 0
        var cost: Double = 0
        var latencySum: Int64 = 0
        var estOutputTokens: Int64 = 0
        var estDurationMs: Int64 = 0
        var firstTokens: [Int64] = []

        mutating func add(_ r: OverlayRow) {
            requests += 1
            if r.isSuccess { successes += 1 }
            tokens += r.realTotalTokens
            cost += r.totalCost
            latencySum += r.latencyMs
            if r.output >= UsageStore.speedEstimateMinOutputTokens,
               r.latencyMs >= UsageStore.speedEstimateMinDurationMs {
                estOutputTokens += r.output
                estDurationMs += r.latencyMs
            }
            if let ms = r.firstTokenMs { firstTokens.append(max(0, ms)) }
        }

        func addEstimatedSpeed(to performance: inout StatsPerformance) {
            performance.estSpeedOutputTokens += estOutputTokens
            performance.estSpeedDurationMs += estDurationMs
        }
    }

    static func group(_ rows: [OverlayRow], by key: (OverlayRow) -> String) -> [String: Group] {
        var groups: [String: Group] = [:]
        for r in rows {
            let k = key(r)
            var g = groups[k] ?? Group(providerId: r.providerId, appType: r.appType, providerName: r.providerName)
            g.add(r)
            groups[k] = g
        }
        return groups
    }

    /// 叠加行估出的首字并进估算首字的样本，各组重新排好序，之后统一取中位数。
    static func mergeFirstTokens(of groups: [String: Group], into samples: inout [String: [Int64]]) {
        for (key, g) in groups where !g.firstTokens.isEmpty {
            var merged = samples[key] ?? []
            merged.append(contentsOf: g.firstTokens)
            merged.sort()
            samples[key] = merged
        }
    }

    /// 已升序的一组数的中位数：奇数个取中间，偶数个取中间两个的整除平均（同上游）。
    static func median(_ sorted: [Int64]) -> Int64 {
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
