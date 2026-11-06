import SwiftUI
import AppKit

/// 菜单栏「显示设置」：按 AI 分组的手风琴。All = 全部 AI 合计（旧 Tokens/Cost 语义不变），
/// 各 AI 分组展开选该 AI 的 Tokens/Cost，有配额数据的 AI 多一行 Quota
/// （Claude = 官方接口 5H/Week，Codex = 本地会话快照、窗口自适应，Antigravity = 官方接口两组 × 5H/7D）。
/// 折叠状态持久化，默认只展开 All。分组的顺序、键和 Quota 占位文案都声明在 MBApp 上，加一家不用改这里。
struct MenuBarSettingsView: View {
    @ObservedObject var model: PanelModel
    @AppStorage(MBKey.groupAll) private var expAll = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show ⚡ icon in menu bar", isOn: $model.mbShowIcon)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.textMain)
            Toggle("Show quota as bar", isOn: $model.mbQuotaBar)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.textMain)

            SettingsGroup(title: "All", expanded: $expAll) {
                SettingsRow("Tokens") {
                    SettingsCheck("Day", $model.mbTokToday)
                    SettingsCheck("Week", $model.mbTokWeek)
                    SettingsCheck("Month", $model.mbTokMonth)
                }
                SettingsRow("Cost") {
                    SettingsCheck("Day", $model.mbCostToday)
                    SettingsCheck("Week", $model.mbCostWeek)
                    SettingsCheck("Month", $model.mbCostMonth)
                }
            }
            ForEach(MBApp.settingsOrder, id: \.self) { app in
                AppSettingsGroup(model: model, app: app)
            }

            Text("All = every AI combined; D/W/M = Day/Week/Month. Quota windows are labelled by duration (5H/7D/30D) so they never clash with the W of Week, and show % used — as a bar unless you turn that off, filled solid once past 80% (under 20% left, same as CC Switch). Length is unlimited; only if macOS squeezes the item out does it auto-shrink to fit, truncated with ….")
                .font(.caption2).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 一个 AI 的分组。展开状态每家一个键，而 @AppStorage 的键只能在 init 里定，所以自成一个视图。
private struct AppSettingsGroup: View {
    @ObservedObject var model: PanelModel
    let app: MBApp
    @AppStorage private var expanded: Bool

    init(model: PanelModel, app: MBApp) {
        self.model = model
        self.app = app
        _expanded = AppStorage(wrappedValue: false, app.expansionKey)
    }

    var body: some View {
        SettingsGroup(title: app.title, expanded: $expanded, icon: app.iconAsset) {
            SettingsRow("Tokens") { usageChecks(.tokens) }
            SettingsRow("Cost") { usageChecks(.cost) }
            quotaRow
        }
        .onChange(of: expanded) { _, on in
            guard on else { return }
            switch app {
            case .codex: model.reload()                    // 展开即补一轮，不必干等下一个 tick 才出勾选项
            case .agy: model.refreshAntigravityNow()       // 展开分组即联网拉取额度档位
            default: break
            }
        }
    }

    /// 单个 AI 的 D/W/M 勾选（走 chipBinding，落盘 + 即时补数）。
    @ViewBuilder private func usageChecks(_ metric: ChipKey.Metric) -> some View {
        SettingsCheck("Day", model.chipBinding(.usage(app, metric, .today)))
        SettingsCheck("Week", model.chipBinding(.usage(app, metric, .week)))
        SettingsCheck("Month", model.chipBinding(.usage(app, metric, .month)))
    }

    @ViewBuilder private var quotaRow: some View {
        if let note = app.quotaNote {
            SettingsRow("Quota") { SettingsNote(note) }
        } else if app == .claude {
            SettingsRow("Quota") {
                SettingsCheck("5H", $model.mbQuota5H)
                SettingsCheck("Week", $model.mbQuotaWeek)
                // 套餐名靠右（凭据里的 subscriptionType + rateLimitTier，同上游卡片上的显示）
                if let plan = model.claudePlanLabel {
                    Spacer(minLength: 8)
                    Text(plan).font(.caption).foregroundStyle(Theme.textDim)
                }
            }
        } else if app == .codex {
            // 逐窗口勾选，交互与 Claude 对齐；窗口从本地快照发现（Plus=5H+Week，Free=30D）。
            // 读 model 里后台扫好的快照：这段视图代码在主线程，不能在这里递归枚举 ~/.codex/sessions。
            SettingsRow("Quota") {
                let windows = model.mbCodexQuota
                if windows.isEmpty {
                    SettingsNote("No Codex data")
                } else {
                    ForEach(windows, id: \.label) { w in
                        SettingsCheck(w.label, model.chipBinding(.quota(.codex, w.label)))
                    }
                }
            }
        } else {
            // Antigravity：用量来自 cc-switch v4.0.18 起导入的会话日志（库里 app_type = agy，含 IDE 会话）；
            // 额度联网查官方接口，按档勾选（服务端回几档就列几档），显示已用 %
            let tiers = model.mbAntigravityQuota
            if tiers.isEmpty {
                SettingsRow("Quota") { SettingsNote("No Antigravity data") }
            } else {
                SettingsRow("Quota") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(tiers) { t in
                            SettingsCheck("\(t.label) · \(Int(t.usedPercent.rounded()))%",
                                          model.chipBinding(.quota(.agy, t.bucketId)))
                        }
                    }
                }
            }
        }
    }
}

/// 一个可折叠的区块：品牌图标 + 标题，整行可点开合（与外层 Menu Bar Display 同交互）。
private struct SettingsGroup<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    var icon: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) { content }
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
            .onTapGesture { withAnimation { expanded.toggle() } }
        }
        .tint(Theme.textDim)
    }
}

private struct SettingsRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 56, alignment: .leading)
            HStack(spacing: 12) { content }
            Spacer(minLength: 0)
        }
    }
}

private struct SettingsCheck: View {
    let label: String
    let isOn: Binding<Bool>

    init(_ label: String, _ isOn: Binding<Bool>) {
        self.label = label
        self.isOn = isOn
    }

    var body: some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(Theme.textMain)
    }
}

/// Quota 行的灰色占位说明（该 AI 无配额数据源时）。
private struct SettingsNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(Theme.textDim)
    }
}
