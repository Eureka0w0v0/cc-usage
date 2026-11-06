import Foundation

/// 菜单栏里的一个额度码片。pct = nil 表示勾了但没数据（没装 / 未登录 / 扫不到快照）。
/// 额度不混进文本段：它要自绘（进度条 / 危险胶囊），跟用量文本分开建模。
struct QuotaChip: Equatable {
    let label: String        // 窗口时长（5H/7D/30D）或模型家族名
    let pct: Double?

    var speech: String {
        guard let pct else { return label == "—" ? "quota unavailable" : "\(label) unavailable" }
        return "\(label) \(Int(pct.rounded()))% used"
    }
}

/// 一家的额度读数 + 勾选 → 该段要画的码片。
enum MenuBarQuota {
    static func chips(for app: MBApp, readings: [QuotaReading], selection: Set<String>,
                      claude5H: Bool, claudeWeek: Bool) -> [QuotaChip] {
        switch app {
        case .claude:
            return claudeChips(readings, show5H: claude5H, showWeek: claudeWeek)
        case .codex, .agy:
            return selectedChips(readings, app: app, selection: selection)
        case .gemini, .opencode, .grokbuild, .pi, .mcode, .kimi, .omp, .dsh:
            return []
        }
    }

    /// Claude 走官方接口两档，勾了没读数时也占位。窗口标签一律用时长：原来七日额度叫 "W"，而 All 组的 "W" 是
    /// 「本周用量」——两个 W 同屏含义不同，没法读，这里改 7D 彻底分开。
    private static func claudeChips(_ readings: [QuotaReading], show5H: Bool, showWeek: Bool) -> [QuotaChip] {
        func pct(_ window: String) -> Double? { readings.first { $0.key == window }?.usedPercent }
        var chips: [QuotaChip] = []
        if show5H { chips.append(QuotaChip(label: "5H", pct: pct("five_hour"))) }
        if showWeek { chips.append(QuotaChip(label: "7D", pct: pct("seven_day"))) }
        return chips
    }

    /// Codex（本地快照，窗口自适应）和 Antigravity（官方接口，服务端回几档就有几档）按档勾选。
    /// 勾了但一条读数都没有（没装 / 未登录 / 会话被清 / 网络失败）时给一个「—」。
    private static func selectedChips(_ readings: [QuotaReading], app: MBApp, selection: Set<String>) -> [QuotaChip] {
        if selection.hasQuotaChip(app) && readings.isEmpty { return [QuotaChip(label: "—", pct: nil)] }
        return readings.filter { selection.contains(.quota(app, $0.key)) }
            .map { QuotaChip(label: $0.label, pct: $0.usedPercent) }
    }
}
