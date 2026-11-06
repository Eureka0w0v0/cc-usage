import Foundation

/// 菜单栏一轮刷新要查的全部用量。全是 SQL 和会话日志扫描，在后台线程跑，不碰 UI；结果是值类型，跨线程安全。
struct MenuBarDataLoader {
    /// 单个 AI 的 D/W/M 汇总（只算勾了码片的 app）。
    struct AppPeriods: Sendable {
        var today: UsageSummary?
        var week: UsageSummary?
        var month: UsageSummary?
    }

    struct Output: Sendable {
        var snap: UsageSnapshot
        var today: UsageSummary
        var week: UsageSummary
        var month: UsageSummary
        var appSummaries: [String: AppPeriods] = [:]
    }

    let store: UsageStore

    /// chips = 按 AI 分组的码片选中集，只查勾了的 (app, 周期)，避免白白多跑 SQL。
    /// 任何一条查询失败都抛：调用方保留上一轮的数字并显示错误，不把这一轮的半截结果写上去。
    func load(chips: Set<String>, now: Date = Date(), calendar: Calendar = .current) throws -> Output {
        // 缺省 filter = 本地今日零点 → now（resolvedFilter），全部来源/模型——
        // 与菜单栏「今日」完全同口径，snap.today 直接复用，不再单独多算一次。
        // 菜单栏只读 today/trend/lastEventAt，累计值拿了就扔 → 跳过那次全库聚合。
        let snap = try store.snapshot(filter: UsageFilter(), now: now, calendar: calendar, includeCumulative: false)
        // 菜单栏 W/M：近 7 天 / 近 30 天，全部来源。按自然日回溯（含今天、从当地零点起），
        // 和主窗口的 7d / 30d 预设同一口径；不用日历「本周/本月」——月初时「本周」会跨回上月、
        // 反比「本月」多。回溯起点 30 天 ≤ 7 天 ≤ 今天零点，「月≥周≥日」照样成立。
        let end = Int64(now.timeIntervalSince1970)
        let weekStart = UsageWindow.lookbackStart(days: 7, now: now, calendar: calendar)
        let monthStart = UsageWindow.lookbackStart(days: 30, now: now, calendar: calendar)
        var out = Output(snap: snap, today: snap.today,
                         week: try store.rangeSummary(UsageFilter(start: weekStart, end: end), calendar: calendar),
                         month: try store.rangeSummary(UsageFilter(start: monthStart, end: end), calendar: calendar))
        let dayStart = UsageWindow.lookbackStart(days: 1, now: now, calendar: calendar)
        for app in MBApp.allCases {
            func need(_ p: ChipKey.Period) -> Bool {
                chips.contains(.usage(app, .tokens, p)) || chips.contains(.usage(app, .cost, p))
            }
            func summary(_ start: Int64) throws -> UsageSummary {
                try store.rangeSummary(UsageFilter(start: start, end: end, appType: app.rawValue), calendar: calendar)
            }
            guard need(.today) || need(.week) || need(.month) else { continue }
            var s = AppPeriods()
            if need(.today) { s.today = try summary(dayStart) }
            if need(.week) { s.week = try summary(weekStart) }
            if need(.month) { s.month = try summary(monthStart) }
            out.appSummaries[app.rawValue] = s
        }
        return out
    }
}
