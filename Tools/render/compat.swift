// 随 App 层 API 走的一小段：把额度喂给 PanelModel。
@MainActor
func setQuota(_ model: PanelModel, claude: [QuotaTier], codex: [(String, Double)], agy: [AntigravityTier]) {
    model.applyClaudeQuota(claude)
    model.quota[.codex] = codex.map { QuotaReading(key: $0.0, label: $0.0, usedPercent: $0.1, resetAt: nil) }
    model.quota[.agy] = agy.map(QuotaReading.init)
}
