import XCTest

// 会话日志时间戳 → epoch 毫秒，逐条对齐 chrono 0.4.44 的 parse_from_rfc3339 + timestamp_millis（cc-switch 就用它）。
// 计时估算要逐块解析时间戳，换掉了一次 44µs 的 ISO8601DateFormatter（2026-10-16）。
// 每个用例的注释写明它负责杀哪些变异体。
final class RFC3339Tests: XCTestCase {
    /// 2026-06-07T13:00:05Z
    private let base: Int64 = 1_780_837_205_000

    /// Claude Code 实际写的形状，以及不带小数秒的写法。
    func testClaudeCodeTimestamps() {
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.000Z"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.041Z"), base + 41)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05Z"), base)
    }

    /// 小数秒至少一位，超过 9 位的忽略，截到毫秒（不四舍五入）。
    /// 杀变异体：四舍五入（.9999 → +1000）；位数不补齐（.5 → +5）；允许点号后面没有数字。
    func testFractionalSecondsAreTruncatedToMilliseconds() {
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.5Z"), base + 500)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.12Z"), base + 120)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.9999Z"), base + 999)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.123456789Z"), base + 123)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05.1234567891234Z"), base + 123)
        XCTAssertNil(RFC3339.epochMillis("2026-06-07T13:00:05.Z"))
    }

    /// 时区：Z / z / ±HH:MM（负号也可以是 U+2212），偏移不足一天；缺偏移、少冒号、分钟 ≥ 60、后面多字符都不行。
    /// 杀变异体：偏移方向反了；不认小写 z 或 U+2212；偏移上限放宽到 24 小时；不检查结尾多出的字符。
    func testTimezoneOffsets() {
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T21:00:05+08:00"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T07:30:05-05:30"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T07:30:05\u{2212}05:30"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05-00:00"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:05z"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-08T12:59:05+23:59"), base)
        for bad in ["2026-06-07T13:00:05", "2026-06-07T13:00:05+0800", "2026-06-07T13:00:05+08",
                    "2026-06-07T13:00:05+08:60", "2026-06-07T13:00:05+24:00", "2026-06-07T13:00:05UTC",
                    "2026-06-07T13:00:05Z ", "2026-06-07T13:00:05Zx", "2026-06-07T13:00:05.5"] {
            XCTAssertNil(RFC3339.epochMillis(bad), bad)
        }
    }

    /// 日期和时间之间是 T、t 或空格；日期必须真实存在；时、分、秒越界不行。秒 60 是闰秒，算进下一秒，
    /// 任意分钟都认（同 chrono：先记成 59 秒再加 1 秒）。
    /// 杀变异体：不校验各月天数或闰年规则（2026-02-29 / 1900-02-29）；不认闰秒；闰秒没加那 1 秒。
    func testDateAndTimeValidation() {
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07t13:00:05Z"), base)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07 13:00:05Z"), base)
        XCTAssertNotNil(RFC3339.epochMillis("2028-02-29T00:00:00Z"))
        XCTAssertNotNil(RFC3339.epochMillis("2000-02-29T00:00:00Z"))
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T12:59:60Z"), base - 5_000)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T12:59:60.500Z"), base - 4_500)
        XCTAssertEqual(RFC3339.epochMillis("2026-06-07T13:00:60Z"), base + 55_000)
        for bad in ["2026-02-29T00:00:00Z", "1900-02-29T00:00:00Z", "2026-04-31T00:00:00Z",
                    "2026-13-01T00:00:00Z", "2026-00-10T00:00:00Z", "2026-06-00T00:00:00Z",
                    "2026-06-07T24:00:00Z", "2026-06-07T13:60:00Z", "2026-06-07T13:00:61Z",
                    "2026-06-07X13:00:05Z", "2026-6-07T13:00:05Z", "2026-06-07T13:00:5Z",
                    "", "not a timestamp", "２０２６-06-07T13:00:05Z"] {
            XCTAssertNil(RFC3339.epochMillis(bad), bad)
        }
    }

    /// 1970 年以前：毫秒 = 向下取整的秒 × 1000 + 毫秒（chrono timestamp_millis 的写法），得负数；公元 0 年照算。
    func testBeforeTheEpoch() {
        XCTAssertEqual(RFC3339.epochMillis("1970-01-01T00:00:00Z"), 0)
        XCTAssertEqual(RFC3339.epochMillis("1969-12-31T23:59:59.500Z"), -500)
        XCTAssertEqual(RFC3339.epochMillis("0000-03-01T00:00:00Z"), -62_162_035_200_000)
    }

    /// 和 Foundation 的公历换算逐条对拍：1900–2199 年里取 2000 个时刻，带随机的毫秒和时区偏移（固定种子，可复现）。
    /// 杀变异体：日期换算里任何一处常数、闰年规则或偏移方向写错。
    func testMatchesFoundationCalendarOnManyTimestamps() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var seed: UInt64 = 0x5EED_2026_1016
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        for _ in 0..<2000 {
            let y = 1900 + next(300), m = 1 + next(12)
            let firstOfMonth = try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: 1)))
            let d = 1 + next(try XCTUnwrap(cal.range(of: .day, in: .month, for: firstOfMonth)).count)
            let h = next(24), mi = next(60), s = next(60), ms = next(1000)
            let offsetMinutes = next(2 * 1439 + 1) - 1439
            let sign = offsetMinutes < 0 ? "-" : "+"
            let text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d",
                              y, m, d, h, mi, s, ms, sign, abs(offsetMinutes) / 60, abs(offsetMinutes) % 60)
            let local = try XCTUnwrap(cal.date(from: DateComponents(year: y, month: m, day: d,
                                                                    hour: h, minute: mi, second: s)))
            let expected = (Int64(local.timeIntervalSince1970) - Int64(offsetMinutes) * 60) * 1000 + Int64(ms)
            XCTAssertEqual(RFC3339.epochMillis(text), expected, text)
        }
    }
}
