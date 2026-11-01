import Foundation

/// Claude 订阅套餐的显示名，照搬上游 `src/lib/claudePlan.ts` 的 claudePlanLabel（英文默认文案）：
/// `subscriptionType`（Claude Code 记在凭据里）加 `rateLimitTier` 区分 Max 5x / 20x 与 Team 高级席位。
/// 认不出的套餐首字母大写照写；读不到（API key 登录、旧凭据）为 nil，界面上就不显示。
/// 两个字段都先去首尾空白（上游 Rust 侧 credential_plan 读出来时就 trim 过）。
enum ClaudePlan {
    static func label(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !type.isEmpty else { return nil }
        let tier = rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "pro":
            return "Pro"
        case "max":
            if tier == "default_claude_max_20x" { return "Max 20x" }
            if tier == "default_claude_max_5x" { return "Max 5x" }
            return "Max"
        case "team":
            // Claude Code 自己也按这个组合认 Team 的高级席位
            return tier == "default_claude_max_5x" ? "Team Premium" : "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return type.prefix(1).uppercased() + type.dropFirst()
        }
    }
}
