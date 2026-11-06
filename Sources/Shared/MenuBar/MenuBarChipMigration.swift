import Foundation

/// 菜单栏码片键的一次性迁移（启动时跑，幂等）。
enum MenuBarChipMigration {
    /// v2.1.0：Antigravity 的 app 键从本应用自起的 `antigravity` 改成库里的 app_type `agy`，额度也从
    /// 「按模型折成家族」换成「按桶」。旧接口给的是每周窗口（重置时间与每周桶一致），所以旧的家族勾选
    /// 迁到每周档：Gemini → `gemini-weekly`，Claude / GPT-OSS（同一组）→ `3p-weekly`。别的旧额度键
    /// 再也不会出现，丢掉；用量码片原样换前缀。
    static func migrateAntigravity(_ chips: Set<String>) -> Set<String> {
        let legacyQuota = [
            "antigravity.quota.Gemini": "agy.quota.gemini-weekly",
            "antigravity.quota.Claude": "agy.quota.3p-weekly",
            "antigravity.quota.GPT-OSS": "agy.quota.3p-weekly",
        ]
        var out = Set<String>()
        for chip in chips {
            if let mapped = legacyQuota[chip] {
                out.insert(mapped)
            } else if chip.hasPrefix("antigravity.quota.") {
                continue
            } else if chip.hasPrefix("antigravity.") {
                out.insert("agy." + chip.dropFirst("antigravity.".count))
            } else {
                out.insert(chip)
            }
        }
        return out
    }
}
