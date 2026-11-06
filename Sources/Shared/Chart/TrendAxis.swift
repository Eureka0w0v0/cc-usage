import Foundation

/// 趋势图纵轴，同主窗口 v4 趋势图（cc-switch `UsageTrendChart.tsx`）的 `<YAxis tickCount={3}>`：
/// - tokens / 花费 / 请求数：定义域 [0, 'auto']，刻度 = getNiceTickValues([0, 最大值], 3)，轴顶扩到最后一个刻度
///   （recharts combineAxisDomainWithNiceTicks）；
/// - 命中率：定义域 [hitRateAxisFloor, 1]，刻度 = getTickValuesFixedDomain，不会冲出 100%。
struct TrendYAxis: Equatable, Sendable {
    static let tickCount = 3

    let ticks: [Double]
    let domain: ClosedRange<Double>

    static func make(metric: TrendMetric, values: [Double?]) -> TrendYAxis {
        // 上游取值前都过一遍 parseFiniteNumber；数据里不会有 NaN / ∞，过滤掉免得构造出非法区间
        let finite = values.compactMap { $0 }.filter(\.isFinite)
        if metric == .hitRate {
            let floor = hitRateFloor(finite)
            let ticks = NiceScale.fixedDomainTicks(min: floor, max: 1, tickCount: tickCount)
            return TrendYAxis(ticks: ticks, domain: min(floor, ticks.first ?? floor)...max(1, ticks.last ?? 1))
        }
        let dataMax = max(finite.max() ?? 0, 0)
        let ticks = NiceScale.niceTicks(dataMax: dataMax, tickCount: tickCount)
        return TrendYAxis(ticks: ticks, domain: 0...max(dataMax, ticks.last ?? dataMax))
    }

    /// 上游 hitRateAxisFloor：命中率通常都在 90% 以上，从 0 画起柱子几乎一样高。取最低值，往下再留半个
    /// 「最低值到 100%」的距离（至少 2 个百分点），向下取整到 5% 的整数档；没有数据或算出来低于 50% 时从 0 画。
    static func hitRateFloor(_ rates: [Double?]) -> Double {
        guard let lowest = rates.compactMap({ $0 }).min() else { return 0 }
        let padded = lowest - max((1 - lowest) / 2, 0.02)
        // 加一点容差：0.95 * 20 在浮点下是 18.999…，直接取整会多掉一档
        let floor = Foundation.floor(padded * 20 + 1e-9) / 20
        return floor < 0.5 ? 0 : floor
    }
}

/// 趋势图上的文字，逐条对齐上游 UsageTrendChart（embed 固定英文，即 en-US）。
enum TrendFormat {
    /// 纵轴刻度（上游 formatYTick）：花费 = formatMoneyTick；命中率 = 一位小数的百分比、去掉末尾 .0；
    /// tokens / 请求数 = Intl compact。
    static func tick(_ value: Double, metric: TrendMetric) -> String {
        switch metric {
        case .cost: return Fmt.costAxis(value)
        case .hitRate: return hitRateTick(value)
        case .tokens, .requests: return compact(value)
        }
    }

    /// 悬停提示里的数值（上游 formatMetric）：tokens / 请求数 = fmtInt（千分位、截掉小数）；花费 = money(v, 4)；
    /// 命中率 = formatHitRatePercent。没有值时花费 / 计数写 --，命中率写 —（上游的两种兜底文字）。
    static func value(_ value: Double?, metric: TrendMetric) -> String {
        guard let value, value.isFinite else { return metric == .hitRate ? "—" : "--" }
        switch metric {
        case .hitRate: return Fmt.percent(value)
        case .cost: return Fmt.cost4(value)
        case .tokens, .requests: return Fmt.grouped(Int64(value.rounded(.towardZero)))
        }
    }

    /// 横轴钟点，同上游 toLocaleTimeString({hour: "2-digit", minute: "2-digit", hourCycle: "h23"})。
    static func hourLabel(_ startTs: Int64, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: TimeInterval(startTs)))
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// Intl.NumberFormat("en-US", {notation: "compact", compactDisplay: "short", maximumFractionDigits: 1})。
    /// 照 ICU 的 chooseMultiplierAndApply：按原值的数量级选 K / M / B / T，四舍五入（halfExpand）到一位小数；
    /// 进位到下一个数量级且换了档的（999.95K → 1000.0K）按新档位重算（→ 1M）。全程十进制，免得 1.25 这类
    /// 「正好一半」被二进制误差带偏。
    static func compact(_ value: Double) -> String {
        guard value.isFinite else { return "--" }
        let exact = Decimal(string: String(value)) ?? Decimal(value)
        guard exact != 0 else { return "0" }
        let magnitude = decimalMagnitude(abs(exact))
        var exponent = compactExponent(magnitude)
        var rounded = roundOneDecimal(exact / pow10(exponent))
        if rounded != 0, decimalMagnitude(abs(rounded)) > magnitude - exponent {
            let next = compactExponent(magnitude + 1)
            if next != exponent {
                exponent = next
                rounded = roundOneDecimal(exact / pow10(exponent))
            }
        }
        return rounded.description + compactSuffixes[exponent / 3]
    }

    private static let compactSuffixes = ["", "K", "M", "B", "T"]

    /// en 的 compact-short：10³ 起 K、10⁶ 起 M、10⁹ 起 B、10¹² 起 T，再大仍用 T。
    private static func compactExponent(_ magnitude: Int) -> Int {
        min(max(magnitude / 3 * 3, 0), 12)
    }

    /// 上游 `${+((v * 100).toFixed(1))}%`：0.925 → 92.5%、0.95 → 95%。
    private static func hitRateTick(_ value: Double) -> String {
        var text = String(format: "%.1f", value * 100)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + "%"
    }

    /// floor(log10(v))，v > 0。Double 先估，再按十进制精确比较修正。
    private static func decimalMagnitude(_ v: Decimal) -> Int {
        var m = Int(Foundation.floor(log10(NSDecimalNumber(decimal: v).doubleValue)))
        while pow10(m) > v { m -= 1 }
        while pow10(m + 1) <= v { m += 1 }
        return m
    }

    private static func pow10(_ n: Int) -> Decimal {
        n >= 0 ? pow(Decimal(10), n) : 1 / pow(Decimal(10), -n)
    }

    /// 四舍五入到一位小数，正好一半时远离零（Intl 默认的 halfExpand）。
    private static func roundOneDecimal(_ d: Decimal) -> Decimal {
        var input = d, out = Decimal()
        NSDecimalRound(&out, &input, 1, .plain)
        return out
    }
}
