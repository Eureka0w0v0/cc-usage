import Foundation

/// 走势图纵轴刻度，逐行移植主窗口所用 recharts 3.5.1 的两套算法
/// （cc-switch `node_modules/recharts/lib/util/scale/getNiceTickValues.js`）：
/// - `niceTicks`：getNiceTickValues([0, max], tickCount, allowDecimals: true)。YAxis 默认定义域 [0, 'auto']
///   时 Recharts 用它取刻度，并把轴顶扩到最后一个刻度；
/// - `fixedDomainTicks`：getTickValuesFixedDomain([min, max], tickCount, true)。定义域写死成数字时
///   （主窗口的命中率是 [下限, 1]）用它，刻度不出界、最后一个就是上界。
///
/// 为什么照抄而不是自己取整：菜单栏小窗口要和主窗口（嵌入的 cc-switch 前端）同一套轴顶，柱子和曲线的
/// 高低才对得上。早前小窗口按 1/2/2.5/3/4/5/6/8/10×10ⁿ 取整，峰值 10.5M 被顶到 20M，主窗口却是 12M。
///
/// 全程用 Decimal：Recharts 靠 decimal.js-light 做十进制精确运算；换成 Double，0.3 / 0.05 这类整除
/// 边界会算出 5.999… 或 6.000…1，ceil 之后差一档。换回 Double 时经十进制字符串（`toDouble`），与
/// decimal.js 的 toNumber 一样取最近的 Double——NSDecimalNumber.doubleValue 会差一个 ulp，金额刻度就成了
/// 0.35000000000000003。
enum NiceScale {
    /// 数据区间 [0, dataMax] 的刻度（第一个是 0，最后一个是轴顶）。
    static func niceTicks(dataMax: Double, tickCount: Int) -> [Double] {
        let intervals = tickCount - 1
        // 全 0 数据走 getTickOfSingleValue(0)：刻度 0…tickCount-1。NaN / ∞ / 负数不会出现，同样处理，免得死循环。
        guard dataMax > 0, dataMax.isFinite, intervals > 0 else { return (0..<max(tickCount, 1)).map(Double.init) }
        // calculateStep 在 min = 0 时 middle = 0、belowCount = 0；又因 step ≥ top / intervals，
        // ceil(top / step) ≤ intervals，修正因子的递归分支不会触发——刻度恒为 0、step、…、step × intervals
        let step = formatStep(decimal(dataMax) / Decimal(intervals))
        return (0...intervals).map { toDouble(step * Decimal($0)) }
    }

    /// 定义域 [min, max] 的刻度：从 min 起按步长往上走、不到 max 为止，最后补上 max 本身（所以末段可能不等长）。
    static func fixedDomainTicks(min: Double, max: Double, tickCount: Int) -> [Double] {
        let (low, high) = min <= max ? (min, max) : (max, min)
        guard low.isFinite, high.isFinite else { return [min, max] }
        if low == high { return [low] }
        let count = Swift.max(tickCount, 2)
        let start = decimal(low)
        let step = formatStep((decimal(high) - start) / Decimal(count - 1))
        var values = rangeStep(start, end: decimal(high), step: step).map(toDouble)
        values.append(high)
        return min > max ? values.reversed() : values
    }

    /// getFormatStep(roughStep, allowDecimals: true, correctionFactor: 0)
    private static func formatStep(_ rough: Decimal) -> Decimal {
        guard rough > 0 else { return 0 }
        let digits = digitCount(rough)
        let unit = pow10(digits)
        let ratioScale = digits != 1 ? Decimal(5) / 100 : Decimal(1) / 10
        return ceil(rough / unit / ratioScale) * ratioScale * unit
    }

    /// arithmetic.rangeStep：start、start + step、… 中小于 end 的那些（上游同样最多走 100000 步防死循环）。
    private static func rangeStep(_ start: Decimal, end: Decimal, step: Decimal) -> [Decimal] {
        var out: [Decimal] = []
        var value = start
        while value < end && out.count < 100_000 {
            out.append(value)
            value += step
        }
        return out
    }

    /// getDigitCount：floor(log10(v)) + 1。Double 先估，再按十进制精确比较修正，
    /// 免得 log10 在 10 的整数次方附近差一位。
    private static func digitCount(_ v: Decimal) -> Int {
        var n = Int(Foundation.floor(log10(NSDecimalNumber(decimal: v).doubleValue))) + 1
        while pow10(n - 1) > v { n -= 1 }
        while pow10(n) <= v { n += 1 }
        return n
    }

    private static func pow10(_ n: Int) -> Decimal {
        n >= 0 ? pow(Decimal(10), n) : 1 / pow(Decimal(10), -n)
    }

    /// 正数向上取整（对应 Math.ceil；入参恒为正，.up 即远离零）。
    private static func ceil(_ d: Decimal) -> Decimal {
        var input = d, out = Decimal()
        NSDecimalRound(&out, &input, 0, .up)
        return out
    }

    /// JS 的 new Decimal(number) 走最短往返字符串；Swift 的 String(Double) 同为最短往返。
    private static func decimal(_ v: Double) -> Decimal {
        Decimal(string: String(v)) ?? Decimal(v)
    }

    /// decimal.js 的 toNumber = 按十进制字符串解析成最近的 Double。
    private static func toDouble(_ d: Decimal) -> Double {
        Double(d.description) ?? NSDecimalNumber(decimal: d).doubleValue
    }
}
