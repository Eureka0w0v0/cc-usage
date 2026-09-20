import SwiftUI
import AppKit

/// 菜单栏「显示设置」：按 AI 分组的手风琴。All = 全部 AI 合计（旧 Tokens/Cost 语义不变），
/// Claude/Codex/Gemini/OpenCode 各自展开选该 AI 的 Tokens/Cost，有配额数据的 AI 多一行 Quota
/// （Claude = 官方接口 5H/Week，Codex = 本地会话快照、窗口自适应）。折叠状态持久化，默认只展开 All。
struct MenuBarSettingsView: View {
    @ObservedObject var model: PanelModel
    @AppStorage(MBKey.groupAll)         private var expAll = true
    @AppStorage(MBKey.groupClaude)      private var expClaude = false
    @AppStorage(MBKey.groupCodex)       private var expCodex = false
    @AppStorage(MBKey.groupGemini)      private var expGemini = false
    @AppStorage(MBKey.groupOpencode)    private var expOpencode = false
    @AppStorage(MBKey.groupAntigravity) private var expAntigravity = false
    @AppStorage(MBKey.groupGrok)        private var expGrok = false
    @AppStorage(MBKey.groupPi)          private var expPi = false
    @AppStorage(MBKey.groupMcode)       private var expMcode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show ⚡ icon in menu bar", isOn: $model.mbShowIcon)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.textMain)
            Toggle("Show quota as bar", isOn: $model.mbQuotaBar)
                .toggleStyle(.checkbox).font(.caption).foregroundStyle(Theme.textMain)

            group("All", $expAll) {
                row("Tokens") {
                    check("Day", $model.mbTokToday); check("Week", $model.mbTokWeek); check("Month", $model.mbTokMonth)
                }
                row("Cost") {
                    check("Day", $model.mbCostToday); check("Week", $model.mbCostWeek); check("Month", $model.mbCostMonth)
                }
            }
            group("Claude", $expClaude, icon: MBApp.claude.iconAsset) {
                appRows(.claude)
                row("Quota") { check("5H", $model.mbQuota5H); check("Week", $model.mbQuotaWeek) }
            }
            group("Codex", $expCodex, icon: MBApp.codex.iconAsset) {
                appRows(.codex)
                // 逐窗口勾选，交互与 Claude 对齐；窗口从本地快照发现（Plus=5H+Week，Free=30D）
                row("Quota") {
                    // 读 model 里后台扫好的快照。这里原来直接调 CodexQuota.latest()，
                    // 而 group() 的内容闭包是立即求值的 —— 分组折叠着也会在主线程
                    // 递归枚举 ~/.codex/sessions，面板每开一次就每 30s 卡一下。
                    let windows = model.mbCodexQuota
                    if windows.isEmpty {
                        noQuota("No Codex data")
                    } else {
                        ForEach(windows, id: \.label) { w in
                            check(w.label, model.chipBinding("codex.quota.\(w.label)"))
                        }
                    }
                }
            }
            .onChange(of: expCodex) { _, on in
                if on { model.reload() }   // 展开即补一轮，不必干等下一个 tick 才出勾选项
            }
            // Gemini 按天限请求数且不落盘、OpenCode 配额归背后 provider、Grok/xAI 无公开额度接口——
            // 都没有配额窗口可显示，Quota 行保留占位并如实标注
            group("Gemini", $expGemini, icon: MBApp.gemini.iconAsset) {
                appRows(.gemini)
                row("Quota") { noQuota("No quota API") }
            }
            group("OpenCode", $expOpencode, icon: MBApp.opencode.iconAsset) {
                appRows(.opencode)
                row("Quota") { noQuota("No quota API") }
            }
            // Grok/xAI 无公开 remaining/utilization 查询接口，Quota 与 Gemini/OpenCode 同占位
            group("Grok", $expGrok, icon: MBApp.grokbuild.iconAsset) {
                appRows(.grokbuild)
                row("Quota") { noQuota("No quota API") }
            }
            // Pi / MiniMax Code：用量经各自的会话导入器进 cc-switch 的库（无代理通道），
            // 额度归背后 provider，本应用无从查起 —— Quota 行与上面几家同占位。
            // Pi 没有可用品牌图标（上游亦然），分组标题只有文字。
            group("Pi", $expPi, icon: MBApp.pi.iconAsset) {
                appRows(.pi)
                row("Quota") { noQuota("No quota API") }
            }
            group("MiniMax Code", $expMcode, icon: MBApp.mcode.iconAsset) {
                appRows(.mcode)
                row("Quota") { noQuota("No quota API") }
            }
            // Antigravity 各模型实时配额（联网查询，无本地用量库），逐模型勾选、显示已用 %
            group("Antigravity", $expAntigravity, icon: MBApp.antigravity.iconAsset) {
                let pools = AntigravityQuota.pools(model.mbAntigravityQuota)
                if pools.isEmpty {
                    row("Quota") { noQuota("No Antigravity data") }
                } else {
                    // 按家族折叠：同家族共用配额，一个勾选即可，勾选后菜单栏显示已用 %
                    row("Quota") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(pools) { p in
                                check("\(p.family) · \(Int(p.usedPercent.rounded()))%",
                                      model.chipBinding("antigravity.quota.\(p.family)"))
                            }
                        }
                    }
                }
            }
            .onChange(of: expAntigravity) { _, on in
                if on { model.refreshAntigravityNow() }   // 展开分组即联网拉取模型列表
            }

            Text("All = every AI combined; D/W/M = Day/Week/Month. Quota windows are labelled by duration (5H/7D/30D) so they never clash with the W of Week, and show % used — as a bar unless you turn that off, filled solid once past 90%. Length is unlimited; only if macOS squeezes the item out does it auto-shrink to fit, truncated with ….")
                .font(.caption2).foregroundStyle(Theme.textDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 单个 AI 的 Tokens/Cost 两行（D/W/M 勾选走 chipBinding，落盘 + 即时补数）。
    @ViewBuilder private func appRows(_ app: MBApp) -> some View {
        let a = app.rawValue
        row("Tokens") {
            check("Day",   model.chipBinding("\(a).tokens.today"))
            check("Week",  model.chipBinding("\(a).tokens.week"))
            check("Month", model.chipBinding("\(a).tokens.month"))
        }
        row("Cost") {
            check("Day",   model.chipBinding("\(a).cost.today"))
            check("Week",  model.chipBinding("\(a).cost.week"))
            check("Month", model.chipBinding("\(a).cost.month"))
        }
    }

    /// 一个可折叠的 AI 区块：品牌图标 + 标题，整行可点开合（与外层 Menu Bar Display 同交互）。
    private func group<C: View>(_ title: String, _ expanded: Binding<Bool>, icon: String? = nil,
                                @ViewBuilder _ content: () -> C) -> some View {
        let inner = content()   // 立即求值：DisclosureGroup 的内容闭包是逃逸的，参数默认非逃逸
        return DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 8) { inner }
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
            .onTapGesture { withAnimation { expanded.wrappedValue.toggle() } }
        }
        .tint(Theme.textDim)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(Theme.textDim)
                .frame(width: 56, alignment: .leading)
            HStack(spacing: 12) { content() }
            Spacer(minLength: 0)
        }
    }

    private func check(_ label: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(label, isOn: isOn)
            .toggleStyle(.checkbox)
            .font(.caption)
            .foregroundStyle(Theme.textMain)
    }

    /// Quota 行的灰色占位说明（该 AI 无配额数据源时）。
    private func noQuota(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(Theme.textDim)
    }
}
