import SwiftUI

@main
struct CCUsageApp: App {
    // 组装处：菜单栏和主窗口的桥接共用一个 store（它的默认叠加层是进程内单例，两边共享一次扫描）。
    private let store: UsageStore
    @StateObject private var model: PanelModel

    init() {
        let store = UsageStore()
        self.store = store
        _model = StateObject(wrappedValue: PanelModel(store: store))
    }

    var body: some Scene {
        // Window（非 WindowGroup）：主窗全局唯一，菜单栏连点 Open Main Window
        // 只会聚焦同一个窗口，不再叠出一堆主界面。
        Window("CC Usage", id: "main") {
            MainWindowView(model: model, store: store)
                .frame(minWidth: 1060, minHeight: 700)   // ≥ cc-switch lg 断点(1024)→ 工具栏一排、徽标右对齐
        }
        .windowStyle(.hiddenTitleBar)          // 隐藏标题栏，内容边到边、交通灯浮在内容上（对齐 cc-switch 一体感）
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}
