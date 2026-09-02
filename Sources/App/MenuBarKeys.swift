import Foundation

// MARK: - 菜单栏显示设置（持久化 key）

/// 菜单栏（MenuBarExtra label）显示哪些「码片」的持久化开关键。
/// 三个维度自由勾选：用量 Tokens / 花费 Cost（各 今日·本周·本月）+ 额度 Quota（5H·Week）。
/// 默认 = 今日 Tokens + 今日 花费（与旧版行为一致）。值存 UserDefaults，
/// MenuBarLabel(读) 与 MenuBarSettingsView(写) 都用 @AppStorage 绑定同一批 key → 改动即时生效。
enum MBKey {
    static let tokToday  = "mb.tokens.today"
    static let tokWeek   = "mb.tokens.week"
    static let tokMonth  = "mb.tokens.month"
    static let costToday = "mb.cost.today"
    static let costWeek  = "mb.cost.week"
    static let costMonth = "mb.cost.month"
    static let quota5H   = "mb.quota.5h"
    static let quotaWeek = "mb.quota.week"
    static let icon      = "mb.icon"        // 菜单栏 ⚡ 图标开关（默认开）
    static let quotaBar  = "mb.quotaBar"    // 额度画进度条（默认开）；关掉则显示百分比数字
    static let appChips  = "mb.appChips"    // 按 AI 分组的码片选中集（字符串数组）
    static let ctxBounds = "mb.ctxBounds"   // 按前台 app 分桶的容量边界 [bundleID: [下界, 上界]]
}

/// 菜单栏可分组展示的 AI 来源。All（全部合计）不在此枚举里——它就是 MBKey 那组旧开关。
/// 码片 key 格式 "\(rawValue).tokens.today" / "\(rawValue).cost.week" / "codex.quota"。
enum MBApp: String, CaseIterable {
    // rawValue 必须等于 cc-switch DB 的 app_type（grokbuild 而非 grok）
    case claude, codex, gemini, opencode, antigravity, grokbuild
    var title: String {
        switch self {
        case .claude: return "Claude"; case .codex: return "Codex"
        case .gemini: return "Gemini"; case .opencode: return "OpenCode"
        case .antigravity: return "Antigravity"; case .grokbuild: return "Grok"
        }
    }
    /// Antigravity 没有本地用量库（Tokens/Cost 无从谈起），只有各模型配额。
    var hasUsageBuckets: Bool { self != .antigravity }
    /// 品牌模板图标（Resources 里的黑色 alpha PNG，菜单栏段前缀与设置分组标题共用）。
    var iconAsset: String {
        switch self {
        case .claude: return "brand-claude"; case .codex: return "brand-openai"
        case .gemini: return "brand-gemini"; case .opencode: return "brand-opencode"
        case .antigravity: return "brand-antigravity"; case .grokbuild: return "brand-grok"
        }
    }
}
