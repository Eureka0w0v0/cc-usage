import Foundation

// Claude OAuth 用量 API（`GET /api/oauth/usage`）响应体的**纯解析层**。
//
// 为什么独立成文件而不是留在 QuotaService 里：解析是纯函数（JSON in、值类型 out），
// 而 QuotaService 还夹着 Keychain / URLSession / actor 缓存。测试 target 只编
// `Tests` + `Sources/Shared`（见 project.yml），逻辑留在 `Sources/App` 就一行都测不到。
// 拆开后解析规则可被夹具逐条打靶，网络与凭据那半边保持原样。
//
// 对齐 cc-switch `src-tauri/src/services/subscription.rs` 的 `parse_claude_quota`。

// MARK: - 数据模型

/// 单个限流窗口（对齐 cc-switch QuotaTier）
public struct QuotaTier: Identifiable, Sendable, Equatable {
    /// 窗口标识：five_hour / seven_day / seven_day_fable / seven_day_opus / seven_day_sonnet …
    public let name: String
    /// 已用百分比 0–100
    public let utilization: Double
    /// 窗口重置时间
    public let resetsAt: Date?
    /// 套餐标签（来自凭据 subscriptionType，如 "max"）
    public var planLabel: String?

    public var id: String { name }

    public init(name: String, utilization: Double, resetsAt: Date?, planLabel: String? = nil) {
        self.name = name
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.planLabel = planLabel
    }
}

// MARK: - 解析

public enum ClaudeQuotaParser {

    // 已知窗口名。数组顺序即展示顺序——`parse` 末尾按此序稳定排序，
    // 未知窗口一律排在已知窗口之后并保持相互间的原有次序。
    public static let tierFiveHour = "five_hour"
    public static let tierSevenDay = "seven_day"
    /// 内部统一名称：Fable 在新版响应里由 `limits[].scope.model` 标识，没有同名顶层窗口。
    public static let tierSevenDayFable = "seven_day_fable"
    public static let tierSevenDayOpus = "seven_day_opus"
    public static let tierSevenDaySonnet = "seven_day_sonnet"

    public static let knownTiers: [String] = [
        tierFiveHour, tierSevenDay, tierSevenDayFable, tierSevenDayOpus, tierSevenDaySonnet,
    ]

    /// 顶层里不是「窗口」的键，遍历未知窗口时跳过。
    /// `limits` 在这里跳过是因为它由下面的 scoped 分支专门处理——不是忽略它。
    private static let nonTierKeys: Set<String> = [
        "extra_usage", "limits", "spend", "member_dashboard_available",
    ]

    /// `display_name` → 内部 tier 名。大小写与首尾空白已归一。
    private static let scopedModelTiers: [String: String] = [
        "fable": tierSevenDayFable,
        "opus": tierSevenDayOpus,
        "sonnet": tierSevenDaySonnet,
    ]

    /// 把响应体解析成窗口列表。
    ///
    /// 三段来源，后者覆盖前者：
    ///   1. 已知顶层窗口（旧格式，读 `utilization`）
    ///   2. 未知顶层窗口（API 新加的窗口类型，同样读 `utilization`，保留原名）
    ///   3. `limits[]` 里的模型专属周限额（新格式，读 `percent`）——覆盖同名旧窗口
    ///
    /// 任何一条畸形都只跳过它自己，不影响其余窗口。
    public static func parse(_ root: [String: Any]) -> [QuotaTier] {
        var tiers: [QuotaTier] = []

        // 1) 已知窗口：按 knownTiers 的顺序先收，天然就是展示序。
        for name in knownTiers {
            if let tier = legacyTier(named: name, from: root) { tiers.append(tier) }
        }

        // 2) 未知窗口：API 新加的窗口类型也要显示，保留它的原名。
        for (key, _) in root where !nonTierKeys.contains(key) && !knownTiers.contains(key) {
            if let tier = legacyTier(named: key, from: root) { tiers.append(tier) }
        }

        // 3) 模型专属周限额覆盖同名旧窗口。
        applyScopedLimits(from: root, into: &tiers)

        // 已知窗口按 knownTiers 排序，未知窗口排其后（稳定，保持彼此原有次序）。
        // 不排序的话顺序跟着字典哈希走，面板每次刷新码片都会跳位。
        return stableSortedByKnownOrder(tiers)
    }

    // MARK: - 旧格式顶层窗口

    /// 读一个顶层窗口。`utilization` 缺失 / 为 null / 非数字都返回 nil（该窗口不显示）。
    private static func legacyTier(named name: String, from root: [String: Any]) -> QuotaTier? {
        guard let window = root[name] as? [String: Any],
              let util = window["utilization"] as? NSNumber else { return nil }
        return QuotaTier(
            name: name,
            utilization: util.doubleValue,
            resetsAt: resetsAt(window),
            planLabel: nil
        )
    }

    // MARK: - 新格式 limits[]

    /// 解析 `limits[]` 中 `kind == "weekly_scoped"` 的模型专属周限额，覆盖同名旧窗口。
    ///
    /// 与 Claude Code 一致：**不**按 `is_active` 过滤——0% 或 `resets_at: null` 也可能是
    /// 有效额度，不存在的额度接口直接省略。
    private static func applyScopedLimits(from root: [String: Any], into tiers: inout [QuotaTier]) {
        guard let limits = root["limits"] as? [Any] else { return }

        var seen = Set<String>()
        for entry in limits {
            guard let limit = entry as? [String: Any],
                  limit["kind"] as? String == "weekly_scoped",
                  limit["group"] as? String == "weekly" else { continue }

            let scope = limit["scope"] as? [String: Any]
            // 特定使用场景的子限额（scope.surface 非 null）不能并进整个模型的周限额。
            if let surface = scope?["surface"], !(surface is NSNull) { continue }

            guard let model = (scope?["model"] as? [String: Any])?["display_name"] as? String,
                  let name = scopedModelTiers[
                    model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                  ],
                  let percent = limit["percent"] as? NSNumber else { continue }

            let value = percent.doubleValue
            // 首条胜出：同一 tier 出现多次时后来者一律丢弃（对齐上游 HashSet 语义）。
            guard value.isFinite, value >= 0, seen.insert(name).inserted else { continue }

            let tier = QuotaTier(
                name: name, utilization: value, resetsAt: resetsAt(limit), planLabel: nil)
            if let i = tiers.firstIndex(where: { $0.name == name }) {
                tiers[i] = tier
            } else {
                tiers.append(tier)
            }
        }
    }

    // MARK: - 共用

    /// `resets_at` 缺失 / null / 非法时间串一律记为 nil——窗口本身仍然有效。
    private static func resetsAt(_ dict: [String: Any]) -> Date? {
        (dict["resets_at"] as? String).flatMap { ISO8601Lenient.date($0) }
    }

    /// 稳定排序：已知窗口按 `knownTiers` 的次序，未知窗口统一排到最后且保持原有相对顺序。
    /// Swift 的 `sort` 不保证稳定，所以带上原下标当第二关键字。
    private static func stableSortedByKnownOrder(_ tiers: [QuotaTier]) -> [QuotaTier] {
        tiers.enumerated()
            .sorted { a, b in
                let ra = knownTiers.firstIndex(of: a.element.name) ?? knownTiers.count
                let rb = knownTiers.firstIndex(of: b.element.name) ?? knownTiers.count
                return ra == rb ? a.offset < b.offset : ra < rb
            }
            .map(\.element)
    }
}
