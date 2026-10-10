import Foundation

/// 额度告警线：菜单栏额度码片到这条线就反白成实心胶囊（见 MenuBarLabel.quotaChip）。
///
/// 独立成 Shared 的纯函数：边界语义（恰好压线算不算告警）只有在测试里钉住才不会被改漂；
/// 留在 Sources/App 就一行都测不到。
public enum QuotaWarning {
    /// 剩余不到这个百分比就告警。对齐 cc-switch v4.0.6 的 `WARN_BELOW_PERCENT = 20`
    /// （src/components/quota/quotaRules.ts 与 src-tauri/src/tray.rs；改前是 10，本 app 改前是用量 ≥90%）。
    public static let warnBelowLeftPercent: Double = 20

    /// 用量百分比（0–100）是否已到告警线：剩余**不到** 20% 才算，剩余恰好 20%（用量 80%）
    /// 仍算正常，与上游用例 `toneForLeft(20) == "normal"` 一致。
    public static func isLow(usedPercent: Double) -> Bool {
        100 - usedPercent < warnBelowLeftPercent
    }
}
