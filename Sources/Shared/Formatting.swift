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

    /// Y 轴刻度用（对齐 recharts (value/1000).toFixed(0)+"k"，四舍五入，0→"0k"）
    public static func tokensAxis(_ n: Int64) -> String {
        String(format: "%.0fk", Double(n) / 1000)
    }

    /// 千分位分隔，还原「153,980,903」
    public static func grouped(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func cost(_ v: Double) -> String {
        if v >= 100 { return String(format: "$%.0f", v) }
        if v >= 1 { return String(format: "$%.2f", v) }
        return String(format: "$%.3f", v)
    }

    public static func costPrecise(_ v: Double) -> String {
        String(format: "$%.4f", v)
    }

    // tooltip 用，对齐 cc-switch fmtUsd(value, 6)
    public static func cost6(_ v: Double) -> String {
        String(format: "$%.6f", v)
    }

    public static func percent(_ ratio: Double) -> String {
        let pct = max(0, min(100, ratio * 100))   // 对齐 cc-switch: clamp[0,100]，≥99.95 取整
        return String(format: pct >= 99.95 ? "%.0f%%" : "%.1f%%", pct)
    }

    public static func requests(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK", Double(n) / 1000) : "\(n)"
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
