import Foundation

/// 走势图纵轴的取整上限，逐行移植主窗口所用 recharts 3.5.1 的
/// `getNiceTickValues([0, max], tickCount, allowDecimals: true)`
/// （cc-switch `node_modules/recharts/lib/util/scale/getNiceTickValues.js`）。
///
/// 为什么照抄而不是自己取整：菜单栏小窗口与主窗口（嵌入的 cc-switch 前端）都是双纵轴，
/// tokens 与花费各自取整定轴顶，两边规则一不同，两条线的相对高低就对不上。早前小窗口按
/// 1/2/2.5/3/4/5/6/8/10×10ⁿ 取整：峰值 10.5M 被顶到 20M、$4.9 只顶到 $5——紫线压到一半、
/// 红虚线顶满，与主窗口（12M / $8）恰好相反。
///
/// 全程用 Decimal：Recharts 靠 decimal.js-light 做十进制精确运算；换成 Double，
/// 0.3 / 0.05 这类整除边界会算出 5.999… 或 6.000…1，ceil 之后差一档。
enum NiceScale {
    /// 刻度数，对齐 Recharts YAxis 的默认 tickCount。
    static let tickCount = 5

    /// 数据区间 [0, dataMax] 的轴顶（即最后一个刻度）。
    static func axisMax(_ dataMax: Double) -> Double {
        let intervals = tickCount - 1
        // 全 0 数据走 getTickOfSingleValue(0)：刻度 0…tickCount-1
        guard dataMax > 0, dataMax.isFinite else { return Double(intervals) }
        // JS 的 new Decimal(number) 走最短往返字符串；Swift 的 String(Double) 同为最短往返
        let top = Decimal(string: String(dataMax)) ?? Decimal(dataMax)
        // calculateStep 在 min = 0 时 belowCount = 0；又因 step ≥ top / intervals，
        // ceil(top / step) ≤ intervals，修正因子的递归分支不会触发——轴顶恒为 step × intervals
        let step = formatStep(top / Decimal(intervals))
        return NSDecimalNumber(decimal: step * Decimal(intervals)).doubleValue
    }

    /// getFormatStep(roughStep, allowDecimals: true, correctionFactor: 0)
    private static func formatStep(_ rough: Decimal) -> Decimal {
        let digits = digitCount(rough)
        let unit = pow10(digits)
        let ratioScale = digits != 1 ? Decimal(5) / 100 : Decimal(1) / 10
        return ceil(rough / unit / ratioScale) * ratioScale * unit
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
}
