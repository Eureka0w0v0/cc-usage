import XCTest

// 「近 N 天」的起点 = 今天往前 N−1 个自然日的当地零点（对齐上游修好的 getPresetLookbackStart，
// 主窗口的 7d / 30d 预设就是这个口径）。菜单栏 W / M 用它，两边同名同数。
final class UsageWindowTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func date(_ cal: Calendar, _ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    /// 起点在当地时区下的年月日时分。
    private func local(_ cal: Calendar, _ epoch: Int64) -> [Int] {
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute],
                                   from: Date(timeIntervalSince1970: TimeInterval(epoch)))
        return [c.year!, c.month!, c.day!, c.hour!, c.minute!]
    }

    // 负责杀的变异体：往前推 N 天而不是 N−1 天（多出一天）。
    func testTokyoCountsTodayAsTheFirstDay() {
        let cal = calendar("Asia/Tokyo")
        let now = date(cal, 2026, 10, 26, 15)
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 1, now: now, calendar: cal)), [2026, 10, 26, 0, 0])
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 7, now: now, calendar: cal)), [2026, 10, 20, 0, 0])
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 30, now: now, calendar: cal)), [2026, 9, 27, 0, 0])
    }

    // 春令时（纽约 2026-03-08 拨快 1 小时）：起点仍是当地零点。按 24 小时倍数减会落到前一天 23:00。
    // 负责杀的变异体：今天零点减 (N−1)×86400 秒。
    func testSpringForwardStillStartsAtLocalMidnight() {
        let cal = calendar("America/New_York")
        let now = date(cal, 2026, 3, 10, 0, 30)
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 7, now: now, calendar: cal)), [2026, 3, 4, 0, 0])
    }

    // 冬令时（纽约 2026-11-01 拨慢 1 小时）：同理不能多跨一天。
    func testFallBackStillStartsAtLocalMidnight() {
        let cal = calendar("America/New_York")
        let now = date(cal, 2026, 11, 3, 23, 30)
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 7, now: now, calendar: cal)), [2026, 10, 28, 0, 0])
    }

    // 零点本身被夏令时跳过的地方（圣保罗 2018-11-04 00:00 直接跳到 01:00）：取那天的第一刻。
    func testSkippedMidnightUsesTheFirstInstantOfThatDay() {
        let cal = calendar("America/Sao_Paulo")
        let now = date(cal, 2018, 11, 7, 12)
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 4, now: now, calendar: cal)), [2018, 11, 4, 1, 0])
    }

    // 反过来：今天就是零点被跳过的那天（今天的第一刻是 01:00），往回推的日子照样从当地零点起。
    // 按日历加减天数会保留 01:00 这个钟点，必须再取一次那天的第一刻。
    // 负责杀的变异体：直接用加减天数的结果，不再取当天第一刻。
    func testOnASkippedMidnightDayEarlierDaysStillStartAtMidnight() {
        let cal = calendar("America/Sao_Paulo")
        let now = date(cal, 2018, 11, 4, 12)
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 1, now: now, calendar: cal)), [2018, 11, 4, 1, 0])
        XCTAssertEqual(local(cal, UsageWindow.lookbackStart(days: 7, now: now, calendar: cal)), [2018, 10, 29, 0, 0])
    }

    // 「月 ≥ 周 ≥ 日」：当初把日历「本周 / 本月」换成滚动窗口就是为了这条（f7b1919），新口径照样成立。
    func testLongerWindowsNeverStartLater() {
        let cal = calendar("Asia/Tokyo")
        let now = date(cal, 2026, 11, 1, 0, 5)   // 月初、刚过零点
        let d = UsageWindow.lookbackStart(days: 1, now: now, calendar: cal)
        let w = UsageWindow.lookbackStart(days: 7, now: now, calendar: cal)
        let m = UsageWindow.lookbackStart(days: 30, now: now, calendar: cal)
        XCTAssertLessThanOrEqual(m, w)
        XCTAssertLessThanOrEqual(w, d)
        XCTAssertLessThanOrEqual(d, Int64(now.timeIntervalSince1970))
    }

    // 不合法的天数按 1 天算（今天零点），不往未来推。
    func testNonPositiveDaysMeansToday() {
        let cal = calendar("Asia/Tokyo")
        let now = date(cal, 2026, 10, 26, 15)
        XCTAssertEqual(UsageWindow.lookbackStart(days: 0, now: now, calendar: cal),
                       UsageWindow.lookbackStart(days: 1, now: now, calendar: cal))
    }
}
