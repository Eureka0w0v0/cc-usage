import Foundation

/// 同价推理档合并（上游 #8845，v4.0.36）。
///
/// 同一个模型的不同推理档位（`-minimal/-low/-medium/-high/-xhigh`，不分大小写），以及 Antigravity 已知的 tiered 变体，
/// 四项单价（输入、输出、缓存读、缓存写）都和基础模型相同、且基础模型自己有精确价时，在统计里并到基础模型那一行。
/// 只影响统计口径：模型统计的分组、模型筛选、首字中位数；请求日志照旧显示原始模型名。
///
/// 纯函数，不碰库：查价以闭包注入——`price` 走完整候选链（含前缀匹配），`directPrice` 只做精确匹配
/// （调用方传 `PricingTable.find` / `findDirect`：库价优先、内置表兜底）。
enum ReasoningTiers {
    typealias Price = PricingTable.Price

    /// 对齐 reasoning_tier_merge_targets：先剥推理档；剥完若还是已知的 tiered，剥掉 tiered 的结果排在前面。
    /// 结果保留原写法（大小写、路径前缀），只截掉后缀。
    static func mergeTargets(_ id: String) -> [String] {
        let afterEffort = ModelId.reasoningEffortSuffixes.lazy
            .compactMap { ModelId.stripSuffixIgnoringASCIICase(id, $0) }.first
        if let afterEffort {
            return [statisticsTieredStripped(afterEffort), afterEffort].compactMap { $0 }
        }
        return [statisticsTieredStripped(id)].compactMap { $0 }
    }

    /// 对齐 strip_statistics_tiered_suffix：只剥已知会出 tiered 变体的模型（Gemini 4 Hydrogen、各版本 Gemini Flash），
    /// 判断时看最后一个 `/` 之后、转小写、剥掉命名空间的部分。
    static func statisticsTieredStripped(_ id: String) -> String? {
        guard let stripped = ModelId.stripSuffixIgnoringASCIICase(id, "-tiered") else { return nil }
        let tail = id.range(of: "/", options: .backwards).map { String(id[$0.upperBound...]) } ?? id
        let lowerTail = asciiLowercased(tail)
        let normalized = ModelId.stripNamespace(lowerTail) ?? lowerTail
        let known = normalized == "gemini-4-hydrogen-tiered" || ModelId.stripGeminiFlashTieredSuffix(normalized) != nil
        return known ? stripped : nil
    }

    /// 对齐 statistics_model：变体的价与某个候选基础模型的直接价四项都相同时归到这个基础模型；
    /// 缺任何一方的价、或任何一项有差价，都保持原名。
    static func statisticsModel(_ raw: String, price: (String) -> Price?,
                                directPrice: (String) -> Price?) -> String {
        let targets = mergeTargets(raw)
        guard !targets.isEmpty, let variant = price(raw) else { return raw }
        return targets.first { directPrice($0) == variant } ?? raw
    }

    /// 对齐 merged_reasoning_suffixes_for_filter：筛选这个模型时还要一并匹配的后缀（小写、带前导 `-`）。
    /// 这个模型自己会被并到别处时，筛选只做精确匹配（返回空）。
    static func mergedSuffixes(for model: String, price: (String) -> Price?,
                               directPrice: (String) -> Price?) -> [String] {
        guard statisticsModel(model, price: price, directPrice: directPrice) == model else { return [] }
        var suffixes = ModelId.reasoningEffortSuffixes
        if statisticsTieredStripped(model + "-tiered") != nil {
            suffixes.append("-tiered")
            suffixes += ModelId.reasoningEffortSuffixes.map { "-tiered" + $0 }
        }
        return suffixes.filter { statisticsModel(model + $0, price: price, directPrice: directPrice) == model }
    }

    /// 只转 ASCII 的小写（同 Rust 的 to_ascii_lowercase、SQLite 内置的 LOWER）。
    static func asciiLowercased(_ s: String) -> String {
        String(decoding: s.utf8.map(ModelId.asciiLower), as: UTF8.self)
    }
}
