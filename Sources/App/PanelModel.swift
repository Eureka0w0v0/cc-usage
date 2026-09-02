import SwiftUI
import WidgetKit
import Combine
import AppKit

// MARK: - 视图模型（含每 N 秒自动刷新）

@MainActor
final class PanelModel: ObservableObject {
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
    /// 额度码片画进度条（默认）还是写百分比数字。条更窄也更好扫，但精确值就看不到了，
    /// 是主观取舍 → 给个开关，不替用户拍板。
    @Published var mbQuotaBar: Bool  { didSet { persist(MBKey.quotaBar, mbQuotaBar) } }

    /// 按 AI 分组的码片选中集（"claude.tokens.today" / "codex.quota" …）。
    /// didSet 落盘 + 立即补一轮 reload，让新勾选的数字马上出现。
    @Published var mbAppChips: Set<String> {
        didSet {
            UserDefaults.standard.set(Array(mbAppChips).sorted(), forKey: MBKey.appChips)
            mbWidthCap = nil   // 勾选变化：解除上限，按新内容全宽重估
            growCeiling = .greatestFiniteMagnitude
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
    /// Antigravity 各模型配额快照（勾了 antigravity.quota.* 才扫描）。
    @Published var mbAntigravityQuota: [AntigravityQuota.Model] = []

    /// 菜单栏宽度上限：nil = 全宽（默认）。原则：**有空间就绝不截断**——只在状态项此刻
    /// 真被 macOS 挤掉时按溢出量精确收缩；内容变短到能放下就立刻解除上限。不做持久化、
    /// 不做跨 app 记忆（那会用陈旧的窄上限截断新的短内容——正是之前的 bug）。
    @Published var mbWidthCap: CGFloat? = nil
    // 宽度 governor 的状态：读写都在 MenuBarWidthGovernor.swift 的 extension 里，故不能 private。
    var lastNatural: CGFloat = 0           // 上次巡检时的自然宽度，用于识别"内容结构变了"
    var growCeiling: CGFloat = .greatestFiniteMagnitude  // 增长天花板 = 上次被挤的宽度，防边界震荡
    var hiddenTicks = 0                     // 连续不可见计数：≥2 才算真被挤，滤面板开合毛刺
    var growTicks = 0                        // 可见但仍截断的连续计数：≥2 才尝试夺回空间
    private var visTimer: AnyCancellable?
    weak var statusWindow: NSWindow?     // 状态项窗口（长命），找到一次就留着
    var panelWindowClass: AnyClass?      // 面板窗口的类对象，比对指针即可，免去每秒建串

    var mbAnyQuotaOn: Bool { mbQuota5H || mbQuotaWeek }
    private func persist(_ key: String, _ val: Bool) {
        UserDefaults.standard.set(val, forKey: key)
    }

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
        mbQuotaBar  = load(MBKey.quotaBar,   true)
        mbAppChips  = Set(d.stringArray(forKey: MBKey.appChips) ?? [])
        Self.migrateLegacyDefaults(d, chips: &mbAppChips)
        // embed 面板持久化的刷新间隔（ms，set_setting 写入）：启动时接管为全局节奏，
        // 菜单栏与面板从第一秒起就一致。没存过则维持默认 5s。
        if let ms = d.object(forKey: EmbedKey.refreshIntervalMs) as? Int {
            intervalSeconds = max(0, ms / 1000)
        }
    }

    /// 旧版遗留 UserDefaults 的一次性清理 / 键迁移（启动即跑，幂等）。
    private static func migrateLegacyDefaults(_ d: UserDefaults, chips: inout Set<String>) {
        // v1.4 改纯反应式后零引用的宽度记忆：按 app 分桶的容量边界（mb.ctxBounds）与
        // v1.3 的安全宽度（mb.maxSafeWidth / mb.squeezeWidth）——陈旧的窄上限会错误截断新内容
        for legacy in ["mb.ctxBounds", "mb.maxSafeWidth", "mb.squeezeWidth"] { d.removeObject(forKey: legacy) }
        // Codex 周窗口标签 W → 7D（W 让位给「本周用量」），码片 key 跟着变，别丢勾选
        if chips.remove("codex.quota.W") != nil {
            chips.insert("codex.quota.7D")
            d.set(Array(chips).sorted(), forKey: MBKey.appChips)
        }
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
        if mbAppChips.contains(where: { $0.hasPrefix("antigravity.quota.") }) { refreshAntigravityNow() }
        updater.start()
        // 状态项可见性巡检：被挤掉后 2s 内一步压回安全宽度
        visTimer = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.checkStatusItemVisibility() }
        // 屏幕变化：可用空间真的变了，解除上限重新按全宽评估（有空间就别截断）。
        let clearCap: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in
                self?.mbWidthCap = nil
                self?.growCeiling = .greatestFiniteMagnitude
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { _ in clearCap() }
        // 前台 app 变化：菜单栏可用空间可能被让出来了，值得重新争取——但只抬天花板，
        // 不动 mbWidthCap。清掉 cap 会让 label 立刻回全宽、随即被挤掉，而恢复要等
        // checkStatusItemVisibility 攒够 hiddenTicks（1Hz 巡检）→ 每切一次 app 就隐身
        // 两秒多。夺回空间交给 checkStatusItemVisibility 的增长分支即可，全程不失可见。
        let raiseCeiling: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.growCeiling = .greatestFiniteMagnitude }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { _ in raiseCeiling() }
    }

    /// 立即强制取一次官方额度（绕过 5 分钟节流），用于用户在菜单栏勾选「额度」码片时的即时反馈。
    func refreshQuotaNow() {
        Task { [weak self] in
            let tiers = await QuotaService.forceTiersForBridge()
            self?.quotaTiers = tiers
        }
    }

    /// 联网取 Antigravity 各模型实时配额（30s actor 内节流）。设置面板展开或勾选时触发。
    private var antigravityFetching = false
    func refreshAntigravityNow() {
        guard !antigravityFetching else { return }
        antigravityFetching = true
        Task { [weak self] in
            let models = await AntigravityQuota.shared.latest()
            await MainActor.run {
                guard let self else { return }
                self.mbAntigravityQuota = models
                self.antigravityFetching = false
            }
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
        // Codex 窗口列表：勾了码片要用，设置面板展开 Codex 分组也要用（得先有列表才能给出勾选项）。
        // 扫描本身是主线程碰不得的活（~/.codex/sessions 递归枚举 + 尾读），一律在这条后台链上做。
        let wantCodex = chips.contains { $0.hasPrefix("codex.quota.") }
            || UserDefaults.standard.bool(forKey: MBKey.groupCodex)

        Task { [weak self] in
            let out = await Task.detached(priority: .userInitiated) { () -> ReloadOutput in
                var o = ReloadOutput()
                do {
                    // 缺省 filter = 本地今日零点 → now（resolvedFilter），全部来源/模型——
                    // 与菜单栏「今日」完全同口径，snap.today 直接复用，不再单独多算一次。
                    // 菜单栏只读 today/trend/lastEventAt，累计值拿了就扔 → 跳过那次全库聚合。
                    o.snap = try store.snapshot(filter: UsageFilter(), includeCumulative: false)
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
                    // codex.quota.<窗口标签>（如 codex.quota.5H / codex.quota.30D）
                    if wantCodex { o.codexWindows = CodexQuota.latest() }
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
                // Antigravity 走联网查询（OAuth + Google API），独立 Task 不阻塞 reload；
                // 有勾选或设置面板需要列表时才发起。
                if self.mbAppChips.contains(where: { $0.hasPrefix("antigravity.quota.") }) {
                    self.refreshAntigravityNow()
                }
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
