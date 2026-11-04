import XCTest

// 菜单栏趋势图 = 主窗口 v4 趋势图（cc-switch `UsageTrendChart.tsx`，v4.0.22）的迷你版：单指标、单纵轴、
// `<YAxis tickCount={3}>`。期望值取自主窗口实际打包的 recharts 3.5.1 / Intl（cc-switch 目录下用 node 跑出）。
final class TrendAxisTests: XCTestCase {

    // MARK: - 指标与样式（跟随主窗口的两项选择）

    // 主窗口指标条记在 `embed.usage.trendMetric`，值就是上游 USAGE_METRICS 里的字符串；
    // 没选过或认不出 → tokens（上游 useRememberedChoice 的默认值）。负责杀的变异体：默认值改成别的指标 / 大小写放宽。
    func testMetricResolveDefaultsToTokens() {
        XCTAssertEqual(TrendMetric.resolve(nil), .tokens)
        XCTAssertEqual(TrendMetric.resolve(""), .tokens)
        XCTAssertEqual(TrendMetric.resolve("HitRate"), .tokens)
        XCTAssertEqual(TrendMetric.resolve("cost"), .cost)
        XCTAssertEqual(TrendMetric.resolve("requests"), .requests)
        XCTAssertEqual(TrendMetric.resolve("tokens"), .tokens)
        XCTAssertEqual(TrendMetric.resolve("hitRate"), .hitRate)
    }

    // 文案同上游 en.json：usage.trend.tokens / cost / requestsLegend、usage.cacheHitRate。
    func testMetricTitlesFollowUpstreamEnglish() {
        XCTAssertEqual(TrendMetric.tokens.title, "Tokens")
        XCTAssertEqual(TrendMetric.cost.title, "Cost")
        XCTAssertEqual(TrendMetric.requests.title, "Requests")
        XCTAssertEqual(TrendMetric.hitRate.title, "Cache Hit Rate")
    }

    // 同上游 buildUsageTrendChartData / hitRateOf：tokens 是四类相加；命中率 = 缓存读 ÷（输入 + 缓存写 + 缓存读），
    // 分母为 0 记 nil（图上留空，不画成 0%）。负责杀的变异体：tokens 漏一类 / 命中率分母带上输出 / 分母为 0 给 0。
    func testMetricValuesFollowUpstreamChartData() {
        let b = TrendBucket(startTs: 0, requestCount: 3, input: 100, output: 50, creation: 30, hit: 820, cost: 0.5)
        XCTAssertEqual(TrendMetric.tokens.value(of: b), 1000)
        XCTAssertEqual(TrendMetric.cost.value(of: b), 0.5)
        XCTAssertEqual(TrendMetric.requests.value(of: b), 3)
        XCTAssertEqual(TrendMetric.hitRate.value(of: b)!, 820.0 / 950.0, accuracy: 1e-15)

        let empty = TrendBucket(startTs: 0)
        XCTAssertEqual(TrendMetric.tokens.value(of: empty), 0)
        XCTAssertEqual(TrendMetric.cost.value(of: empty), 0)
        XCTAssertNil(TrendMetric.hitRate.value(of: empty))
        XCTAssertNil(TrendMetric.hitRate.value(of: TrendBucket(startTs: 0, output: 10)))
    }

    // 主窗口「趋势图样式」存在 `embed.usageDisplay` 的 trendChartType；没设置或认不出 → 柱形（上游 resolveTrendChartType）。
    // 负责杀的变异体：默认值改成面积 / 不认 JSON 里的值。
    func testChartStyleResolveFollowsUpstreamDefault() {
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: nil), .bar)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: ""), .bar)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: "not json"), .bar)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: #"{"trendChartType":"area"}"#), .area)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: #"{"trendChartType":"bar"}"#), .bar)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: #"{"trendChartType":"line"}"#), .bar)
        XCTAssertEqual(TrendChartStyle.resolve(usageDisplayJSON: #"{"requestLogColumns":{"model":true}}"#), .bar)
    }

    // MARK: - 纵轴

    // tokens / 花费 / 请求数：定义域 [0, 'auto']，刻度 = getNiceTickValues([0, 最大值], 3)，轴顶跟着刻度。
    // 负责杀的变异体：轴顶不取整 / 仍按 5 档 / 把 nil 当成 0 以外的值。
    func testCountMetricsUseNiceTicksFromZero() {
        let tokens = TrendYAxis.make(metric: .tokens, values: [0, 123_456, 98_765])
        XCTAssertEqual(tokens.ticks, [0, 65_000, 130_000])
        XCTAssertEqual(tokens.domain, 0...130_000)

        let cost = TrendYAxis.make(metric: .cost, values: [0.2, 0.684, 0])
        XCTAssertEqual(cost.ticks, [0, 0.35, 0.7])
        XCTAssertEqual(cost.domain, 0...0.7)
    }

    // 全 0 / 没有数据：getTickOfSingleValue(0) → 0、1、2，曲线贴底（与主窗口一致）。
    func testAllZeroOrEmptyUsesSingleValueTicks() {
        for values in [[0, 0], [], [nil]] as [[Double?]] {
            let axis = TrendYAxis.make(metric: .requests, values: values)
            XCTAssertEqual(axis.ticks, [0, 1, 2], "\(values)")
            XCTAssertEqual(axis.domain, 0...2, "\(values)")
        }
    }

    // 逐条照搬上游 hitRateAxisFloor 的单测（tests/components/UsageTrendChart.test.ts）。
    // 负责杀的变异体：余量下限 2 个百分点漏掉 / 容差 1e-9 漏掉（0.97 会多掉一档）/ 低于 50% 不归 0。
    func testHitRateFloorMatchesUpstreamTests() {
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.99, 0.96, nil, 0.985]), 0.9)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.985, 0.99]), 0.95)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.97]), 0.95)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.8, 0.95]), 0.7)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.37, 0.99]), 0)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.7]), 0.55)
        XCTAssertEqual(TrendYAxis.hitRateFloor([nil, nil]), 0)
        XCTAssertEqual(TrendYAxis.hitRateFloor([]), 0)
        // 余量「至少 2 个百分点」：0.968 若只减半段（0.016）是 0.952 → 95%，按 2 个百分点是 0.948 → 90%。
        // 上游自带的用例分不出这一条（变异测试时存活，补这两组；期望值由上游源码里的函数原样算出）。
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.968]), 0.9)
        XCTAssertEqual(TrendYAxis.hitRateFloor([0.969]), 0.9)
    }

    // 命中率：上游给了定义域 [下限, 1]，刻度走 getTickValuesFixedDomain，不会冲出 100%。
    // 负责杀的变异体：命中率也走 niceTicks / 定义域上界不是 1。
    func testHitRateAxisUsesFixedDomain() {
        let high = TrendYAxis.make(metric: .hitRate, values: [0.97, 0.99, nil])
        XCTAssertEqual(high.ticks, [0.95, 0.975, 1])
        XCTAssertEqual(high.domain, 0.95...1)

        let mid = TrendYAxis.make(metric: .hitRate, values: [0.7])
        XCTAssertEqual(mid.ticks, [0.55, 0.8, 1])
        XCTAssertEqual(mid.domain, 0.55...1)

        let none = TrendYAxis.make(metric: .hitRate, values: [nil, nil])
        XCTAssertEqual(none.ticks, [0, 0.5, 1])
        XCTAssertEqual(none.domain, 0...1)
    }

    // MARK: - 刻度与悬停文案

    // tokens / 请求数刻度：Intl.NumberFormat("en-US", compact short, 最多 1 位小数)，四舍五入是 halfExpand
    // （1250 → 1.3K、0.25 → 0.3），进位到 1000 换下一档（999950 → 1M）。
    // 负责杀的变异体：银行家舍入 / 不换档 / 保留 ".0"。
    func testCountTicksUseIntlCompact() {
        let golden: [(Double, String)] = [
            (0, "0"), (1, "1"), (2, "2"), (2.5, "2.5"), (150, "150"), (999, "999"), (1000, "1K"),
            (1250, "1.3K"), (1500, "1.5K"), (12_500, "12.5K"), (60_000, "60K"), (61_550, "61.6K"),
            (125_000, "125K"), (999_949, "999.9K"), (999_950, "1M"), (1_000_000, "1M"), (1_250_000, "1.3M"),
            (1_050_000, "1.1M"), (2_500_000, "2.5M"), (12_000_000, "12M"), (1_000_000_000, "1B"),
            (1_250_000_000, "1.3B"), (1e12, "1T"), (0.5, "0.5"), (0.25, "0.3"), (0.05, "0.1"),
        ]
        for (v, want) in golden {
            XCTAssertEqual(TrendFormat.tick(v, metric: .tokens), want, "tokens \(v)")
            XCTAssertEqual(TrendFormat.tick(v, metric: .requests), want, "requests \(v)")
        }
    }

    // 金额刻度：上游 formatMoneyTick = "$" + 千分位(String(num))。刻度值都来自 NiceScale 的十进制步长，
    // 不会带浮点尾巴，所以这里不覆盖 0.30000000000000004 / 1e-7 这类 JS 写法特殊的值。
    // 负责杀的变异体：不加千分位 / 截断小数 / 固定小数位。
    func testCostTicksUseUpstreamMoneyTick() {
        let golden: [(Double, String)] = [
            (0, "$0"), (0.4, "$0.4"), (0.8, "$0.8"), (1.2, "$1.2"), (0.25, "$0.25"), (0.5, "$0.5"),
            (1, "$1"), (2, "$2"), (4, "$4"), (1500, "$1,500"), (3000, "$3,000"), (0.0002, "$0.0002"),
            (0.00002, "$0.00002"), (12_345.5, "$12,345.5"),
        ]
        for (v, want) in golden {
            XCTAssertEqual(TrendFormat.tick(v, metric: .cost), want, "cost \(v)")
        }
    }

    // 命中率刻度：上游 `${+((v * 100).toFixed(1))}%`（一位小数、去掉末尾的 .0）。
    func testHitRateTicksDropTrailingZero() {
        let golden: [(Double, String)] = [
            (0, "0%"), (0.5, "50%"), (0.55, "55%"), (0.8, "80%"), (0.925, "92.5%"), (0.95, "95%"),
            (0.975, "97.5%"), (1, "100%"), (0.935, "93.5%"), (0.9333333, "93.3%"),
        ]
        for (v, want) in golden {
            XCTAssertEqual(TrendFormat.tick(v, metric: .hitRate), want, "hitRate \(v)")
        }
    }

    // 悬停数值同上游 formatMetric：tokens / 请求数 = fmtInt（千分位、截断小数）；花费 = money(v, 4)；
    // 命中率 = formatHitRatePercent，nil 显示 —。负责杀的变异体：花费仍用 6 位小数 / 金额不加千分位。
    func testTooltipValuesFollowUpstreamFormatMetric() {
        XCTAssertEqual(TrendFormat.value(123_456, metric: .tokens), "123,456")
        XCTAssertEqual(TrendFormat.value(3, metric: .requests), "3")
        XCTAssertEqual(TrendFormat.value(0, metric: .cost), "$0.0000")
        XCTAssertEqual(TrendFormat.value(0.684, metric: .cost), "$0.6840")
        XCTAssertEqual(TrendFormat.value(1234.56789, metric: .cost), "$1,234.5679")
        XCTAssertEqual(TrendFormat.value(0.00005, metric: .cost), "$0.0001")
        XCTAssertEqual(TrendFormat.value(12.5, metric: .cost), "$12.5000")
        XCTAssertEqual(TrendFormat.value(0.933, metric: .hitRate), "93.3%")
        XCTAssertEqual(TrendFormat.value(0.9996, metric: .hitRate), "100%")
        XCTAssertEqual(TrendFormat.value(nil, metric: .hitRate), "—")
    }

    // 横轴钟点：上游 toLocaleTimeString({hour: "2-digit", minute: "2-digit", hourCycle: "h23"})，按本地时区。
    func testHourLabelUsesLocalTwentyFourHourClock() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let twoPM: Int64 = 1_793_595_600   // 2026-11-02 14:00 JST
        XCTAssertEqual(TrendFormat.hourLabel(twoPM, timeZone: tokyo), "14:00")
        XCTAssertEqual(TrendFormat.hourLabel(twoPM - 14 * 3600, timeZone: tokyo), "00:00")
        XCTAssertEqual(TrendFormat.hourLabel(twoPM, timeZone: TimeZone(identifier: "UTC")!), "05:00")
    }
}
