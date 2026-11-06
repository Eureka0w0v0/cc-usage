import Foundation

/// 用量统计的时间窗起点。
enum UsageWindow {
    /// 「近 N 天」的起点（epoch 秒）：今天往前 N−1 个自然日那天的第一刻，终点是现在。
    ///
    /// 与 cc-switch 主窗口 7d / 14d / 30d 预设同一口径（`src/lib/usageRange.ts` 的
    /// getPresetLookbackStart，上游 50e091b0 修好夏令时之后的版本）：按日历往回数日子，
    /// 不是按 24 小时的倍数往回减——跨夏令时那天只有 23 或 25 小时，按秒减会落到相邻的日子上。
    /// 零点本身被夏令时跳过的时区，取那天实际存在的第一刻（startOfDay 的语义）。
    ///
    /// 菜单栏 W / M 用它。早先用的是滚动的 7×24 / 30×24 小时（`f7b1919`：为了不让日历
    /// 「本周」在月初跨回上月、比「本月」还多）；按自然日回溯同样保证「月 ≥ 周 ≥ 日」，
    /// 还和主窗口的数字对得上。
    static func lookbackStart(days: Int, now: Date, calendar: Calendar) -> Int64 {
        let today = calendar.startOfDay(for: now)
        let back = days - 1   // 不合法的天数（≤ 1）都落到下面的 guard，按今天零点算
        guard back > 0,
              let day = calendar.date(byAdding: .day, value: -back, to: today)
        else { return Int64(today.timeIntervalSince1970) }
        return Int64(calendar.startOfDay(for: day).timeIntervalSince1970)
    }
}
