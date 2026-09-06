import AppKit
import os

// MARK: - 菜单栏状态项宽度治理（纯反应式）
//
// macOS 在菜单栏塞不下时会把整个状态项藏起来。这里 1Hz 巡检状态项窗口的 occlusionState，
// 真被挤出时按实测空位一步收缩 mbWidthCap；空间回来 / 内容变短时立刻解除上限。
// 状态属性仍在 PanelModel 里（mbWidthCap / lastNatural / growCeiling / hiddenTicks /
// concealReasons / statusWindow / panelWindowClass），这个文件只放算法，方便单独阅读与改动。
//
// macOS 26.6 实测的两条教训（v1.9.3）：
// 1. 「occlusionState 不含 .visible」≠ 被挤。App 全屏、锁屏、屏保、息屏时状态项同样失去
//    .visible，而窗口位置纹丝不动。旧版把这当成被挤，每 2s 砍 48pt 砍到 80pt 下限，退出全屏后
//    还要等切换前台 app 才每 2s 长回 100pt——就是「label 缩进去再慢慢展开」的根源。
//    所以先分「遮蔽」还是「被挤」，遮蔽期间宽度一根手指都不动。判据：被挤时整条菜单栏都在
//    （其他 app 的状态项在屏幕上）、唯独我们不在；全屏 / 自动隐藏时所有状态项都不在屏幕上；
//    锁屏 / 屏保 / 息屏 / 睡眠由系统通知维护 concealReasons。
//    旧的 NSScreen.visibleFrame 守卫在全屏时值不变，形同虚设，已删。
// 2. 被挤出的窗口不是顶到 x<0，而是停放在刘海左侧（x 无规律，isVisible 恒 true），
//    坐标算不出溢出量；刘海屏直接量「刘海右侧区域里最左状态项左边的空位」一步压到刚好放下，
//    普通屏量不到左界（前台 app 菜单末端）才退回 48pt 步进试探。
// 两处按私有类名嗅探 SwiftUI 内部窗口（StatusBarWindow / MenuBarExtraWindow）都在此文件，
// 系统升级失效时只需改这里。
extension PanelModel {
    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "menubar")
    /// 再窄就只剩 ⚡ 了；压到这里还放不下就只能等空间回来。
    private static let minCap: CGFloat = 80
    /// 状态项窗口比合成图宽 16pt（左右各 8 内边距），composite 又把图宽压到 cap-12 → 窗口 ≈ cap+4。
    /// 空位减掉这个余量得到的 cap 才保证放得下；多留 12pt 吃掉 notchGap 的估算误差（30~42）。
    private static let fitMargin: CGFloat = 16

    /// 状态项可见性巡检（纯反应式，无持久化、无跨 app 记忆）：
    /// - 内容结构变了（自然宽度突变）→ 解除增长天花板，允许重新扩张（修"内容变短仍被旧上限截断"）；
    /// - 可见且有上限 → 内容放得下就解除；仍截断且天花板抬起过就夺回空间（见 growIfRoom）；
    /// - 不可见但属于遮蔽 → 不动；
    /// - 真被挤 → 连续 2 拍后按实测空位一步收缩。
    func checkStatusItemVisibility() {
        guard let win = statusBarWindow() else { return }
        guard !panelOpen() else { return }     // 面板开着时遮挡状态不稳，跳过

        // 自然宽度（未截断的完整内容宽）由合成图缓存持有 —— 它本来就要存这个值。
        let naturalWidth = MBLabelCache.currentNatural
        // 内容结构突变（增删码片/AI 段，宽度跳变 >30pt）→ 允许重新扩张，不受旧挤出宽度束缚
        if abs(naturalWidth - lastNatural) > 30 { growCeiling = .greatestFiniteMagnitude }
        lastNatural = naturalWidth

        guard !win.occlusionState.contains(.visible) else {
            hiddenTicks = 0
            // 看得见就绝不是遮蔽中：某个「结束」通知漏掉也不至于让 governor 永久失灵
            if !concealReasons.isEmpty { setConcealed(reasons: []) }
            growIfRoom(win, natural: naturalWidth)
            return
        }
        // 不可见：先排除遮蔽（全屏 / 自动隐藏 / 锁屏 / 屏保 / 息屏），那不是被挤，宽度不动
        let scan = MenuBarStrip.live(for: win)
        Self.log.debug("hidden: reasons=\(self.concealReasons.sorted().joined(separator: ","), privacy: .public) items=\(scan?.itemsOnScreen ?? -1) covered=\(scan?.covered ?? false) free=\(Int(scan?.freeLeft ?? -1)) frame=\(Int(win.frame.minX))..\(Int(win.frame.maxX)) cap=\(Int(self.mbWidthCap ?? -1)) ticks=\(self.hiddenTicks)")
        guard concealReasons.isEmpty, let scan, scan.itemsOnScreen > 0, !scan.covered else { hiddenTicks = 0; return }
        hiddenTicks += 1
        guard hiddenTicks >= 2 else { return }            // 连续 2 拍才算真被挤，滤开合毛刺
        hiddenTicks = 0                                   // 收缩后重新计数，给渲染生效留时间
        let cur = mbWidthCap ?? win.frame.width
        // 刘海屏：空位实测，一步到位；量不到（普通屏）或量出来不比现在窄（布局还在路上）→ 48pt 步进
        var newCap = scan.freeLeft.map { $0 - Self.fitMargin } ?? 0
        if newCap >= cur { newCap = cur - 48 }
        newCap = max(Self.minCap, newCap)
        guard newCap < cur else { return }                // 已在下限，只能等空间回来
        growCeiling = newCap                              // 别再涨回刚被挤的宽度，防边界震荡
        mbWidthCap = newCap
        Self.log.info("squeezed: cap \(Int(cur)) → \(Int(newCap)), free=\(Int(scan.freeLeft ?? -1)), items=\(scan.itemsOnScreen)")
    }

    /// 可见但有上限时夺回空间：内容放得下 → 直接解除；仍截断则在天花板抬起过（切了前台 app /
    /// 内容结构变了 / 屏幕变了）时试一次——刘海屏量出空位只涨到刚好、绝不撞隐身；普通屏量不到，
    /// 直接回全宽，放不下会被精确压回。试过没空位就把天花板钉回 cap；钉住期间刘海屏每 30s
    /// 无痛重量一次（量不会隐身，挤我们的东西走了就自动长回来），普通屏只能等下次抬起。
    private func growIfRoom(_ win: NSWindow, natural: CGFloat) {
        guard let cap = mbWidthCap else { pinnedTicks = 0; return }   // 全宽显示中，无需动作
        if natural <= cap + 6 { release("content fits cap \(Int(cap))"); return }
        if growCeiling <= cap {                           // 刚被挤过、空间没变 → 别去撞
            pinnedTicks += 1
            guard pinnedTicks >= 30, MenuBarStrip.screen(of: win)?.auxiliaryTopRightArea != nil else { return }
        }
        pinnedTicks = 0
        guard let free = MenuBarStrip.live(for: win)?.freeLeft else { release("probe full width"); return }
        let target = min(natural, cap + free - Self.fitMargin)
        if target >= natural {
            release("room \(Int(free)) fits natural \(Int(natural))")
        } else if target > cap + 1 {
            mbWidthCap = target
            growCeiling = target
            Self.log.info("grow: cap \(Int(cap)) → \(Int(target)), free=\(Int(free))")
        } else {
            growCeiling = cap                             // 没空位：钉住天花板，等下次抬起再量
        }
    }

    private func release(_ why: String) {
        mbWidthCap = nil
        growCeiling = .greatestFiniteMagnitude
        pinnedTicks = 0
        Self.log.info("release cap: \(why, privacy: .public)")
    }

    /// 锁屏 / 屏保 / 息屏 / 睡眠：这些期间状态项必然失去 .visible，与被挤无关。
    /// 成对的系统通知维护 concealReasons；非空即遮蔽。start() 里调一次。
    func observeMenuBarConcealment() {
        let dnc = DistributedNotificationCenter.default()
        let wnc = NSWorkspace.shared.notificationCenter
        let pairs: [(NotificationCenter, Notification.Name, Notification.Name, String)] = [
            (dnc, .init("com.apple.screenIsLocked"),      .init("com.apple.screenIsUnlocked"),   "lock"),
            (dnc, .init("com.apple.screensaver.didstart"), .init("com.apple.screensaver.didstop"), "saver"),
            (wnc, NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display"),
            (wnc, NSWorkspace.willSleepNotification,       NSWorkspace.didWakeNotification,        "sleep"),
        ]
        for (center, on, off, reason) in pairs {
            center.addObserver(forName: on, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self.map { $0.setConcealed(reasons: $0.concealReasons.union([reason])) } }
            }
            center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self.map { $0.setConcealed(reasons: $0.concealReasons.subtracting([reason])) } }
            }
        }
    }

    private func setConcealed(reasons: Set<String>) {
        guard reasons != concealReasons else { return }
        concealReasons = reasons
        Self.log.info("conceal reasons: [\(reasons.sorted().joined(separator: ","), privacy: .public)]")
    }

    /// 状态项窗口：长命对象，弱引用缓存住。原来每拍都对所有窗口做
    /// String(describing: type(of:)) 建串再子串匹配，1Hz 常驻白烧。
    private func statusBarWindow() -> NSWindow? {
        if let w = statusWindow { return w }
        let found = NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        statusWindow = found
        return found
    }

    /// 菜单栏面板是否开着。面板窗口按需创建，弱引用会随关闭失效，改缓存「类对象」：
    /// 认过一次之后每拍只做指针比对，不再建字符串。
    private func panelOpen() -> Bool {
        NSApp.windows.contains { w in
            if let cls = panelWindowClass { return type(of: w) == cls && w.isVisible }
            guard String(describing: type(of: w)).contains("MenuBarExtraWindow") else { return false }
            panelWindowClass = type(of: w)
            return w.isVisible
        }
    }
}

extension MenuBarStrip {
    /// 抓一次「状态项窗口所在屏幕」菜单栏条带的窗口快照。CGWindowList 不需要录屏权限即可拿到
    /// 各窗口的层级 / 归属 / 位置（拿不到的只是窗口标题）。CG 坐标：原点主屏左上、y 向下。
    /// 状态项窗口所属的屏幕。被挤出去的窗口可能停在屏外（win.screen 为 nil）→ 按顶边对齐找。
    @MainActor
    static func screen(of win: NSWindow) -> NSScreen? {
        win.screen ?? NSScreen.screens.first { abs($0.frame.maxY - win.frame.maxY) < 1 } ?? NSScreen.main
    }

    @MainActor
    static func live(for win: NSWindow) -> Scan? {
        guard let primary = NSScreen.screens.first, let screen = screen(of: win) else { return nil }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let records = list.compactMap { w -> Record? in
            guard let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  let layer = w[kCGWindowLayer as String] as? Int else { return nil }
            return Record(layer: layer, alpha: w[kCGWindowAlpha as String] as? Double ?? 1, bounds: bounds)
        }
        let top = primary.frame.maxY - screen.frame.maxY          // 该屏顶端的 CG y
        let strip = CGRect(x: screen.frame.minX, y: top, width: screen.frame.width, height: win.frame.height)
        let boundary = screen.auxiliaryTopRightArea.map { $0.minX + notchGap }
        let center = CGPoint(x: win.frame.midX, y: primary.frame.maxY - win.frame.midY)
        return scan(records, strip: strip, boundary: boundary, myCenter: center)
    }
}
