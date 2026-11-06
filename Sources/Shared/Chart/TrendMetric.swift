import Foundation

/// 趋势图画哪个指标——跟随主窗口（cc-switch v4 用量页）指标条的选择。
///
/// 主窗口把选择记在 UserDefaults `embed.usage.trendMetric`（上游 localStorage 键 `cc-switch.usage.trendMetric`
/// 的原生镜像，值就是上游 USAGE_METRICS 里的字符串）；没选过或认不出 → tokens，同上游 useRememberedChoice 的默认值。
enum TrendMetric: String, CaseIterable, Sendable {
    case cost, requests, tokens, hitRate

    static func resolve(_ raw: String?) -> TrendMetric {
        raw.flatMap(TrendMetric.init(rawValue:)) ?? .tokens
    }

    /// 英文文案，同上游 en.json（usage.trend.tokens / cost / requestsLegend、usage.cacheHitRate）。
    var title: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost: return "Cost"
        case .requests: return "Requests"
        case .hitRate: return "Cache Hit Rate"
        }
    }

    /// 一个桶在这个指标上的值，同上游 buildUsageTrendChartData：tokens = 输入 + 输出 + 缓存写 + 缓存读；
    /// 命中率 = 缓存读 ÷（输入 + 缓存写 + 缓存读），分母为 0 时为 nil（图上留空，不画成 0%）。
    func value(of bucket: TrendBucket) -> Double? {
        switch self {
        case .tokens: return Double(bucket.tokens)
        case .cost: return bucket.cost
        case .requests: return Double(bucket.requestCount)
        case .hitRate:
            let cacheable = bucket.input + bucket.creation + bucket.hit
            return cacheable > 0 ? Double(bucket.hit) / Double(cacheable) : nil
        }
    }
}

/// 趋势图画成柱形还是面积——跟随主窗口「趋势图样式」下拉，存在 UserDefaults `embed.usageDisplay`
/// （JSON 字符串）的 `trendChartType`；没设置或认不出 → 柱形，同上游 resolveTrendChartType。
enum TrendChartStyle: String, Sendable {
    case bar, area

    static func resolve(usageDisplayJSON: String?) -> TrendChartStyle {
        let saved = EmbedSettings.usageDisplay(fromJSON: usageDisplayJSON)?["trendChartType"] as? String
        return saved.flatMap(TrendChartStyle.init(rawValue:)) ?? .bar
    }
}
