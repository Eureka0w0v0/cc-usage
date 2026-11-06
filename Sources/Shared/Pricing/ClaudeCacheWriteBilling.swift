import Foundation

/// Claude 缓存写入的计价口径（对齐 cc-switch v4.0.7 #7653 / calculator.rs）。
///
/// Anthropic 把 `cache_creation_input_tokens` 分成 5 分钟和 1 小时两档写入，拆分记在
/// `usage.cache_creation.ephemeral_{5m,1h}_input_tokens`。定价表的 cache_creation 单价是
/// 5 分钟档（输入价 × 1.25），1 小时档是输入价 × 2，即 5 分钟档的 1.6 倍。
///
/// 只有 SessionOverlay 的现场定价用得到：拆分不落库，库里的行要么已按导入时的口径算好成本，
/// 要么成本为 0、由 costSQL 兜底（与上游 backfill 一样只能按 5 分钟价）。
public enum ClaudeCacheWriteBilling {
    /// 1 小时写入相对定价表 cache_creation 单价的倍数（2 / 1.25）。
    public static let oneHourMultiplier = 1.6

    /// 第一个按 1 小时价导入 Claude 会话的 cc-switch 版本。
    static let firstOneHourVersion = [4, 0, 7]

    /// 叠加层要不要按 1 小时价计。叠加行迟早会被 cc-switch 补录的行替换，现场算的数必须和它
    /// 补录的一致，否则一打开 cc-switch 数字就跳：
    /// - ≥ 4.0.7：它按 1 小时价补录，跟着算；
    /// - 更早的版本（如 3.20.x）：它补录时一律按 5 分钟价，现场也按 5 分钟价；
    /// - 没装、或版本号认不出：没有补录方要对齐，按正确的 1 小时价。
    public static func usesOneHourRate(ccSwitchVersion: String?) -> Bool {
        guard let version = ccSwitchVersion, let parts = numericParts(version) else { return true }
        return !parts.lexicographicallyPrecedes(firstOneHourVersion)
    }

    /// 缓存写入成本（美元）。1 小时部分钳在 [0, 总写入量]（同上游 `min`），开关关着时不拆分。
    public static func cost(tokens: Int64, oneHourTokens: Int64,
                            pricePerMillion: Double, oneHourRate: Bool) -> Double {
        let oneHour = oneHourRate ? min(max(oneHourTokens, 0), tokens) : 0
        return (Double(tokens - oneHour) + Double(oneHour) * oneHourMultiplier)
            * pricePerMillion / 1_000_000
    }

    /// 「4.0.12」→ [4, 0, 12]。只认开头的数字和点（「4.0.7-beta.1」→ [4, 0, 7]），认不出为 nil。
    static func numericParts(_ version: String) -> [Int]? {
        let head = version.prefix { $0 == "." || ("0"..."9").contains($0) }
        // 空串也会切出一个空段，Int("") 为 nil，所以「没有数字」和「有空段」一并在这里挡掉
        let parts = head.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.contains(nil) else { return nil }
        return parts.compactMap { $0 }
    }

    public static let defaultAppPaths = ["/Applications/CC Switch.app", "~/Applications/CC Switch.app"]

    /// 本机装的 CC Switch 版本号，按 appPaths 顺序找第一个。每次现读 Info.plist：升级是原地
    /// 替换 .app，`Bundle(url:)` 按路径缓存实例，会一直报旧版本。
    public static func installedCCSwitchVersion(appPaths: [String] = defaultAppPaths) -> String? {
        for path in appPaths {
            let plist = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                .appendingPathComponent("Contents/Info.plist")
            if let info = NSDictionary(contentsOf: plist),
               let version = info["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        return nil
    }
}
