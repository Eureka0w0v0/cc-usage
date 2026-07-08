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
    /// 0 = 面板关闭自动刷新（菜单栏仍按 menuBarFallbackSeconds 兜底节奏更新）。
    @Published var intervalSeconds: Int = 5 { didSet { restartTimer() } }

    /// 面板选 off 时菜单栏的兜底节奏：面板可以不刷，常驻的菜单栏数字/额度不能永远冻结。
    static let menuBarFallbackSeconds = 60

    private var timer: AnyCancellable?
    private let store = UsageStore()
    private var started = false
    private var isReloading = false
    private var pendingReload = false

    func start() {
        guard !started else { return }
        started = true
        let store = self.store
        Task { [weak self] in
            // 首次打库也放后台（与 reload 同理），结果回主线程发布
            let lists = await Task.detached(priority: .utility) {
                (store.distinctAppTypes(), store.distinctModels())
            }.value
            guard let self else { return }
            (self.apps, self.models) = lists
        }
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
        // 面板选 off 时不再停摆，降到兜底节奏——菜单栏数字/额度码片继续呼吸
        let period = intervalSeconds > 0 ? intervalSeconds : Self.menuBarFallbackSeconds
        timer = Timer.publish(every: Double(period), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.reload() }
    }

    /// 一次后台 reload 的产出（值类型，跨线程安全）。
    private struct ReloadOutput: Sendable {
        var snap: UsageSnapshot?
        var today: UsageSummary?
        var week: UsageSummary?
        var month: UsageSummary?
        var errorText: String?
    }

    func reload() {
        // 全部 SQL + 会话 JSONL 扫描下放后台：冷启动的 overlay 全量扫可达秒级，
        // 不能卡主线程。在途时只记一笔待办、完成后立即补一轮——筛选切换不会被吞。
        if isReloading { pendingReload = true; return }
        isReloading = true

        let (s, e) = range.bounds()
        let filter = UsageFilter(start: s, end: e, appType: appType, model: model)
        let store = self.store

        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { () -> ReloadOutput in
                var o = ReloadOutput()
                do {
                    o.snap = try store.snapshot(filter: filter)
                    // 菜单栏专用：今日（本日零点，与面板 Today 一致）+ 近 7 天 / 近 30 天（滚动窗口），全部来源。
                    // 用滚动窗口而非日历「本周/本月」——否则月初时「本周」会跨回上月、反比「本月」多，违反「月≥周≥日」直觉。
                    let now = Int64(Date().timeIntervalSince1970)
                    let dayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
                    o.today = try? store.rangeSummary(UsageFilter(start: dayStart, end: now))
                    o.week  = try? store.rangeSummary(UsageFilter(start: now - 7 * 86400, end: now))
                    o.month = try? store.rangeSummary(UsageFilter(start: now - 30 * 86400, end: now))
                } catch {
                    o.errorText = "\(error)"
                }
                return o
            }.value

            guard let self else { return }
            if let err = out.errorText {
                self.error = err
            } else {
                self.snap = out.snap
                self.mbToday = out.today
                self.mbWeek = out.week
                self.mbMonth = out.month
                self.error = nil
                self.reloadWidgetsThrottled()
                // 官方额度：仅当有额度码片开启时才查（默认关 → 不读凭据、不联网）。
                // 走 QuotaCache（5 分钟节流 + stale-if-error），与 embed 的 get_quota 共享同一份
                // 缓存；限流(429)/失败时保留上次值，不会把接口打爆。独立 Task：网络耗时不阻塞下轮 reload。
                if self.mbAnyQuotaOn {
                    Task { [weak self] in
                        let tiers = await QuotaService.fetchTiersForBridge()
                        self?.quotaTiers = tiers
                    }
                }
            }
            self.isReloading = false
            if self.pendingReload { self.pendingReload = false; self.reload() }
        }
    }

    // WidgetKit 有系统刷新预算，跟着 reload() 每 5s 打一次会被系统直接限流忽略；
    // 桌面小组件自身的时间线是 15 分钟，这里 5 分钟提醒一次绰绰有余。
    private var lastWidgetReload: Date?
    private func reloadWidgetsThrottled() {
        let now = Date()
        if let last = lastWidgetReload, now.timeIntervalSince(last) < 5 * 60 { return }
        lastWidgetReload = now
        WidgetCenter.shared.reloadAllTimelines()
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

    /// 状态项宽度锁：只增不减（本次运行内）。SwiftUI MenuBarExtra 的已知毛病——
    /// label 运行中变窄（如取消勾选码片）时，状态项会被系统整个隐藏，变宽才恢复。
    /// 锁住最大已见宽度后，取消勾选只是右侧留白、绝不收窄 → 不再触发隐藏；
    /// 重启后按当前勾选恢复精确宽度。
    @State private var lockedWidth: CGFloat = 0

    var body: some View {
        // 菜单栏 label = bolt 兄弟 Image + 单个 Text（实测唯一可靠组合：兄弟 Image 能显示、
        // 单个 Text 不被截断；而多个并列 Text 会被截、SF Symbol 塞进 Text 又渲染成空白）。
        HStack(spacing: 4) {
            Image(systemName: "bolt.fill")
            Text(labelString)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { lockedWidth = max(lockedWidth, geo.size.width) }
                    .onChange(of: geo.size.width) { _, w in lockedWidth = max(lockedWidth, w) }
            }
        )
        .frame(minWidth: lockedWidth, alignment: .leading)
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
            // 数据层出错时给出可见降级（比如 cc-switch.db 不存在）——否则面板一片空、无从排查
            if let err = model.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                    Text(err).font(.caption2).foregroundStyle(Theme.textDim)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
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
                Text(model.intervalSeconds == 0
                     ? "Panel refresh off · menu bar \(PanelModel.menuBarFallbackSeconds)s"
                     : "Every \(model.intervalSeconds)s")
                    .font(.caption2).foregroundStyle(Theme.textDim)
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
