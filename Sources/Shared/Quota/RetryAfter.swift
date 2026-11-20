import Foundation

/// HTTP `Retry-After` 响应头 → 还要等几秒（RFC 9110 §10.2.3：非负整数秒，或一个 HTTP 日期）。
enum RetryAfter {
    /// 认不出的写法（空、负数、小数、乱码）返回 nil；日期已经过去返回 0。
    static func seconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let raw = header?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            return TimeInterval(raw)
        }
        guard let date = httpDate.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// IMF-fixdate，如 `Sun, 06 Nov 1994 08:49:37 GMT`（RFC 9110 规定的首选格式）。
    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()
}
