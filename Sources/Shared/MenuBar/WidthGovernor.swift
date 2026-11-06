import CoreGraphics

/// 菜单栏状态项宽度的状态机。纯逻辑：输入一拍观测，输出新状态；窗口、CGWindowList、系统通知这些观测在
/// App 的 MenuBarWidthGovernor.swift 里采集。
///
/// 原则：**有空间就绝不截断**——只在状态项此刻真被 macOS 挤掉时按溢出量精确收缩，内容变短到能放下就立刻解除
/// 上限。不做持久化、不做跨 app 记忆（那会用陈旧的窄上限截断新的短内容）。
///
/// 三种宽度状态：
///
///       ┌───────────── 放得下 / reset ──────────────┐
///       ▼                                            │
///     full ──被挤──▶ pinned ◀──试过了（长一点或没空位）── reclaiming
///                     │  ▲                                ▲
///                     │  └───────────被挤───────────────── │
///                     └──切前台 app / 内容结构变了──────────┘
///
/// macOS 26.6 实测的教训（v1.9.3）：「不可见」≠ 被挤。App 全屏、锁屏、屏保、息屏时状态项同样不可见，窗口纹丝
/// 不动；旧版当成被挤，每 2s 砍 48pt 砍到 80pt，就是「label 缩进去再慢慢展开」的根源。所以先分遮蔽还是被挤，
/// 遮蔽期间宽度一根手指都不动。判据见 squeezeIfPushedOut。
struct WidthGovernor {
    enum Width: Equatable {
        /// 全宽：没有上限（默认）。
        case full
        /// 有上限，刚被挤过或试过没空位：空间没变就别去撞。普通屏量不到空位，只能等下次抬起；
        /// 刘海屏每 pinnedRemeasureTicks 拍无痛重量一次（量不会隐身，挤我们的东西走了就长回来）。
        case pinned(cap: CGFloat)
        /// 有上限，天花板抬起过（切了前台 app / 内容结构变了）：下一个看得见的拍试着夺回空间。
        case reclaiming(cap: CGFloat)

        var cap: CGFloat? {
            switch self {
            case .full: return nil
            case .pinned(let cap), .reclaiming(let cap): return cap
            }
        }
    }

    /// 这一拍看到的状态项。
    enum Sighting {
        /// 看得见。量空位要跑 CGWindowList，只在真要夺回空间时才调。
        case visible(hasNotch: () -> Bool, measureFree: () -> CGFloat?)
        /// 不可见。条带快照量不到时为 nil。
        case hidden(MenuBarStrip.Scan?)
    }

    enum Release: Equatable {
        case contentFits(cap: CGFloat)
        case roomFits(free: CGFloat, natural: CGFloat)
        case probeFullWidth
    }

    /// 这一拍发生的变化（调用方拿去写日志）。
    enum Change: Equatable {
        case squeezed(from: CGFloat, to: CGFloat, free: CGFloat?, items: Int)
        case grew(from: CGFloat, to: CGFloat, free: CGFloat)
        case released(Release)
        case concealCleared
    }

    /// 再窄就只剩 ⚡ 了；压到这里还放不下就只能等空间回来。
    static let minCap: CGFloat = 80
    /// 状态项窗口比合成图宽 16pt（左右各 8 内边距），composite 又把图宽压到 cap-12 → 窗口 ≈ cap+4。
    /// 空位减掉这个余量得到的 cap 才保证放得下；多留 12pt 吃掉 notchGap 的估算误差（30~42）。
    static let fitMargin: CGFloat = 16
    /// 量出来的空位不比现在窄时（布局还在路上）一次收多少。
    static let squeezeStep: CGFloat = 48
    /// 连续几拍不可见才算真被挤，滤面板开合毛刺。
    static let squeezeTicks = 2
    /// 刘海屏钉住后隔几拍重量一次（1Hz 巡检，即 30 秒）。
    static let pinnedRemeasureTicks = 30
    /// 自然宽度跳变超过它算内容结构变了（增删码片 / AI 段）；等宽数字下单纯的数字变化到不了这么大。
    static let structureJump: CGFloat = 30
    /// 自然宽度比 cap 只多这么点时算放得下。
    static let fitSlack: CGFloat = 6

    private(set) var width: Width = .full
    /// 锁屏 / 屏保 / 息屏 / 睡眠：非空 = 遮蔽中，不可见不算被挤。
    private(set) var concealReasons: Set<String> = []
    /// 连续不可见的拍数。
    private(set) var hiddenTicks = 0
    private var pinnedTicks = 0
    /// 上次巡检时的自然宽度，用于识别内容结构变了。
    private var lastNatural: CGFloat = 0

    var cap: CGFloat? { width.cap }

    /// 一拍。natural = 内容未截断的自然宽度，windowWidth = 状态项窗口当前宽度。
    mutating func tick(natural: CGFloat, windowWidth: CGFloat, _ sighting: Sighting) -> [Change] {
        if abs(natural - lastNatural) > Self.structureJump { raiseCeiling() }
        lastNatural = natural
        switch sighting {
        case .visible(let hasNotch, let measureFree):
            hiddenTicks = 0
            // 看得见就绝不是遮蔽中：某个「结束」通知漏掉也不至于让 governor 永久失灵
            let cleared: [Change] = concealReasons.isEmpty ? [] : [.concealCleared]
            concealReasons = []
            return cleared + reclaim(natural: natural, hasNotch: hasNotch, measureFree: measureFree)
        case .hidden(let scan):
            return squeezeIfPushedOut(scan, windowWidth: windowWidth)
        }
    }

    /// 切了前台 app：菜单栏可用空间可能被让出来了，值得重新争取——但只抬天花板，不动 cap。清掉 cap 会让 label
    /// 立刻回全宽、随即被挤掉，而恢复要攒够 squeezeTicks，每切一次 app 就隐身两秒多。
    mutating func raiseCeiling() {
        if case .pinned(let cap) = width { width = .reclaiming(cap: cap) }
    }

    /// 勾选变化、屏幕变化：解除上限，按新内容全宽重估（有空间就别截断）。
    mutating func reset() {
        width = .full
    }

    /// 返回遮蔽原因有没有变。
    @discardableResult
    mutating func setConcealed(_ reasons: Set<String>) -> Bool {
        guard reasons != concealReasons else { return false }
        concealReasons = reasons
        return true
    }

    /// 不可见：先排除遮蔽。被挤时整条菜单栏都在（别的状态项在屏幕上）、唯独我们不在；全屏 / 自动隐藏时所有
    /// 状态项都不在屏幕上；锁屏 / 屏保 / 息屏 / 睡眠由系统通知维护 concealReasons。
    private mutating func squeezeIfPushedOut(_ scan: MenuBarStrip.Scan?, windowWidth: CGFloat) -> [Change] {
        guard concealReasons.isEmpty, let scan, scan.itemsOnScreen > 0, !scan.covered else {
            hiddenTicks = 0
            return []
        }
        hiddenTicks += 1
        guard hiddenTicks >= Self.squeezeTicks else { return [] }
        hiddenTicks = 0                                   // 收缩后重新计数，给渲染生效留时间
        let current = cap ?? windowWidth
        // 刘海屏：空位实测，一步到位；量出来不比现在窄（布局还在路上）→ 按步长收。
        // 普通屏量不到时按 0 算，直接落到 minCap（f5e5332 的说明写的是步进，代码一直是这样）。
        var next = scan.freeLeft.map { $0 - Self.fitMargin } ?? 0
        if next >= current { next = current - Self.squeezeStep }
        next = max(Self.minCap, next)
        guard next < current else { return [] }           // 已在下限，只能等空间回来
        width = .pinned(cap: next)                        // 别再涨回刚被挤的宽度，防边界震荡
        return [.squeezed(from: current, to: next, free: scan.freeLeft, items: scan.itemsOnScreen)]
    }

    /// 可见但有上限时夺回空间：内容放得下 → 直接解除；仍截断则在 reclaiming 时试一次——刘海屏量出空位只涨到
    /// 刚好、绝不撞隐身；普通屏量不到，直接回全宽，放不下会被精确压回。
    private mutating func reclaim(natural: CGFloat, hasNotch: () -> Bool,
                                  measureFree: () -> CGFloat?) -> [Change] {
        guard let cap else {
            pinnedTicks = 0                               // 全宽显示中，无需动作
            return []
        }
        if natural <= cap + Self.fitSlack { return release(.contentFits(cap: cap)) }
        if case .pinned = width {
            pinnedTicks += 1
            guard pinnedTicks >= Self.pinnedRemeasureTicks, hasNotch() else { return [] }
        }
        pinnedTicks = 0
        guard let free = measureFree() else { return release(.probeFullWidth) }
        let target = min(natural, cap + free - Self.fitMargin)
        if target >= natural { return release(.roomFits(free: free, natural: natural)) }
        if target > cap + 1 {
            width = .pinned(cap: target)
            return [.grew(from: cap, to: target, free: free)]
        }
        width = .pinned(cap: cap)                         // 没空位：钉住，等下次抬起再量
        return []
    }

    private mutating func release(_ why: Release) -> [Change] {
        width = .full
        pinnedTicks = 0
        return [.released(why)]
    }
}
