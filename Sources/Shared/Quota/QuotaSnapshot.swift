import Foundation

/// 落盘的 Claude 额度快照：上次成功拿到的各档额度，加上查询闸门的状态（上次查询时刻、限流暂停到几点）。
/// App 层存进 UserDefaults：重启后先显示上次的数，限流暂停期间也不会一启动就再打接口。
/// （cc-switch 的额度缓存只在内存里，进程重启即空；这里多存一份是本应用的取舍，见 2026-11-20 规格。）
struct QuotaSnapshot: Codable, Equatable {
    var tiers: [QuotaTier]
    var lastAttempt: Date?
    var blockedUntil: Date?

    /// 还能显示的档：已经过了重置时刻的丢掉（那个窗口已经结束，旧百分比会误导）；没有重置时刻的照留。
    static func live(_ tiers: [QuotaTier], now: Date) -> [QuotaTier] {
        tiers.filter { tier in tier.resetsAt.map { $0 > now } ?? true }
    }

    static func decode(_ data: Data) throws -> QuotaSnapshot {
        try JSONDecoder().decode(QuotaSnapshot.self, from: data)
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
