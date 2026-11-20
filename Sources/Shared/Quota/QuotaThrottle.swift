import Foundation

/// Claude 额度接口（`/api/oauth/usage`）的查询闸门，纯值类型。
///
/// - 平时两次查询至少隔 5 分钟（对齐 cc-switch 的 REFETCH_INTERVAL），成功失败都算一次。
/// - 被限流（HTTP 429）后按服务端的 `Retry-After` 暂停到指定时刻；没给这个头先停 30 分钟；
///   离谱的值钳到 6 小时，免得一个坏头把额度永久关掉。
/// - 暂停期间连用户手动刷新也不打：这个接口按账号限流（实测一小时十几次就 429），限流期间每多一次请求
///   都可能把限流拖长，同一账号下的其它客户端（Claude Code 状态栏等）也跟着拿不到数。
struct QuotaThrottle: Equatable {
    static let minInterval: TimeInterval = 5 * 60
    static let defaultBackoff: TimeInterval = 30 * 60
    static let maxBackoff: TimeInterval = 6 * 3600

    /// 上次发起查询的时刻。
    private(set) var lastAttempt: Date?
    /// 限流暂停到这一刻（含之前都不查）。
    private(set) var blockedUntil: Date?

    init(lastAttempt: Date? = nil, blockedUntil: Date? = nil) {
        self.lastAttempt = lastAttempt
        self.blockedUntil = blockedUntil
    }

    /// 这一刻能不能发起查询。`force` = 用户手动刷新：不受 5 分钟间隔限制，但仍受限流暂停限制。
    func mayFetch(now: Date, force: Bool) -> Bool {
        if let blockedUntil, now < blockedUntil { return false }
        if force { return true }
        guard let lastAttempt else { return true }
        return now.timeIntervalSince(lastAttempt) >= Self.minInterval
    }

    mutating func recordAttempt(at now: Date) {
        lastAttempt = now
    }

    /// 收到 429：暂停到 now + 服务端要求的秒数（钳在 0…6 小时；没给按 30 分钟）。
    mutating func recordRateLimited(at now: Date, retryAfter: TimeInterval?) {
        let wait = min(max(retryAfter ?? Self.defaultBackoff, 0), Self.maxBackoff)
        blockedUntil = now.addingTimeInterval(wait)
    }
}
