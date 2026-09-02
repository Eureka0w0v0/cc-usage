import SwiftUI

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
