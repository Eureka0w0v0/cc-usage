import AppKit
import SwiftUI

// MARK: - 菜单栏状态项宽度治理（纯反应式）
//
// macOS 在菜单栏塞不下时会把整个状态项隐藏。这里 1Hz 巡检 occlusionState，被挤时按
// 窗口溢出量精确收缩 mbWidthCap，内容变短/屏幕变化时解除上限。状态属性仍在 PanelModel
// 里（lastNatural / growCeiling / hiddenTicks / growTicks / statusWindow / panelWindowClass），
// 这个文件只放算法，方便单独阅读与改动。
// 三处按私有类名嗅探 SwiftUI 内部窗口（StatusBarWindow / MenuBarExtraWindow）都在此文件，
// 系统升级失效时只需改这里。
extension PanelModel {
    /// 状态项可见性巡检（纯反应式，无持久化、无跨 app 记忆）：
    /// - 内容结构变了（自然宽度突变）→ 解除增长天花板，允许重新扩张（修"内容变短仍被旧上限截断"）；
    /// - 被真正挤掉 → 按溢出量（窗口被顶出屏幕左缘的量）精确收缩，一步到位；
    /// - 可见且自然宽度已 ≤ 上限 → 上限多余，立刻解除（全宽显示，有空间绝不截断）；
    /// - 可见但仍截断 → 每 2 拍向天花板方向夺回空间，越界再被挤会精确收回，快速收敛不震荡。
    func checkStatusItemVisibility() {
        guard let win = statusBarWindow() else { return }
        let menuBarPresent = NSScreen.screens.contains { $0.visibleFrame.maxY < $0.frame.maxY }
        guard menuBarPresent else { return }   // 全屏等菜单栏不在场时不误判为被挤
        guard !panelOpen() else { return }     // 面板开着时遮挡状态不稳，跳过

        // 自然宽度（未截断的完整内容宽）由合成图缓存持有 —— 它本来就要存这个值，
        // 再让 composite 在 getter 里回写 model 属于视图求值中改状态，白白多一条暗线。
        let naturalWidth = MBLabelCache.currentNatural
        // 内容结构突变（增删码片/AI 段，宽度跳变 >30pt）→ 允许重新扩张，不受旧挤出宽度束缚
        if abs(naturalWidth - lastNatural) > 30 { growCeiling = .greatestFiniteMagnitude }
        lastNatural = naturalWidth

        // 被挤信号：occlusionState 不含 .visible（实测 isVisible 恒 true，不可用）
        let visible = win.occlusionState.contains(.visible)
        if visible {
            hiddenTicks = 0
            guard let cap = mbWidthCap else { return }        // 全宽显示中，无需动作
            if naturalWidth <= cap + 6 {                      // 内容已能全放下 → 上限多余，解除
                mbWidthCap = nil; growTicks = 0
            } else {                                          // 仍截断 → 慢慢夺回空间
                growTicks += 1
                if growTicks >= 2 {
                    let target = min(naturalWidth, min(cap + 100, growCeiling))
                    if target > cap + 1 { mbWidthCap = target }
                    growTicks = 0
                }
            }
        } else {
            growTicks = 0
            hiddenTicks += 1
            guard hiddenTicks >= 2 else { return }            // 连续 2 拍才算真被挤，滤面板开合毛刺
            let overflow = win.frame.origin.x < 0 ? -win.frame.origin.x + 24 : 48
            let cur = mbWidthCap ?? win.frame.width
            let newCap = max(80, cur - overflow)
            growCeiling = newCap                              // 别再涨回刚被挤的宽度，防边界震荡
            mbWidthCap = newCap
            hiddenTicks = 0                                   // 收缩后重新计数，给渲染生效留时间
        }
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
