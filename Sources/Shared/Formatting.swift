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

    /// 千分位分隔，还原「153,980,903」。formatter 静态复用（tooltip 每悬停帧调 4 次）。
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

/// 宽容 ISO8601 解析：来源时间串可能带 3/6 位小数秒（ISO8601DateFormatter 的
/// .withFractionalSeconds 只认 3 位），先剥小数秒按秒级解析，失败再拿原串让
/// 小数位 formatter 兜底。SessionOverlay(JSONL timestamp) 与 QuotaService(resets_at)
/// 共用这一份，formatter 静态复用（ISO8601DateFormatter 线程安全）。
public enum ISO8601Lenient {
    private static let seconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func date(_ s: String) -> Date? {
        if let d = seconds.date(from: stripFractionalSeconds(s)) { return d }
        return fractional.date(from: s)
    }

    /// "…56.123456+00:00" → "…56+00:00"（手写扫描，免去每次调用编译正则）
    private static func stripFractionalSeconds(_ s: String) -> String {
        guard let dot = s.firstIndex(of: ".") else { return s }
        var end = s.index(after: dot)
        while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
        guard end > s.index(after: dot) else { return s }
        return String(s[..<dot]) + String(s[end...])
    }
}
