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
    static let groupAntigravity = "mb.group.antigravity"   // 历史键名保留（对应 MBApp.agy）
    static let groupGrok        = "mb.group.grok"      // 历史键名保留（对应 MBApp.grokbuild）
    static let groupPi          = "mb.group.pi"
    static let groupMcode       = "mb.group.mcode"
    static let groupKimi        = "mb.group.kimi"
    static let groupOmp         = "mb.group.omp"
    static let groupDsh         = "mb.group.dsh"
}

/// embed 面板经 set_setting 写进 UserDefaults 的键（PanelWebView 桥接与 PanelModel 启动接管共用）。
enum EmbedKey {
    static let prefix = "embed."
    /// 面板传来的裸键（如 "refreshIntervalMs"）→ UserDefaults 键。
    static func setting(_ name: String) -> String { prefix + name }
    static let refreshIntervalName = "refreshIntervalMs"
    static let refreshIntervalMs = setting(refreshIntervalName)
    /// 主窗口的显示设置（请求日志列显隐、趋势图样式），JSON 字符串；桥接 get_settings 读它。
    static let usageDisplay = setting("usageDisplay")
    /// 主窗口指标条选中的指标（tokens / cost / requests / hitRate），embed 经 set_setting("usage.trendMetric") 写；
    /// 菜单栏趋势图跟着它画。
    static let trendMetric = setting("usage.trendMetric")
}

/// 菜单栏可分组展示的 AI 来源。All（全部合计）不在此枚举里——它就是 MBKey 那组旧开关。
/// 码片键见 ChipKey。
enum MBApp: String, CaseIterable {
    // rawValue 必须等于 cc-switch DB 的 app_type（grokbuild 而非 grok）。
    //
    // 覆盖上游 `KNOWN_APP_TYPES`（src/types/usage.ts，v4.0.22）的全部 11 项。上游那份清单里没有的
    // `openclaw` / `hermes` 只是"被管理的 app"，压根不产生用量行，故不进本枚举；`claude-desktop` 在查询层
    // 就折叠进 `claude`（见 foldedAppL/R），单列会只显示半个数、反而误导。
    // `omp`（Oh My Pi）v4.0.22 起由上游导入用量（本应用的 OmpOverlay 叠加还没入库的部分）；`dsh`
    // （DeepSeek Harness）是 v4.0.22 新增的应用，用量同样来自上游的会话导入。
    // `agy` 原名 `antigravity`：上游 v4.0.18 有 agy 之前，本应用只拿它查额度、键是自起的名字；v2.1.0 起
    // 上游导入 Antigravity 的会话用量（app_type = agy），改成同名，旧码片键由 MenuBarChipMigration 迁移。
    // 追加新项一律放末尾：allCases 的顺序就是菜单栏里各段的排列，插在中间会平白
    // 打乱用户已经习惯的位置。
    case claude, codex, gemini, opencode, agy, grokbuild, pi, mcode, kimi, omp, dsh
    var title: String {
        switch self {
        case .claude: return "Claude"; case .codex: return "Codex"
        case .gemini: return "Gemini"; case .opencode: return "OpenCode"
        case .agy: return "Antigravity"; case .grokbuild: return "Grok"
        case .pi: return "Pi"; case .mcode: return "MiniMax Code"
        case .kimi: return "Kimi Code"
        case .omp: return "Oh My Pi"; case .dsh: return "DeepSeek Harness"
        }
    }
    /// 品牌模板图标（BrandIcons 里的 64×64 黑色 alpha PNG，菜单栏段前缀与设置分组
    /// 标题共用）。nil = 该家没有可用图标，调用方只渲染文字——上游对 Pi 同样没有
    /// 图标（`ProviderIcon icon="pi" showFallback={false}`），这里如实照搬而不是
    /// 指向一个不存在的文件名靠 NSImage 返回 nil 兜底。brand-kimi / brand-deepseek 由上游
    /// `src/icons/extracted/` 的 kimi.svg / deepseek.svg 转来（颜色统一成黑、只留 alpha）；brand-omp 取上游
    /// `src/icons/extracted/index.ts` 里 Oh My Pi 内联 SVG 的 π 字形（去掉深色底块，否则模板图是一整块实心方块）。
    var iconAsset: String? {
        switch self {
        case .claude: return "brand-claude"; case .codex: return "brand-openai"
        case .gemini: return "brand-gemini"; case .opencode: return "brand-opencode"
        case .agy: return "brand-antigravity"; case .grokbuild: return "brand-grok"
        case .mcode: return "brand-minimax"; case .kimi: return "brand-kimi"
        case .omp: return "brand-omp"; case .dsh: return "brand-deepseek"
        case .pi: return nil
        }
    }

    /// 设置面板里各分组的顺序。和 allCases（菜单栏段的顺序）不一样：Antigravity 在设置面板排 MiniMax Code 后面，
    /// 用户已经习惯这个位置。
    static let settingsOrder: [MBApp] = [.claude, .codex, .gemini, .opencode, .grokbuild, .pi, .mcode, .agy,
                                         .kimi, .omp, .dsh]

    /// 设置面板这个分组展开状态的持久化键（agy、grokbuild 的键是历史名，不能改）。
    var expansionKey: String {
        switch self {
        case .claude: return MBKey.groupClaude
        case .codex: return MBKey.groupCodex
        case .gemini: return MBKey.groupGemini
        case .opencode: return MBKey.groupOpencode
        case .agy: return MBKey.groupAntigravity
        case .grokbuild: return MBKey.groupGrok
        case .pi: return MBKey.groupPi
        case .mcode: return MBKey.groupMcode
        case .kimi: return MBKey.groupKimi
        case .omp: return MBKey.groupOmp
        case .dsh: return MBKey.groupDsh
        }
    }

    /// 没有额度可显示时 Quota 行的说明；nil = 这家有额度数据，设置面板列勾选项。
    var quotaNote: String? {
        switch self {
        case .claude, .codex, .agy:
            return nil
        // Gemini 按天限请求数且不落盘、OpenCode 配额归背后 provider、Grok/xAI 无公开 remaining/utilization 查询接口；
        // Pi / MiniMax Code 的用量经各自的会话导入器进 cc-switch 的库（无代理通道），额度归背后 provider，本应用无从查起。
        case .gemini, .opencode, .grokbuild, .pi, .mcode:
            return "No quota API"
        // Kimi Code：上游的官方账号额度走它的授权中心（OAuth），本应用没做。Oh My Pi：按各家 API key 计费，没有统一的
        // 额度可查。DeepSeek Harness：上游在授权中心查 DeepSeek 账号余额，本应用没做。
        case .kimi, .omp, .dsh:
            return "Not supported"
        }
    }
}

/// 按 AI 分组的码片键。`mb.appChips` 里存的就是 rawValue，格式变了用户的勾选就丢了：
///   <app>.tokens.<today|week|month>、<app>.cost.<today|week|month>、<app>.quota.<额度档>
/// 选中集本身仍是 Set<String>：里面可能有更早版本留下、这一版不认识的键，要原样保留。
enum ChipKey: Hashable {
    enum Metric: String, CaseIterable { case tokens, cost }
    enum Period: String, CaseIterable { case today, week, month }

    case usage(MBApp, Metric, Period)
    /// 额度档：Codex 是窗口标签（5H / 7D / 30D），Antigravity 是桶 id。
    case quota(MBApp, String)

    var rawValue: String {
        switch self {
        case .usage(let app, let metric, let period): return "\(app.rawValue).\(metric.rawValue).\(period.rawValue)"
        case .quota(let app, let tier): return Self.quotaPrefix(app) + tier
        }
    }

    static func quotaPrefix(_ app: MBApp) -> String { "\(app.rawValue).quota." }
}

extension Set where Element == String {
    func contains(_ key: ChipKey) -> Bool { contains(key.rawValue) }
    /// 这一家有没有勾任何额度码片。
    func hasQuotaChip(_ app: MBApp) -> Bool { contains { $0.hasPrefix(ChipKey.quotaPrefix(app)) } }
}
