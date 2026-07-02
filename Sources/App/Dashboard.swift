import SwiftUI
import WidgetKit
import Combine
import AppKit

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
}

// MARK: - 日期范围预设

enum DateRangePreset: String, CaseIterable, Identifiable {
    case today = "Today"
    case yesterday = "Yesterday"
    case last7 = "Last 7 Days"
    case last30 = "Last 30 Days"
    case all = "All Time"
    var id: String { rawValue }

    func bounds(now: Date = Date(), cal: Calendar = .current) -> (Int64?, Int64?) {
        let nowTs = Int64(now.timeIntervalSince1970)
        let today0 = cal.startOfDay(for: now)
        switch self {
        case .today:
            return (Int64(today0.timeIntervalSince1970), nowTs)
        case .yesterday:
            let y = cal.date(byAdding: .day, value: -1, to: today0)!
            return (Int64(y.timeIntervalSince1970), Int64(today0.timeIntervalSince1970))
        case .last7:
            return (Int64(cal.date(byAdding: .day, value: -7, to: now)!.timeIntervalSince1970), nowTs)
        case .last30:
            return (Int64(cal.date(byAdding: .day, value: -30, to: now)!.timeIntervalSince1970), nowTs)
        case .all:
            return (nil, nowTs)
        }
    }
}

// MARK: - 视图模型（含每 N 秒自动刷新）

@MainActor
final class PanelModel: ObservableObject {
    /// 进程内唯一实例（App 以 @StateObject 持有）。PanelWebView 桥接的 set_setting
    /// 经它把 embed 面板选的刷新间隔写穿过来，让菜单栏与面板同节奏。
    static weak var shared: PanelModel?

    @Published var snap: UsageSnapshot?
    @Published var error: String?
    @Published var apps: [String] = []
    @Published var models: [String] = []
    @Published var fiveHour: UsageSummary?   // 近 5 小时滚动窗口
    @Published var weekly: UsageSummary?     // 近 7 天滚动窗口

    // 菜单栏专用汇总（始终「全部来源/模型」，不随主窗口的来源/模型筛选变化）：今日 / 本周 / 本月。
    // 口径 = store.rangeSummary（logs + rollups 两表合并），与 cc-switch 对应区间数字一致。
    @Published var mbToday: UsageSummary?
    @Published var mbWeek: UsageSummary?
    @Published var mbMonth: UsageSummary?
    // 官方订阅额度窗口（five_hour / seven_day），供菜单栏电池码片用。
    // 仅当有「额度」码片开启时才发起查询；实际是否命中官方接口由 QuotaCache 5 分钟节流决定。
    @Published var quotaTiers: [QuotaTier] = []

    // 菜单栏码片开关——放在 @Published（而非视图里的 @AppStorage）里，因为 MenuBarExtra 的 label
    // 对 @AppStorage 变化不可靠响应，但对本 model 的 @Published 变化一定响应（Tokens 数已验证）。
    // didSet 落盘 UserDefaults；勾选额度即刻强制取一次。
    @Published var mbTokToday: Bool  { didSet { persist(MBKey.tokToday,  mbTokToday) } }
    @Published var mbTokWeek: Bool   { didSet { persist(MBKey.tokWeek,   mbTokWeek) } }
    @Published var mbTokMonth: Bool  { didSet { persist(MBKey.tokMonth,  mbTokMonth) } }
    @Published var mbCostToday: Bool { didSet { persist(MBKey.costToday, mbCostToday) } }
    @Published var mbCostWeek: Bool  { didSet { persist(MBKey.costWeek,  mbCostWeek) } }
    @Published var mbCostMonth: Bool { didSet { persist(MBKey.costMonth, mbCostMonth) } }
    @Published var mbQuota5H: Bool   { didSet { persist(MBKey.quota5H,   mbQuota5H);   if mbQuota5H { refreshQuotaNow() } } }
    @Published var mbQuotaWeek: Bool { didSet { persist(MBKey.quotaWeek, mbQuotaWeek); if mbQuotaWeek { refreshQuotaNow() } } }

    var mbAnyQuotaOn: Bool { mbQuota5H || mbQuotaWeek }
    private func persist(_ key: String, _ val: Bool) { UserDefaults.standard.set(val, forKey: key) }

    init() {
        let d = UserDefaults.standard
        func load(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
        mbTokToday  = load(MBKey.tokToday,  true)   // 默认：今日 Tokens + 今日花费（与旧版一致）
        mbTokWeek   = load(MBKey.tokWeek,   false)
        mbTokMonth  = load(MBKey.tokMonth,  false)
        mbCostToday = load(MBKey.costToday, true)
        mbCostWeek  = load(MBKey.costWeek,  false)
        mbCostMonth = load(MBKey.costMonth, false)
        mbQuota5H   = load(MBKey.quota5H,   false)
        mbQuotaWeek = load(MBKey.quotaWeek, false)
        // embed 面板持久化的刷新间隔（ms，set_setting 写入）：启动时接管为全局节奏，
        // 菜单栏与面板从第一秒起就一致。没存过则维持默认 5s。
        if let ms = d.object(forKey: "embed.refreshIntervalMs") as? Int {
            intervalSeconds = max(0, ms / 1000)
        }
        PanelModel.shared = self
    }

    /// embed 面板刷新选择器写穿过来的间隔（ms），0 = 关闭自动刷新。
    /// 与面板用同一个值 → 菜单栏 D/W/M、额度码片与面板数字同节奏更新。
    func applyEmbedRefreshInterval(ms: Int) {
        let secs = max(0, ms / 1000)
        if intervalSeconds != secs { intervalSeconds = secs }
    }

    @Published var appType: String? { didSet { reload() } }
    @Published var model: String? { didSet { reload() } }
    @Published var range: DateRangePreset = .today { didSet { reload() } }
    @Published var intervalSeconds: Int = 5 { didSet { restartTimer() } }

    // 可选刷新间隔（秒），0 = 关闭
    static let intervals = [1, 3, 5, 10, 30, 60, 0]

    // 限流额度（token）——用于 5H / Week 百分比。请按你的套餐真实额度调整。
    static let fiveHourLimitTokens: Int64 = 100_000_000    // 5 小时窗口额度（占位，待你给真实值）
    static let weeklyLimitTokens: Int64 = 1_000_000_000    // 每周额度（占位，待你给真实值）

    private var timer: AnyCancellable?
    private let store = UsageStore()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        apps = store.distinctAppTypes()
        models = store.distinctModels()
        reload()
        restartTimer()
        if mbAnyQuotaOn { refreshQuotaNow() }   // 启动时若已开启额度码片，立即取一次
    }

    /// 立即强制取一次官方额度（绕过 5 分钟节流），用于用户在菜单栏勾选「额度」码片时的即时反馈。
    func refreshQuotaNow() {
        Task { [weak self] in
            let tiers = await QuotaService.forceTiersForBridge()
            self?.quotaTiers = tiers
        }
    }

    private func restartTimer() {
        timer?.cancel()
        guard intervalSeconds > 0 else { return }
        timer = Timer.publish(every: Double(intervalSeconds), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
    }

    func reload() {
        let (s, e) = range.bounds()
        let now = Int64(Date().timeIntervalSince1970)
        do {
            snap = try store.snapshot(filter: UsageFilter(start: s, end: e, appType: appType, model: model))
            // 常驻窗口：跟随来源/模型筛选，时间窗固定
            fiveHour = try? store.rangeSummary(UsageFilter(start: now - 5 * 3600, end: now, appType: appType, model: model))
            weekly = try? store.rangeSummary(UsageFilter(start: now - 7 * 86400, end: now, appType: appType, model: model))

            // 菜单栏专用：今日（本日零点，与面板 Today 一致）+ 近 7 天 / 近 30 天（滚动窗口），全部来源。
            // 用滚动窗口而非日历「本周/本月」——否则月初时「本周」会跨回上月、反比「本月」多，违反「月≥周≥日」直觉。
            let dayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
            mbToday = try? store.rangeSummary(UsageFilter(start: dayStart, end: now))
            mbWeek  = try? store.rangeSummary(UsageFilter(start: now - 7 * 86400, end: now))
            mbMonth = try? store.rangeSummary(UsageFilter(start: now - 30 * 86400, end: now))

            // 官方额度：仅当有额度码片开启时才查（默认关 → 不读凭据、不联网）。
            // 走 QuotaCache（5 分钟节流 + stale-if-error），与 embed 的 get_quota 共享同一份缓存。
            // 仅当有「额度」码片开启时才查（默认关→不读凭据、不联网）。走 QuotaCache 5 分钟节流
            // + stale-if-error：限流(429)/失败时保留上次值，不会把接口打爆。
            if mbAnyQuotaOn {
                Task { [weak self] in
                    let tiers = await QuotaService.fetchTiersForBridge()
                    self?.quotaTiers = tiers
                }
            }
            error = nil
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            self.error = "\(error)"
        }
    }
}

// MARK: - 顶部工具栏

struct Toolbar: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var quota: QuotaService

    var body: some View {
        HStack(spacing: 10) {
            SourceSegmented(model: model)

            Menu {
                Button("All Sources") { model.appType = nil }
                ForEach(model.apps, id: \.self) { a in Button(a.capitalized) { model.appType = a } }
            } label: { pill(nil, model.appType?.capitalized ?? "All Sources") }

            Menu {
                Button("All Models") { model.model = nil }
                ForEach(model.models, id: \.self) { m in Button(m) { model.model = m } }
            } label: { pill(nil, model.model ?? "All Models") }

            Menu {
                ForEach(PanelModel.intervals, id: \.self) { s in
                    Button(s == 0 ? "关闭" : "\(s)s") { model.intervalSeconds = s }
                }
            } label: { pill("arrow.triangle.2.circlepath", model.intervalSeconds == 0 ? "关闭" : "\(model.intervalSeconds)s") }

            Menu {
                ForEach(DateRangePreset.allCases) { p in Button(p.rawValue) { model.range = p } }
            } label: { pill("calendar", model.range.rawValue) }

            Spacer()

            WindowBadge(label: "5H", tier: quota.fiveHour)
            WindowBadge(label: "Week", tier: quota.weekly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
    }

    private func pill(_ icon: String?, _ text: String) -> some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.textDim) }
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textMain).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textDim)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
        .fixedSize()
    }
}

/// 常驻用量窗口徽标：5H  87%  + 迷你进度条，按官方 utilization 阈值配色。
/// 数据源为 QuotaService 的真实额度（而非 token/占位额度）；tier == nil 时优雅降级显示 "—"。
struct WindowBadge: View {
    let label: String
    let tier: QuotaTier?

    /// 有真实数据时的已用百分比
    private var percent: Int? { tier.map { Int($0.utilization.rounded()) } }
    private var fraction: Double {
        guard let u = tier?.utilization else { return 0 }
        return min(1, max(0, u / 100))
    }
    /// 阈值配色，对齐 cc-switch SubscriptionQuotaFooter.utilizationColor
    /// （≥90 红 / ≥70 橙 / 否则 绿）；无数据用 textDim。
    private var color: Color {
        guard let p = percent else { return Theme.textDim }
        switch p {
        case 90...: return Theme.cost      // 红
        case 70...: return Theme.amber     // 橙
        default:    return Theme.emerald   // 绿
        }
    }

    /// 悬停提示：窗口含义 + 已用% + 重置倒计时 + 套餐
    private var helpText: String {
        guard let tier, let p = percent else {
            return "\(label)：暂无数据（未登录 Claude 或查询失败）"
        }
        var parts = ["\(label) 已用 \(p)%"]
        if let cd = tier.countdown { parts.append("重置于 \(cd)") }
        if let plan = tier.planLabel, !plan.isEmpty { parts.append(plan) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 7) {
            Text(label).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.textDim)
            Text(percent.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(color)
            Capsule().fill(Theme.track.opacity(0.6)).frame(width: 30, height: 4)
                .overlay(alignment: .leading) {
                    Capsule().fill(color).frame(width: 30 * fraction, height: 4)
                }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(Theme.card.opacity(0.6))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.track.opacity(0.5), lineWidth: 1))
        )
        .fixedSize()
        .help(helpText)
    }
}

/// 主窗口:真面板 WebView 边到边铺满整窗。
/// 5H/Week 额度徽标已下沉到 embed 面板工具栏内部（usage-embed.tsx，走原生 get_quota），
/// 原生不再叠加浮层 → 消除与工具栏的重叠、割裂，做到真正一体。
struct MainWindowView: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        ZStack(alignment: .top) {
            Theme.bg.ignoresSafeArea()
            PanelWebView().ignoresSafeArea()          // 真面板边到边铺满整窗
            WindowDragArea()                          // 顶部留白带原生拖拽区（隐藏标题栏后可拖窗口）
                .frame(maxWidth: .infinity).frame(height: 46)
                .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            model.start()            // 仍驱动菜单栏 / MenuBarPanel（额度前端自查，无需原生 QuotaService）
        }
    }
}

/// 来源(app)分段选择器：All + 各 app 图标
struct SourceSegmented: View {
    @ObservedObject var model: PanelModel
    var body: some View {
        HStack(spacing: 2) {
            seg(nil, "square.grid.2x2.fill", Theme.textDim)
            ForEach(model.apps, id: \.self) { a in seg(a, icon(a), color(a)) }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 1))
        )
    }
    private func seg(_ app: String?, _ sym: String, _ tint: Color) -> some View {
        let selected = model.appType == app
        return Button { model.appType = app } label: {
            Image(systemName: sym).font(.system(size: 14))
                .foregroundStyle(selected ? Theme.textMain : tint)
                .frame(width: 32, height: 26)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white.opacity(0.12) : .clear))
        }
        .buttonStyle(.plain)
    }
    private func icon(_ app: String) -> String {
        switch app {
        case "claude": return "asterisk"
        case "codex", "openai": return "circle.dashed"
        case "gemini": return "sparkles"
        case "opencode", "openclaw": return "square.fill"
        default: return "cube.fill"
        }
    }
    private func color(_ app: String) -> Color {
        switch app {
        case "claude": return Theme.creation
        case "gemini": return Theme.hit
        default: return Theme.textDim
        }
    }
}

// MARK: - 仪表盘（工具栏 + 面板）

struct DashboardView: View {
    @ObservedObject var model: PanelModel
    @StateObject private var quota = QuotaService()   // 官方订阅额度（真实 utilization%）

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(model: model, quota: quota)
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 2)

            if let snap = model.snap {
                PanelView(snap: snap, rangeLabel: model.range.rawValue, interactive: true)
            } else if let e = model.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("读取 cc-switch 数据失败").foregroundStyle(Theme.textMain)
                    Text(e).font(.caption2).foregroundStyle(Theme.textDim)
                }.frame(maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.large).frame(maxHeight: .infinity)
            }
        }
        .background(Theme.bg)
        .onAppear {
            model.start()
            quota.start()
        }
    }
}

// MARK: - 菜单栏常驻

struct MenuBarLabel: View {
    @ObservedObject var model: PanelModel

    /// 一个「按周期分组」的文本码片：同周期的 Tokens/花费 合成一段，如「D:1M·$0.1」。
    private struct Seg: Identifiable { let id: String; let text: String }

    private var segments: [Seg] {
        var segs: [Seg] = []
        // 每个开启的周期一段，前缀 D/W/M（Day/Week/Month）；同周期的 Tokens/花费 合并为 "D:1M·$0.1"。
        // 多选各自独立出现，如 D 用量 + W 用量 → "D:1M W:1M"。
        func add(_ letter: String, _ sum: UsageSummary?, _ tok: Bool, _ cost: Bool) {
            guard tok || cost, let s = sum else { return }
            var parts: [String] = []
            if tok  { parts.append(Fmt.tokens(s.tokensProcessed)) }
            if cost { parts.append(Fmt.cost(s.cost)) }
            guard !parts.isEmpty else { return }
            segs.append(Seg(id: letter, text: "\(letter): \(parts.joined(separator: "·"))"))
        }
        add("D", model.mbToday, model.mbTokToday, model.mbCostToday)
        add("W", model.mbWeek,  model.mbTokWeek,  model.mbCostWeek)
        add("M", model.mbMonth, model.mbTokMonth, model.mbCostMonth)
        return segs
    }

    private func tier(_ name: String) -> QuotaTier? { model.quotaTiers.first { $0.name == name } }

    private var isEmpty: Bool { segments.isEmpty && !model.mbAnyQuotaOn }

    var body: some View {
        // 菜单栏 label = bolt 兄弟 Image + 单个 Text（实测唯一可靠组合：兄弟 Image 能显示、
        // 单个 Text 不被截断；而多个并列 Text 会被截、SF Symbol 塞进 Text 又渲染成空白）。
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(labelString)
        }
        .onAppear { model.start() }
    }

    /// 整条内容拼成一个字符串：token 段（D:1M·$0.1）+ 额度段（5H:10% / Week:69%），空格分隔。
    private var labelString: String {
        var parts = segments.map { $0.text }
        if model.mbQuota5H   { parts.append(quotaStr("5H",   "five_hour")) }
        if model.mbQuotaWeek { parts.append(quotaStr("Week", "seven_day")) }
        return parts.isEmpty ? "CC" : parts.joined(separator: "  ")
    }

    private func quotaStr(_ label: String, _ name: String) -> String {
        let pct = tier(name).map { "\(Int($0.utilization.rounded()))%" } ?? "—"
        return "\(label): \(pct)"
    }
}

struct MenuBarPanel: View {
    @ObservedObject var model: PanelModel
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
                Text("CC Usage · \(model.range.rawValue)").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textMain)
                Spacer()
                Text(Fmt.relative(model.snap?.lastEventAt)).font(.caption2).foregroundStyle(Theme.textDim)
            }

            if let s = model.snap?.today {
                HStack(spacing: 10) {
                    stat("Tokens", Fmt.tokens(s.tokensProcessed), Theme.textMain)
                    stat("Cost", Fmt.cost(s.cost), Theme.output)
                    stat("Hit Rate", Fmt.percent(s.cacheHitRate), Theme.hit)
                }
            }
            if let snap = model.snap {
                TrendChart(buckets: snap.trend, showAxes: false, interactive: false)
                    .frame(height: 80)
            }

            Divider().overlay(Theme.track.opacity(0.5))

            DisclosureGroup(isExpanded: $showSettings) {
                MenuBarSettingsView(model: model).padding(.top, 8)
            } label: {
                // 整行(齿轮+文字+空白)都可点开合，不用非得戳小三角
                Label("Menu Bar Display", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textMain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation { showSettings.toggle() } }
            }
            .tint(Theme.textDim)

            HStack {
                Button {
                    // MenuBarExtra(.window) 的弹窗不会因 openWindow 自动收起：
                    // 点击瞬间它就是 key window，先记下，开完主窗后把它关掉。
                    // 高度>50 排除菜单栏 label 小窗；主窗不是 NSPanel 也不含
                    // MenuBarExtra 类名，不会被误关。
                    let popup = NSApp.keyWindow
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                    if let popup, popup.frame.height > 50,
                       popup.className.contains("MenuBarExtra") || popup is NSPanel {
                        popup.close()
                    }
                } label: { Text("Open Main Window") }
                Spacer()
                Text("Every \(model.intervalSeconds)s").font(.caption2).foregroundStyle(Theme.textDim)
            }
        }
        .padding(14)
        .frame(width: 340)
        .background(Theme.bg)
        .onAppear { model.start() }
    }

    private func stat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.textDim)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}

/// 菜单栏「显示设置」勾选面板：三组原生 checkbox，绑定 PanelModel 的 @Published 开关
/// （didSet 落盘 + 勾选额度即刻强制取数）。Tokens/Cost 各含 D·W·M，Quota 含 5H·Week。
struct MenuBarSettingsView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Tokens") {
                check("Day", $model.mbTokToday); check("Week", $model.mbTokWeek); check("Month", $model.mbTokMonth)
            }
            row("Cost") {
                check("Day", $model.mbCostToday); check("Week", $model.mbCostWeek); check("Month", $model.mbCostMonth)
            }
            row("Quota") {
                check("5H", $model.mbQuota5H); check("Week", $model.mbQuotaWeek)
            }
            Text("Menu bar shows D / W / M = Day / Week / Month. Quota is % used, e.g. 5H:10%.")
                .font(.caption2).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 56, alignment: .leading)
            HStack(spacing: 12) { content() }
            Spacer(minLength: 0)
        }
    }

    private func check(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(Theme.textMain)
    }
}
