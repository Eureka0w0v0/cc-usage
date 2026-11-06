import AppKit
import os

// MARK: - 菜单栏状态项宽度治理（纯反应式）
//
// macOS 在菜单栏塞不下时会把整个状态项藏起来。这里 1Hz 巡检状态项窗口的 occlusionState 和菜单栏条带，
// 把观测交给 WidthGovernor（Shared/MenuBar，纯状态机，规则和取舍都写在那边），再把新的上限写回
// mbWidthCap。这个文件只放 AppKit 观测和系统通知。
//
// 被挤出的窗口不是顶到 x<0，而是停放在刘海左侧（x 无规律，isVisible 恒 true），坐标算不出溢出量；刘海屏
// 直接量「刘海右侧区域里最左状态项左边的空位」（macOS 26.6 实测，v1.9.3）。
// 两处按私有类名嗅探 SwiftUI 内部窗口（StatusBarWindow / MenuBarExtraWindow）都在此文件，
// 系统升级失效时只需改这里。
extension PanelModel {
    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "menubar")

    /// 状态项可见性巡检（纯反应式，无持久化、无跨 app 记忆）。
    func checkStatusItemVisibility() {
        guard let win = statusBarWindow() else { return }
        guard !panelOpen() else { return }     // 面板开着时遮挡状态不稳，跳过

        // 自然宽度（未截断的完整内容宽）由合成图缓存持有 —— 它本来就要存这个值。
        let naturalWidth = MBLabelCache.currentNatural
        let sighting: WidthGovernor.Sighting
        if win.occlusionState.contains(.visible) {
            sighting = .visible(hasNotch: { MenuBarStrip.screen(of: win)?.auxiliaryTopRightArea != nil },
                                measureFree: { MenuBarStrip.live(for: win)?.freeLeft })
        } else {
            let scan = MenuBarStrip.live(for: win)
            Self.log.debug("hidden: reasons=\(self.widthGovernor.concealReasons.sorted().joined(separator: ","), privacy: .public) items=\(scan?.itemsOnScreen ?? -1) covered=\(scan?.covered ?? false) free=\(Int(scan?.freeLeft ?? -1)) frame=\(Int(win.frame.minX))..\(Int(win.frame.maxX)) cap=\(Int(self.mbWidthCap ?? -1)) ticks=\(self.widthGovernor.hiddenTicks)")
            sighting = .hidden(scan)
        }
        let changes = widthGovernor.tick(natural: naturalWidth, windowWidth: win.frame.width, sighting)
        for change in changes { Self.record(change) }
        if mbWidthCap != widthGovernor.cap { mbWidthCap = widthGovernor.cap }
    }

    private static func record(_ change: WidthGovernor.Change) {
        switch change {
        case .squeezed(let from, let to, let free, let items):
            log.info("squeezed: cap \(Int(from)) → \(Int(to)), free=\(Int(free ?? -1)), items=\(items)")
        case .grew(let from, let to, let free):
            log.info("grow: cap \(Int(from)) → \(Int(to)), free=\(Int(free))")
        case .released(.contentFits(let cap)):
            log.info("release cap: content fits cap \(Int(cap))")
        case .released(.roomFits(let free, let natural)):
            log.info("release cap: room \(Int(free)) fits natural \(Int(natural))")
        case .released(.probeFullWidth):
            log.info("release cap: probe full width")
        case .concealCleared:
            log.info("conceal reasons: []")
        }
    }

    /// 勾选变化、屏幕变化：解除上限，按新内容全宽重估。
    func resetWidthCap() {
        widthGovernor.reset()
        mbWidthCap = nil
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
                Task { @MainActor in self.map { $0.setConcealed($0.widthGovernor.concealReasons.union([reason])) } }
            }
            center.addObserver(forName: off, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self.map { $0.setConcealed($0.widthGovernor.concealReasons.subtracting([reason])) } }
            }
        }
    }

    private func setConcealed(_ reasons: Set<String>) {
        guard widthGovernor.setConcealed(reasons) else { return }
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
