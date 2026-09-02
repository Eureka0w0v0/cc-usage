import SwiftUI
import AppKit

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
