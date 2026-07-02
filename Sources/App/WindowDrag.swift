import SwiftUI
import AppKit

/// 顶部原生拖拽条。隐藏标题栏后 WKWebView 会吞掉鼠标事件、`-webkit-app-region:drag`
/// 在 WKWebView 里又不生效，所以在面板顶部留白带(交通灯所在、无网页控件)叠一层原生
/// 视图:按下即 `performDrag` 拖动窗口。交通灯是窗口按钮层，在此覆盖层之上，点击不受影响。
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = true
    }
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)   // 直接发起窗口拖动
        }
    }
}
