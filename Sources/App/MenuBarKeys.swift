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
    // 设置面板各分组的展开状态（MenuBarSettingsView 的 @AppStorage；reload 也读 codex 这个决定是否扫描）
    static let groupAll         = "mb.group.all"
    static let groupClaude      = "mb.group.claude"
    static let groupCodex       = "mb.group.codex"
    static let groupGemini      = "mb.group.gemini"
    static let groupOpencode    = "mb.group.opencode"
    static let groupAntigravity = "mb.group.antigravity"
    static let groupGrok        = "mb.group.grok"      // 历史键名保留（对应 MBApp.grokbuild）
    static let groupPi          = "mb.group.pi"
    static let groupMcode       = "mb.group.mcode"
}

/// embed 面板经 set_setting 写进 UserDefaults 的键（PanelWebView 桥接与 PanelModel 启动接管共用）。
enum EmbedKey {
    static let prefix = "embed."
    /// 面板传来的裸键（如 "refreshIntervalMs"）→ UserDefaults 键。
    static func setting(_ name: String) -> String { prefix + name }
    static let refreshIntervalName = "refreshIntervalMs"
    static let refreshIntervalMs = setting(refreshIntervalName)
}

/// 菜单栏可分组展示的 AI 来源。All（全部合计）不在此枚举里——它就是 MBKey 那组旧开关。
/// 码片 key 格式 "\(rawValue).tokens.today" / "\(rawValue).cost.week" / "codex.quota"。
enum MBApp: String, CaseIterable {
    // rawValue 必须等于 cc-switch DB 的 app_type（grokbuild 而非 grok）。
    //
    // 覆盖上游 `KNOWN_APP_TYPES`（src/types/usage.ts）的全部 7 项，外加本 app 独有的
    // antigravity。上游那份清单里没有的 `openclaw` / `hermes` 只是"被管理的 app"，
    // 压根不产生用量行，故不进本枚举；`claude-desktop` 在查询层就折叠进 `claude`
    // （见 foldedAppL/R），单列会只显示半个数、反而误导。
    // 追加新项一律放末尾：allCases 的顺序就是菜单栏里各段的排列，插在中间会平白
    // 打乱用户已经习惯的位置。
    case claude, codex, gemini, opencode, antigravity, grokbuild, pi, mcode
    var title: String {
        switch self {
        case .claude: return "Claude"; case .codex: return "Codex"
        case .gemini: return "Gemini"; case .opencode: return "OpenCode"
        case .antigravity: return "Antigravity"; case .grokbuild: return "Grok"
        case .pi: return "Pi"; case .mcode: return "MiniMax Code"
        }
    }
    /// Antigravity 没有本地用量库（Tokens/Cost 无从谈起），只有各模型配额。
    var hasUsageBuckets: Bool { self != .antigravity }
    /// 品牌模板图标（BrandIcons 里的 64×64 黑色 alpha PNG，菜单栏段前缀与设置分组
    /// 标题共用）。nil = 该家没有可用图标，调用方只渲染文字——上游对 Pi 同样没有
    /// 图标（`ProviderIcon icon="pi" showFallback={false}`），这里如实照搬而不是
    /// 指向一个不存在的文件名靠 NSImage 返回 nil 兜底。
    var iconAsset: String? {
        switch self {
        case .claude: return "brand-claude"; case .codex: return "brand-openai"
        case .gemini: return "brand-gemini"; case .opencode: return "brand-opencode"
        case .antigravity: return "brand-antigravity"; case .grokbuild: return "brand-grok"
        case .mcode: return "brand-minimax"
        case .pi: return nil
        }
    }
}
