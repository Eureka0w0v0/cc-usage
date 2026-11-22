import Foundation

/// Claude Code 缓存的额度：全局配置（`~/.claude.json`）里的 `cachedUsageUtilization`。
/// 对齐 cc-switch `services/claude_account/usage.rs` 的 read_cached 与 `subscription.rs` 的 account_quota_with_cache。
///
/// `claude -p /usage` 由 Claude Code 自己回答、不问模型：它按自己的锁刷新令牌、查额度，把结果缓存进全局配置
/// （`utilization` 与 `/api/oauth/usage` 的返回同一个结构，走同一套解析）。令牌过期时读这份缓存，见 ClaudeLoginRecovery。
/// 全局配置里还有邮箱等个人信息，这里只取账号 id 和这份缓存。
enum ClaudeUsageCache {
    /// 只信这么新的缓存：最近一次 `/usage` 跑成功写下的。更旧的说明这段时间里没跑成（登录失效、没装 claude…），
    /// 显示它会把「要重新登录」藏起来。
    static let maxAge: TimeInterval = ClaudeUsageCLI.runInterval + ClaudeUsageCLI.runTimeout

    struct Entry: Equatable {
        let fetchedAt: Date
        let tiers: [QuotaTier]
    }

    /// 当前登录的账号：`oauthAccount.accountUuid`，去首尾空白，空串当没有（同上游 identity_from_profile）。
    static func accountUuid(fromProfile data: Data) -> String? {
        guard let account = root(data)?["oauthAccount"] as? [String: Any],
              let uuid = (account["accountUuid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uuid.isEmpty else { return nil }
        return uuid
    }

    /// 账号 `account` 的那份缓存：Claude Code 自己也只认 accountUuid 对得上的。缺字段、类型不对、JSON 读不出来都当没有。
    static func entry(fromProfile data: Data, account: String) -> Entry? {
        guard let cached = root(data)?["cachedUsageUtilization"] as? [String: Any],
              cached["accountUuid"] as? String == account,
              let milliseconds = number(cached["fetchedAtMs"]),
              let utilization = cached["utilization"] as? [String: Any] else { return nil }
        return Entry(fetchedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                     tiers: ClaudeQuotaParser.parse(utilization))
    }

    /// 取数以来不超过 maxAge 才算新（正好到点也算）。取数时刻在将来（时钟回拨）同上游算新。
    static func isFresh(_ entry: Entry, now: Date) -> Bool {
        now.timeIntervalSince(entry.fetchedAt) <= maxAge
    }

    private static func root(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// 整数或小数（上游先 as_i64 再 as_f64）；布尔在 JSONSerialization 里也是 NSNumber，要排除。
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}
