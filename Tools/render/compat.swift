// 随 App 层 API 走的一小段：把额度喂给 PanelModel。
@MainActor
func setQuota(_ model: PanelModel, claude: [QuotaTier], codex: [(String, Double)], agy: [AntigravityTier]) {
    model.quotaTiers = claude
    model.mbCodexQuota = codex.map { CodexQuota.Window(label: $0.0, usedPercent: $0.1) }
    model.mbAntigravityQuota = agy
}
