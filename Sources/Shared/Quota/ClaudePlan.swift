import Foundation

/// Claude 订阅套餐的显示名。
///
/// 取法照 Claude Code 2.1.316：服务器在 `/api/oauth/profile` 里下发 `organization.plan_display_name`，
/// Claude Code 校验后存进全局配置（`~/.claude.json`）的 `oauthAccount.planDisplayName`，显示时优先用它；
/// 拿不到才按凭据里的 `subscriptionType` 推断。所以官方改名不用等我们发版。
///
/// 推断用的映射起初照搬上游 cc-switch 的 claudePlanLabel（`src/lib/claudePlan.ts`）。2026-10-30 官方把
/// Max 20x 改名 Ultra、Max 5x 改名 Max，凭据里的标识却没变（仍是 `max` + `default_claude_max_20x` / `_5x`），
/// 上游到 v4.0.24 还写着旧名；这里改用新名，与官方套餐页一致。
enum ClaudePlan {
    /// - displayName：服务器下发的显示名（见 `displayName(fromClaudeConfig:)`），不合法时当没有。
    /// - 读不到套餐类型（API key 登录、旧凭据）时不显示，哪怕配置里留着显示名——Claude Code 也只在有类型时才用它。
    /// 类型和档位都先去首尾空白（上游 Rust 侧 credential_plan 读出来时就 trim 过），类型不分大小写。
    static func label(displayName: String?, subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let type = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !type.isEmpty else { return nil }
        if let displayName, isValidDisplayName(displayName) { return displayName }
        let tier = rateLimitTier?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "pro":
            return "Pro"
        case "max":
            return tier == "default_claude_max_20x" ? "Ultra" : "Max"
        case "team":
            // Claude Code 自己也按这个组合认 Team 的高级席位
            return tier == "default_claude_max_5x" ? "Team Premium" : "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return type.prefix(1).uppercased() + type.dropFirst()
        }
    }

    /// Claude Code 校验 plan_display_name 的同一条规则（`^[\p{L}\p{N}](?:[\p{L}\p{N} .+-]{0,38}[\p{L}\p{N}+])?$`，
    /// JS 的 `u` 模式）：1–40 个字符，字母或数字开头，字母、数字或 + 结尾，中间允许空格、点、加号、连字符。
    /// ICU 的 `$` 会放过结尾换行、JS 不会，所以锚点写成 `\A` / `\z`。
    static func isValidDisplayName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return displayNamePattern.firstMatch(in: name, range: range) != nil
    }

    private static let displayNamePattern: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"\A[\p{L}\p{N}](?:[\p{L}\p{N} .+\-]{0,38}[\p{L}\p{N}+])?\z"#)
        } catch {
            preconditionFailure("套餐显示名的校验正则写错了：\(error)")
        }
    }()

    /// 从 Claude Code 全局配置的 JSON 里取 `oauthAccount.planDisplayName`；不是字符串（缺键、null、数字）或
    /// JSON 读不出来都返回 nil。合不合法由 `label` 判断。配置里还有邮箱等个人信息，只取这一个字段。
    static func displayName(fromClaudeConfig data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return nil }
        return account["planDisplayName"] as? String
    }
}
