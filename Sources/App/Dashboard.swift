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
    static let icon      = "mb.icon"        // 菜单栏 ⚡ 图标开关（默认开）
    static let appChips  = "mb.appChips"    // 按 AI 分组的码片选中集（字符串数组）
}

/// 菜单栏可分组展示的 AI 来源。All（全部合计）不在此枚举里——它就是 MBKey 那组旧开关。
/// 码片 key 格式 "\(rawValue).tokens.today" / "\(rawValue).cost.week" / "codex.quota"。
enum MBApp: String, CaseIterable {
    case claude, codex, gemini, opencode
    var title: String {
        switch self {
        case .claude: return "Claude"; case .codex: return "Codex"
        case .gemini: return "Gemini"; case .opencode: return "OpenCode"
        }
    }
    /// 品牌模板图标（Resources 里的黑色 alpha PNG，菜单栏段前缀与设置分组标题共用）。
    var iconAsset: String {
        switch self {
        case .claude: return "brand-claude"; case .codex: return "brand-openai"
        case .gemini: return "brand-gemini"; case .opencode: return "brand-opencode"
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
    /// 菜单栏 ⚡ 图标开关。全关 + 码片全空时 label 会兜底显示 "CC"，状态项不会隐身。
    @Published var mbShowIcon: Bool  { didSet { persist(MBKey.icon, mbShowIcon) } }

    /// 按 AI 分组的码片选中集（"claude.tokens.today" / "codex.quota" …）。
    /// didSet 落盘 + 立即补一轮 reload，让新勾选的数字马上出现。
    @Published var mbAppChips: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(mbAppChips).sorted(), forKey: MBKey.appChips)
            if started { reload() }
        }
    }

    /// 单个 AI 的 D/W/M 汇总（只算勾了码片的 app，reload 时装配）。
    struct AppPeriods: Sendable {
        var today: UsageSummary?
        var week: UsageSummary?
        var month: UsageSummary?
    }
    @Published var mbAppSummaries: [String: AppPeriods] = [:]
    /// Codex 限额窗口快照（勾了 codex.quota 才扫描）。
    @Published var mbCodexQuota: [CodexQuota.Window] = []

    var mbAnyQuotaOn: Bool { mbQuota5H || mbQuotaWeek }
    private func persist(_ key: String, _ val: Bool) { UserDefaults.standard.set(val, forKey: key) }

    func chipOn(_ key: String) -> Bool { mbAppChips.contains(key) }
    /// 设置面板 checkbox 的绑定入口（Set 成员 ↔ Toggle）。
    func chipBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { [weak self] in self?.mbAppChips.contains(key) ?? false },
            set: { [weak self] on in
                guard let self else { return }
                if on { self.mbAppChips.insert(key) } else { self.mbAppChips.remove(key) }
            }
        )
    }

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
        mbShowIcon  = load(MBKey.icon,      true)
        mbAppChips  = Set(d.stringArray(forKey: MBKey.appChips) ?? [])
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

    /// 0 = 面板关闭自动刷新（菜单栏仍按 menuBarFallbackSeconds 兜底节奏更新）。
    @Published var intervalSeconds: Int = 5 { didSet { restartTimer() } }

    /// 面板选 off 时菜单栏的兜底节奏：面板可以不刷，常驻的菜单栏数字/额度不能永远冻结。
    static let menuBarFallbackSeconds = 60

    /// GitHub Releases 新版本检查（菜单栏提示行 / 主窗徽标共用，子视图直接观察它）。
    let updater = UpdateChecker()

    private var timer: AnyCancellable?
    private let store = UsageStore()
    private var started = false
    private var isReloading = false
    private var pendingReload = false

    func start() {
        guard !started else { return }
        started = true
        reload()
        restartTimer()
        if mbAnyQuotaOn { refreshQuotaNow() }   // 启动时若已开启额度码片，立即取一次
        updater.start()
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
        var appSummaries: [String: AppPeriods] = [:]
        var codexWindows: [CodexQuota.Window] = []
        var errorText: String?
    }

    func reload() {
        // 全部 SQL + 会话 JSONL 扫描下放后台：冷启动的 overlay 全量扫可达秒级，
        // 不能卡主线程。在途时只记一笔待办、完成后立即补一轮——刷新不会被吞。
        if isReloading { pendingReload = true; return }
        isReloading = true

        let store = self.store
        let chips = mbAppChips   // 值拷贝进后台闭包，避免在途中被设置面板改动

        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { () -> ReloadOutput in
                var o = ReloadOutput()
                do {
                    // 缺省 filter = 本地今日零点 → now（resolvedFilter），全部来源/模型——
                    // 与菜单栏「今日」完全同口径，snap.today 直接复用，不再单独多算一次。
                    o.snap = try store.snapshot(filter: UsageFilter())
                    o.today = o.snap?.today
                    // 菜单栏 W/M：近 7 天 / 近 30 天（滚动窗口），全部来源。
                    // 用滚动窗口而非日历「本周/本月」——否则月初时「本周」会跨回上月、反比「本月」多，违反「月≥周≥日」直觉。
                    let now = Int64(Date().timeIntervalSince1970)
                    o.week  = try? store.rangeSummary(UsageFilter(start: now - 7 * 86400, end: now))
                    o.month = try? store.rangeSummary(UsageFilter(start: now - 30 * 86400, end: now))
                    // 按 AI 分组的码片：只查勾了的 (app, 周期)，避免白白多跑 SQL
                    let dayStart = Int64(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970)
                    for app in MBApp.allCases.map(\.rawValue) {
                        func need(_ p: String) -> Bool {
                            chips.contains("\(app).tokens.\(p)") || chips.contains("\(app).cost.\(p)")
                        }
                        guard need("today") || need("week") || need("month") else { continue }
                        var s = AppPeriods()
                        if need("today") { s.today = try? store.rangeSummary(UsageFilter(start: dayStart, end: now, appType: app)) }
                        if need("week")  { s.week  = try? store.rangeSummary(UsageFilter(start: now - 7 * 86400, end: now, appType: app)) }
                        if need("month") { s.month = try? store.rangeSummary(UsageFilter(start: now - 30 * 86400, end: now, appType: app)) }
                        o.appSummaries[app] = s
                    }
                    // codex.quota.<窗口标签>（如 codex.quota.5H / codex.quota.30D），任一勾选即扫描
                    if chips.contains(where: { $0.hasPrefix("codex.quota.") }) {
                        o.codexWindows = CodexQuota.latest()
                    }
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
                self.mbAppSummaries = out.appSummaries
                self.mbCodexQuota = out.codexWindows
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
            // 新版本徽标：贴在拖拽区右端，不遮 embed 工具栏（工具栏内容从 46pt 以下开始）
            UpdateNotice(updater: model.updater, compact: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14).padding(.top, 12)
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

    /// 状态项宽度锁：只增不减（本次运行内）。SwiftUI MenuBarExtra 的已知毛病——
    /// label 运行中变窄（如取消勾选码片）时，状态项会被系统整个隐藏，变宽才恢复。
    /// 锁住最大已见宽度后，取消勾选只是右侧留白、绝不收窄 → 不再触发隐藏；
    /// 重启后按当前勾选恢复精确宽度。
    @State private var lockedWidth: CGFloat = 0

    var body: some View {
        // 整条 label 合成为单张模板 NSImage。MenuBarExtra label 实测只有「单 Image」
        // 「Image+单 Text」可靠——多段 Text 会被截断、SF Symbol 塞 Text 渲染空白；
        // 品牌图标要与文本交错，只能整体合成单图，isTemplate 让明暗/失焦自动着色。
        Image(nsImage: composite)
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

    /// 一段菜单栏内容：品牌图标 + 该 AI 的文本。All 段无图标（⚡ 就是本应用标识）。
    private struct Piece { let icon: String?; let text: String }

    private var pieces: [Piece] {
        var out: [Piece] = []
        let all = segments.map(\.text).joined(separator: "  ")
        if !all.isEmpty { out.append(Piece(icon: nil, text: all)) }
        for app in MBApp.allCases {
            let a = app.rawValue
            let sums = model.mbAppSummaries[a]
            var segs: [String] = []
            func add(_ letter: String, _ s: UsageSummary?, _ tokKey: String, _ costKey: String) {
                let tok = model.chipOn(tokKey), cost = model.chipOn(costKey)
                guard tok || cost, let s else { return }
                var p: [String] = []
                if tok  { p.append(Fmt.tokens(s.tokensProcessed)) }
                if cost { p.append(Fmt.cost(s.cost)) }
                segs.append("\(letter): \(p.joined(separator: "·"))")
            }
            add("D", sums?.today, "\(a).tokens.today", "\(a).cost.today")
            add("W", sums?.week,  "\(a).tokens.week",  "\(a).cost.week")
            add("M", sums?.month, "\(a).tokens.month", "\(a).cost.month")
            // 额度段跟在所属 AI 段内：Claude 走官方接口两档，Codex 走本地快照（窗口自适应）
            if app == .claude {
                if model.mbQuota5H   { segs.append(quotaStr("5H", "five_hour")) }
                if model.mbQuotaWeek { segs.append(quotaStr("W",  "seven_day")) }
            }
            if app == .codex {
                let anyOn = model.mbAppChips.contains { $0.hasPrefix("codex.quota.") }
                let sel = model.mbCodexQuota.filter { model.chipOn("codex.quota.\($0.label)") }
                if anyOn && model.mbCodexQuota.isEmpty {
                    segs.append("—")   // 勾了但没扫到快照（没装 Codex / 会话被清）
                } else {
                    segs.append(contentsOf: sel.map { "\($0.label): \(Int($0.usedPercent.rounded()))%" })
                }
            }
            if !segs.isEmpty { out.append(Piece(icon: app.iconAsset, text: segs.joined(separator: " "))) }
        }
        return out
    }

    /// pieces → 单张黑色模板图：⚡（可关）+ [All 文本] + [品牌图标 文本]…，空段兜底 "CC"。
    private var composite: NSImage {
        let font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let str = NSMutableAttributedString()
        func appendIcon(_ img: NSImage) {
            let h: CGFloat = 14
            let w = img.size.height > 0 ? img.size.width / img.size.height * h : h
            let att = NSTextAttachment()
            att.image = img
            att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
            str.append(NSAttributedString(attachment: att))
            str.append(NSAttributedString(string: " ", attributes: attrs))
        }
        if model.mbShowIcon,
           let bolt = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
               .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            appendIcon(bolt)
        }
        let ps = pieces
        if ps.isEmpty {
            str.append(NSAttributedString(string: "CC", attributes: attrs))
        } else {
            for p in ps {
                if str.length > 0 { str.append(NSAttributedString(string: "  ", attributes: attrs)) }
                if let name = p.icon, let img = NSImage(named: name) { appendIcon(img) }
                str.append(NSAttributedString(string: p.text, attributes: attrs))
            }
        }
        let bounds = str.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let img = NSImage(size: NSSize(width: ceil(bounds.width) + 1, height: 18), flipped: false) { rect in
            str.draw(with: NSRect(x: 0, y: (rect.height - bounds.height) / 2 - bounds.minY,
                                  width: bounds.width, height: bounds.height),
                     options: [.usesLineFragmentOrigin])
            return true
        }
        img.isTemplate = true
        return img
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
                Text("CC Usage · Today").font(.system(size: 13, weight: .semibold))
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

            UpdateNotice(updater: model.updater)

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

/// 菜单栏「显示设置」：按 AI 分组的手风琴。All = 全部 AI 合计（旧 Tokens/Cost 语义不变），
/// Claude/Codex/Gemini/OpenCode 各自展开选该 AI 的 Tokens/Cost，有配额数据的 AI 多一行 Quota
/// （Claude = 官方接口 5H/Week，Codex = 本地会话快照、窗口自适应）。折叠状态持久化，默认只展开 All。
struct MenuBarSettingsView: View {
    @ObservedObject var model: PanelModel
    @AppStorage("mb.group.all")      private var expAll = true
    @AppStorage("mb.group.claude")   private var expClaude = false
    @AppStorage("mb.group.codex")    private var expCodex = false
    @AppStorage("mb.group.gemini")   private var expGemini = false
    @AppStorage("mb.group.opencode") private var expOpencode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show ⚡ icon in menu bar", isOn: $model.mbShowIcon)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.textMain)

            group("All", $expAll) {
                row("Tokens") {
                    check("Day", $model.mbTokToday); check("Week", $model.mbTokWeek); check("Month", $model.mbTokMonth)
                }
                row("Cost") {
                    check("Day", $model.mbCostToday); check("Week", $model.mbCostWeek); check("Month", $model.mbCostMonth)
                }
            }
            group("Claude", $expClaude, icon: MBApp.claude.iconAsset) {
                appRows(.claude)
                row("Quota") { check("5H", $model.mbQuota5H); check("Week", $model.mbQuotaWeek) }
            }
            group("Codex", $expCodex, icon: MBApp.codex.iconAsset) {
                appRows(.codex)
                // 逐窗口勾选，交互与 Claude 对齐；窗口从本地快照发现（Plus=5H+Week，Free=30D）
                row("Quota") {
                    let windows = CodexQuota.latest()
                    if windows.isEmpty {
                        noQuota("No Codex data")
                    } else {
                        ForEach(windows, id: \.label) { w in
                            check(w.label == "W" ? "Week" : w.label,
                                  model.chipBinding("codex.quota.\(w.label)"))
                        }
                    }
                }
            }
            // Gemini 按天限请求数且不落盘、OpenCode 配额归背后 provider——都没有配额窗口可显示，
            // Quota 行保留占位并如实标注，五个组结构对齐
            group("Gemini", $expGemini, icon: MBApp.gemini.iconAsset) {
                appRows(.gemini)
                row("Quota") { noQuota("No quota API") }
            }
            group("OpenCode", $expOpencode, icon: MBApp.opencode.iconAsset) {
                appRows(.opencode)
                row("Quota") { noQuota("No quota API") }
            }

            Text("All = every AI combined. Prefixes: C=Claude, X=Codex, G=Gemini, O=OpenCode; D/W/M = Day/Week/Month. Quota is % used.")
                .font(.caption2).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 单个 AI 的 Tokens/Cost 两行（D/W/M 勾选走 chipBinding，落盘 + 即时补数）。
    @ViewBuilder private func appRows(_ app: MBApp) -> some View {
        let a = app.rawValue
        row("Tokens") {
            check("Day",   model.chipBinding("\(a).tokens.today"))
            check("Week",  model.chipBinding("\(a).tokens.week"))
            check("Month", model.chipBinding("\(a).tokens.month"))
        }
        row("Cost") {
            check("Day",   model.chipBinding("\(a).cost.today"))
            check("Week",  model.chipBinding("\(a).cost.week"))
            check("Month", model.chipBinding("\(a).cost.month"))
        }
    }

    /// 一个可折叠的 AI 区块：品牌图标 + 标题，整行可点开合（与外层 Menu Bar Display 同交互）。
    private func group<C: View>(_ title: String, _ expanded: Binding<Bool>, icon: String? = nil,
                                @ViewBuilder _ content: () -> C) -> some View {
        let inner = content()   // 立即求值：DisclosureGroup 的内容闭包是逃逸的，参数默认非逃逸
        return DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 8) { inner }
                .padding(.top, 6).padding(.leading, 2)
        } label: {
            HStack(spacing: 5) {
                if let icon, let img = NSImage(named: icon) {
                    Image(nsImage: img).renderingMode(.template)
                        .resizable().scaledToFit().frame(width: 13, height: 13)
                        .foregroundStyle(Theme.textMain)
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textMain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation { expanded.wrappedValue.toggle() } }
        }
        .tint(Theme.textDim)
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

    /// Quota 行的灰色占位说明（该 AI 无配额数据源时）。
    private func noQuota(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textDim)
    }
}
