import Foundation

/// 数字格式化：与 cc-switch 面板一致的紧凑写法（107.35M / $99.82 / 95.5%）。
public enum Fmt {
    public static func tokens(_ n: Int64) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.2fM", d / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", d / 1_000)
        default:               return "\(n)"
        }
    }

    /// 走势图 $ 轴刻度，对齐主窗口 v4 的 formatMoneyTick（"$" + 千分位(String(num))）：整数不带小数点、
    /// 小数按需显示。最多 10 位小数只为吃掉 1.9500000000000002 这类浮点尾巴——刻度值来自 NiceScale 的十进制
    /// 步长，本来就没有尾巴；只有小于 1e-6 时与 JS 不同（JS 写成 5e-7，这里写成 0.0000005）。
    /// 早前是 `Int(rounded)`：刻度 1.25 / 2.5 被标成 $1 / $3，花费不足 $1 时整排 $0。
    public static func costAxis(_ v: Double) -> String {
        "$" + (costAxisFormatter.string(from: NSNumber(value: v)) ?? "\(v)")
    }
    private static let costAxisFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.groupingSize = 3
        f.maximumFractionDigits = 10
        return f
    }()

    /// 走势图悬停里的金额，对齐上游 money(v, 4)：固定四位小数 + 千分位（"$1,234.5679"）。
    public static func cost4(_ v: Double) -> String {
        let fixed = String(format: "%.4f", v)
        let parts = fixed.split(separator: ".", maxSplits: 1)
        let whole = String(parts[0])
        let sign = whole.hasPrefix("-") ? "-" : ""
        let digits = sign.isEmpty ? whole : String(whole.dropFirst())
        var grouped = ""
        for (i, ch) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        return "$" + sign + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }

    /// 千分位分隔，还原「153,980,903」。formatter 静态复用（走势图悬停时每帧都调）。
    public static func grouped(_ n: Int64) -> String {
        groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US")
        return f
    }()

    public static func cost(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    /// 菜单栏专用：0 显示 "$0"（而不是难看的 "$0.000"），其余与 cost 同口径。
    /// 菜单栏是常驻视野里最贵的一块地，格式只求一眼可读。
    public static func costCompact(_ v: Double) -> String {
        v == 0 ? "$0" : cost(v)
    }

    /// 菜单栏专用：M/B 只留 1 位小数（2.24M → 2.2M）。等宽数字下每省一位约 7pt，
    /// 三段码片就是 20pt+，而菜单栏根本不需要这一位的精度（精确值看面板）。
    public static func tokensCompact(_ n: Int64) -> String {
        let d = Double(n)
        switch abs(d) {
        case 1_000_000_000...: return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", d / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", d / 1_000)
        default:               return "\(n)"
        }
    }

    public static func percent(_ ratio: Double) -> String {
        let pct = max(0, min(100, ratio * 100))   // 对齐 cc-switch: clamp[0,100]，≥99.95 取整
        return String(format: pct >= 99.95 ? "%.0f%%" : "%.1f%%", pct)
    }

    /// "3m ago"（UI 统一英文，与面板/菜单栏其余文案一致）
    public static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
