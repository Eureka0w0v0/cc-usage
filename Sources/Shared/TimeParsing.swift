import Foundation

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

    /// RFC3339 → epoch 秒。两个 overlay 冷启动逐行调用，是热路径（formatter 静态复用）。
    public static func epochSeconds(_ s: String) -> Int64? {
        date(s).map { Int64($0.timeIntervalSince1970) }
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

/// RFC3339 → epoch 毫秒，逐条对齐 chrono 0.4.44 的 `DateTime::parse_from_rfc3339` + `timestamp_millis`
/// （cc-switch 解析会话日志时间戳用的就是它）：
///   * `YYYY-MM-DD` + `T` / `t` / 空格 + `HH:MM:SS`，各位必须是数字，日期必须真实存在（2 月 30 日不行）；
///   * 秒可以是 60（闰秒）：按 59 秒再加 1 秒算；
///   * 小数秒可选，有点号就至少一位数字，超过 9 位的忽略，最后截到毫秒；
///   * 时区是 `Z` / `z`，或 `±HH:MM`（负号也可以是 U+2212），偏移必须不足一天；后面不能再有别的字符。
/// 不合规的一律 nil，与上游一样当「没有这个时间戳」处理。
///
/// 会话计时要逐块解析时间戳，ISO8601DateFormatter 一次 44µs（本机实测），所以手写扫描。
enum RFC3339 {
    static func epochMillis(_ s: String) -> Int64? {
        var s = s
        return s.withUTF8 { parse($0) }
    }

    private static func parse(_ b: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard b.count >= 19 else { return nil }
        func digit(_ i: Int) -> Int64? {
            guard i < b.count, (0x30...0x39).contains(b[i]) else { return nil }
            return Int64(b[i] - 0x30)
        }
        func twoDigits(_ i: Int) -> Int64? {
            guard let high = digit(i), let low = digit(i + 1) else { return nil }
            return high * 10 + low
        }
        func byte(_ i: Int, is c: Unicode.Scalar) -> Bool { i < b.count && b[i] == UInt8(ascii: c) }

        guard let century = twoDigits(0), let yy = twoDigits(2), byte(4, is: "-"),
              let month = twoDigits(5), byte(7, is: "-"), let day = twoDigits(8),
              byte(10, is: "T") || byte(10, is: "t") || byte(10, is: " "),
              let hour = twoDigits(11), byte(13, is: ":"), let minute = twoDigits(14), byte(16, is: ":"),
              var second = twoDigits(17) else { return nil }
        let year = century * 100 + yy
        guard (1...12).contains(month), (1...daysInMonth(year, month)).contains(day) else { return nil }

        // 闰秒：chrono 记成 59 秒加 10 亿纳秒
        var nanos: Int64 = 0
        if second == 60 { second = 59; nanos = 1_000_000_000 }

        var i = 19
        if byte(i, is: ".") {
            i += 1
            var digits = 0
            var fraction: Int64 = 0
            while let d = digit(i) {
                if digits < 9 { fraction = fraction * 10 + d; digits += 1 }
                i += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<9 { fraction *= 10 }
            nanos += fraction
        }
        guard hour < 24, minute < 60, second < 60, nanos < 2_000_000_000,
              nanos < 1_000_000_000 || second == 59 else { return nil }

        guard let tz = timezoneOffset(b, from: i), tz.end == b.count,
              tz.offset > -86_400, tz.offset < 86_400 else { return nil }

        let seconds = daysFromCivil(year, month, day) * 86_400 + hour * 3600 + minute * 60 + second - tz.offset
        return seconds * 1000 + nanos / 1_000_000
    }

    /// `Z` / `z` / `±HH:MM`：偏移秒数，以及偏移之后的下标。小时 00–99、分钟 00–59（chrono 的 timezone_offset），
    /// 不足一天的检查由调用方做。
    private static func timezoneOffset(_ b: UnsafeBufferPointer<UInt8>,
                                       from start: Int) -> (offset: Int64, end: Int)? {
        guard start < b.count else { return nil }
        if b[start] == UInt8(ascii: "Z") || b[start] == UInt8(ascii: "z") { return (0, start + 1) }
        var i = start
        let negative: Bool
        switch b[i] {
        case UInt8(ascii: "+"): negative = false; i += 1
        case UInt8(ascii: "-"): negative = true; i += 1
        case 0xE2 where i + 2 < b.count && b[i + 1] == 0x88 && b[i + 2] == 0x92:   // U+2212 MINUS SIGN
            negative = true; i += 3
        default: return nil
        }
        func digit(_ j: Int) -> Int64? {
            guard j < b.count, (0x30...0x39).contains(b[j]) else { return nil }
            return Int64(b[j] - 0x30)
        }
        guard let h1 = digit(i), let h2 = digit(i + 1), i + 2 < b.count, b[i + 2] == UInt8(ascii: ":"),
              let m1 = digit(i + 3), m1 <= 5, let m2 = digit(i + 4) else { return nil }
        let seconds = (h1 * 10 + h2) * 3600 + (m1 * 10 + m2) * 60
        return (negative ? -seconds : seconds, i + 5)
    }

    private static func daysInMonth(_ year: Int64, _ month: Int64) -> Int64 {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// 公历日期 → 距 1970-01-01 的天数（Howard Hinnant 的 days_from_civil，对负年份同样成立）。
    private static func daysFromCivil(_ y: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let year = m <= 2 ? y - 1 : y
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let monthFromMarch = (m + 9) % 12
        let dayOfYear = (153 * monthFromMarch + 2) / 5 + d - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}
