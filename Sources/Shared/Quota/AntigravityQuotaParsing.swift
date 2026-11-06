import Foundation

/// Antigravity 官方额度的一档：`retrieveUserQuotaSummary` 响应里的一个桶。
struct AntigravityTier: Sendable, Equatable, Identifiable {
    let bucketId: String      // gemini-5h / gemini-weekly / 3p-5h / 3p-weekly
    let label: String         // 菜单栏与设置面板的文案，窗口按时长写（5H / 7D）
    let usedPercent: Double   // 0…100
    let resetAt: Date?
    var id: String { bucketId }
}

/// `retrieveUserQuotaSummary` 的解析规则，对齐 cc-switch `subscription_agy.rs` 的
/// tier_name / sort_order / collect_tiers 和 `agy_account/quota.rs` 的 parse_version / user_agent。
///
/// 额度分两组：Gemini 一组，Claude 和 GPT 共用一组（`3p` = third party），每组各有 5 小时和
/// 每周两个窗口。有几档回几档（10-26 实测免费档账号只回两个每周桶）。
enum AntigravityQuotaParsing {
    /// 认识的桶，顺序即展示序。文案参照上游 en 的「Gemini 5h / Gemini Wk / Claude 5h / Claude Wk」，
    /// 窗口改按时长写，和菜单栏里 Claude、Codex 的额度码片一致（W 留给「近 7 天用量」）。
    static let knownBuckets: [(id: String, label: String)] = [
        ("gemini-5h", "Gemini 5H"),
        ("gemini-weekly", "Gemini 7D"),
        ("3p-5h", "Claude 5H"),
        ("3p-weekly", "Claude 7D"),
    ]

    /// 读不到本机 agy 版本时写进 User-Agent 的版本（上游 FALLBACK_AGY_VERSION；服务端要 ≥ 1.2.0 才回 Gemini 那组）。
    static let fallbackAgyVersion = "1.4.6"

    /// 服务端按 User-Agent 决定回什么：不带 `antigravity` 一律 403；带了但不是
    /// `antigravity/cli/<版本 ≥ 1.2.0>` 只回 Claude/GPT 那组。照实报 CC Usage，括号里补上服务端要的客户端标识。
    static func userAgent(appVersion: String, agyVersion: String) -> String {
        "cc-usage/\(appVersion) (antigravity/cli/\(agyVersion))"
    }

    /// 响应 JSON → 排好序的档；一档都认不出时返回 nil（调用方保留上次结果）。
    /// 未知的桶（以后新增的组）和没有剩余比例的桶跳过；剩余比例钳到 0…1，已用 = (1 − 剩余) × 100。
    /// 同一个桶出现两次只留第一次——菜单栏拿桶 id 当勾选键，重复会让两个勾选框绑同一个键。
    static func parseSummary(_ root: [String: Any]) -> [AntigravityTier]? {
        let labels = Dictionary(uniqueKeysWithValues: knownBuckets.map { ($0.id, $0.label) })
        let order = Dictionary(uniqueKeysWithValues: knownBuckets.enumerated().map { ($1.id, $0) })
        var tiers: [AntigravityTier] = []
        let groups = root["groups"] as? [[String: Any]] ?? []
        for bucket in groups.flatMap({ $0["buckets"] as? [[String: Any]] ?? [] }) {
            guard let id = bucket["bucketId"] as? String, let label = labels[id],
                  let remaining = (bucket["remainingFraction"] as? NSNumber)?.doubleValue,
                  !tiers.contains(where: { $0.bucketId == id })
            else { continue }
            let clamped = min(1, max(0, remaining))
            let reset = (bucket["resetTime"] as? String).flatMap { ISO8601Lenient.date($0) }
            tiers.append(AntigravityTier(bucketId: id, label: label,
                                         usedPercent: (1 - clamped) * 100, resetAt: reset))
        }
        guard !tiers.isEmpty else { return nil }
        return tiers.sorted { (order[$0.bucketId] ?? .max) < (order[$1.bucketId] ?? .max) }
    }

    /// `agy --version` 输出里第一个形如 `1.4.6` 的词（允许 `v` 前缀）；没有返回 nil。
    static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace)
            .map { $0.hasPrefix("v") ? $0.dropFirst() : $0 }
            .first { word in
                word.contains(".") && word.first?.isNumber == true
                    && word.allSatisfy { $0.isNumber || $0 == "." }
            }
            .map(String.init)
    }
}
