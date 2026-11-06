import Foundation

/// 菜单栏和设置面板看到的一条额度。三个来源（Claude 官方接口、Codex 本地快照、Antigravity 官方接口）各有各的
/// 取数规则和节流（QuotaCache、CodexQuota、AntigravityQuota，语义不同，不统一），只有展示类型是这一种，在进
/// PanelModel 时转过来。
struct QuotaReading: Sendable, Equatable, Identifiable {
    /// 这一档的标识：Claude 是窗口名（five_hour / seven_day），Codex 是窗口标签，Antigravity 是桶 id。
    /// Codex、Antigravity 的码片键由它组成（ChipKey.quota）。
    let key: String
    let label: String
    /// 已用百分比 0–100
    let usedPercent: Double
    let resetAt: Date?
    var id: String { key }
}

extension QuotaReading {
    init(_ tier: QuotaTier) {
        self.init(key: tier.name, label: tier.name, usedPercent: tier.utilization, resetAt: tier.resetsAt)
    }

    init(_ tier: AntigravityTier) {
        self.init(key: tier.bucketId, label: tier.label, usedPercent: tier.usedPercent, resetAt: tier.resetAt)
    }
}
