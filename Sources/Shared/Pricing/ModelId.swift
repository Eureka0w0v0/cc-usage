import Foundation

/// 模型 id 归一化与定价候选链（对齐 cc-switch v4.0.36 的 model_pricing_candidates /
/// should_try_pricing_prefix_match / find_direct_model_pricing_row 的候选部分）。纯字符串逻辑，
/// ModelPricing、PricingTable 与两个 overlay 都依赖它。
/// 早前挂在 SessionOverlay 上，让定价模块反向依赖会话扫描器、形成 ModelPricing ↔ SessionOverlay
/// 的环；搬到这里之后依赖只剩单向：overlay → ModelPricing → ModelId。
enum ModelId {
    /// 一个查价候选。`allowsPrefixMatch` = 所有候选的精确匹配都落空后，能不能拿它做前缀匹配
    /// （`model_id LIKE '<id>-%'`）。从 Flash / Hydrogen 的 tiered、Orchestrator、worker 派生出来的基础模型
    /// 只做精确匹配：基础价缺失时宁可不定价，也不能借 `-preview` 或别的档位的价（上游 #9600 / #9706 / #9686）。
    struct Candidate: Equatable {
        let id: String
        let allowsPrefixMatch: Bool
    }

    static let reasoningEffortSuffixes = ["-minimal", "-low", "-medium", "-high", "-xhigh"]

    /// 对齐 model_pricing_candidates（v4.0.36）：清洗后按**队列**（先进先出）逐条展开，各规则的先后同上游——
    /// 命名空间 → Claude Desktop 的非 Anthropic 前缀 → `-v<N>` → Claude 点转横线 → 日期尾 → 推理档 →
    /// Flash tiered → Hydrogen tiered → Orchestrator / worker → Claude thinking。候选的顺序就是查价的优先级。
    /// （v4.0.34 及以前是栈式展开、后进先出，上游 #9600 改成了队列。）
    static func pricingCandidates(_ modelId: String) -> [Candidate] {
        guard let cleaned = clean(modelId) else { return [] }
        var candidates: [Candidate] = []
        var queue = [Candidate(id: cleaned, allowsPrefixMatch: true)]
        var head = 0
        while head < queue.count {
            let current = queue[head]
            head += 1
            guard pushUnique(&candidates, current) else { continue }
            let c = current.id
            // 普通的派生沿用当前候选的前缀资格；tiered / Orchestrator / worker 的基础模型一律只做精确匹配。
            let derive = { (id: String) in queue.append(Candidate(id: id, allowsPrefixMatch: current.allowsPrefixMatch)) }
            let exactOnly = { (id: String) in queue.append(Candidate(id: id, allowsPrefixMatch: false)) }
            if let s = stripNamespace(c) { derive(s) }
            if let s = stripDesktopNonAnthropicPrefix(c) { derive(s) }
            if let s = stripBedrockVersionSuffix(c) { derive(s) }
            if c.hasPrefix("claude-"), c.contains("."), stripDesktopNonAnthropicPrefix(c) == nil {
                derive(c.replacingOccurrences(of: ".", with: "-"))
            }
            if let s = stripDateSuffix(c) { derive(s) }
            if let s = stripReasoningEffortSuffix(c) { derive(s) }
            if let s = stripGeminiFlashTieredSuffix(c) { exactOnly(s) }
            if c == hydrogenTiered { exactOnly(hydrogenBase) }
            if c == hydrogenOrchestrator || c == flashWorkerAgy { exactOnly(hydrogenBase) }
            if let s = stripClaudeThinkingSuffix(c) { derive(s) }
        }
        return candidates
    }

    /// 对齐 find_direct_model_pricing_row 的候选：只剥命名空间、Desktop 前缀、`-v<N>`、Claude 点转横线、日期尾，
    /// **不剥推理档 / tiered / thinking**，结果只做精确匹配。同价推理档合并时用它取「基础模型自己的价」。
    static func directCandidates(_ modelId: String) -> [String] {
        guard let cleaned = clean(modelId) else { return [] }
        var candidates: [String] = []
        var queue = [cleaned]
        var head = 0
        while head < queue.count {
            let c = queue[head]
            head += 1
            if c.isEmpty || candidates.contains(c) { continue }
            candidates.append(c)
            if let s = stripNamespace(c) { queue.append(s) }
            if let s = stripDesktopNonAnthropicPrefix(c) { queue.append(s) }
            if let s = stripBedrockVersionSuffix(c) { queue.append(s) }
            if c.hasPrefix("claude-"), c.contains("."), stripDesktopNonAnthropicPrefix(c) == nil {
                queue.append(c.replacingOccurrences(of: ".", with: "-"))
            }
            if let s = stripDateSuffix(c) { queue.append(s) }
        }
        return candidates
    }

    /// 对齐 should_try_pricing_prefix_match（claude ≥3 段、o 系 ≥1 段、常见家族 ≥2 段）。
    /// tiered / Orchestrator / worker 这几个名字本身也不做前缀匹配（v4.0.36）。
    static func shouldTryPrefixMatch(_ id: String) -> Bool {
        if id == hydrogenTiered || id == hydrogenOrchestrator || id == flashWorkerAgy
            || stripGeminiFlashTieredSuffix(id) != nil {
            return false
        }
        let dashes = id.filter { $0 == "-" }.count
        if id.hasPrefix("claude-") { return dashes >= 3 }
        if ["o1", "o3", "o4", "o5"].contains(where: { id.hasPrefix($0) }) { return dashes >= 1 }
        let families = ["gpt-", "gemini-", "deepseek-", "qwen-", "glm-", "kimi-", "minimax-"]
        return families.contains(where: { id.hasPrefix($0) }) && dashes >= 2
    }

    // MARK: - 清洗与各条剥离规则（逐条对齐 usage_stats.rs）

    private static let hydrogenTiered = "gemini-4-hydrogen-tiered"
    private static let hydrogenOrchestrator = "gemini-4-hydrogen-orchestrator"
    private static let flashWorkerAgy = "gemini-flash-worker-agy"
    private static let hydrogenBase = "gemini-4-hydrogen"

    /// 对齐 clean_model_id_for_pricing + is_placeholder_pricing_model：取最后一个 `/` 之后、第一个 `:` 之前，
    /// 去空白、`@` 换 `-`、转小写、去掉末尾的 `[1m]` 上下文标记（可能叠了几个）再去空白；
    /// 空串和 unknown / null / none 视为占位，返回 nil。
    /// 转小写用的是完整 Unicode 规则（上游只转 ASCII）：PricingTable 的键和 TEMP 兜底表的键都这么转，三处要一致。
    private static func clean(_ modelId: String) -> String? {
        var cleaned = modelId
        if let idx = cleaned.range(of: "/", options: .backwards) { cleaned = String(cleaned[idx.upperBound...]) }
        if let idx = cleaned.firstIndex(of: ":") { cleaned = String(cleaned[..<idx]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "-").lowercased()
        while cleaned.hasSuffix("[1m]") { cleaned = String(cleaned.dropLast(4)) }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty || ["unknown", "null", "none"].contains(cleaned) { return nil }
        return cleaned
    }

    /// 同一个 id 第二次出现时不再展开；唯一的例外是先以「只精确」入列、后又以「可前缀」遇到——升级资格并重新展开
    /// （对齐 push_unique_candidate）。
    private static func pushUnique(_ candidates: inout [Candidate], _ candidate: Candidate) -> Bool {
        if candidate.id.isEmpty { return false }
        if let i = candidates.firstIndex(where: { $0.id == candidate.id }) {
            guard !candidates[i].allowsPrefixMatch, candidate.allowsPrefixMatch else { return false }
            candidates[i] = candidate
            return true
        }
        candidates.append(candidate)
        return true
    }

    /// 对齐 strip_known_model_namespace：id 中间出现 `claude-` 就从那里截（找到即返回，不再看厂商前缀）；
    /// 否则剥第一个命中的厂商前缀。
    private static func stripNamespace(_ id: String) -> String? {
        if let r = id.range(of: "claude-", options: .backwards), r.lowerBound != id.startIndex {
            return String(id[r.lowerBound...])
        }
        for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.", "bedrock.", "global."]
        where id.hasPrefix(marker) {
            return String(id.dropFirst(marker.count))
        }
        return nil
    }

    /// 对齐 strip_claude_desktop_non_anthropic_prefix：Claude Desktop 给第三方模型加的 `claude-` 前缀
    /// （`claude-deepseek-…`、`claude-gpt-…` 等）剥掉，按第三方模型自己的价算。
    private static func stripDesktopNonAnthropicPrefix(_ id: String) -> String? {
        guard id.hasPrefix("claude-") else { return nil }
        let rest = String(id.dropFirst("claude-".count))
        return desktopNonAnthropicMarkers.contains(where: { rest.hasPrefix($0) }) ? rest : nil
    }

    private static let desktopNonAnthropicMarkers = [
        "abab", "ark-code", "arctic", "astron", "codex", "command-r", "deepseek", "doubao", "ernie",
        "gemini", "gemma", "glm", "gpt", "grok", "hermes", "hy3", "hunyuan", "jamba", "kimi", "lfm",
        "llama", "longcat", "mercury", "mimo", "minimax", "mistral", "mixtral", "moonshot", "nemotron",
        "nova-", "openai", "qianfan", "qwen", "seed-", "solar", "stepfun",
    ]

    /// `-v<N>` 版本尾（Bedrock）：最后一个 `-v` 之后全是 ASCII 数字且两边都不空。
    private static func stripBedrockVersionSuffix(_ id: String) -> String? {
        guard let r = id.range(of: "-v", options: .backwards) else { return nil }
        let base = String(id[..<r.lowerBound]), suffix = id[r.upperBound...]
        guard !base.isEmpty, !suffix.isEmpty, suffix.allSatisfy(isASCIIDigit) else { return nil }
        return base
    }

    /// -YYYY-MM-DD / -YYYYMMDD / -YYMMDD（6 位校验月日）三种日期尾巴，按字节比（同上游）。
    private static func stripDateSuffix(_ id: String) -> String? {
        let bytes = Array(id.utf8)
        if bytes.count > 11 {
            let s = bytes[(bytes.count - 11)...].map { Character(UnicodeScalar($0)) }
            if s[0] == "-", s[1...4].allSatisfy(isASCIIDigit), s[5] == "-",
               s[6...7].allSatisfy(isASCIIDigit), s[8] == "-", s[9...10].allSatisfy(isASCIIDigit) {
                return String(decoding: bytes[..<(bytes.count - 11)], as: UTF8.self)
            }
        }
        guard let r = id.range(of: "-", options: .backwards) else { return nil }
        let base = String(id[..<r.lowerBound]), suffix = String(id[r.upperBound...])
        guard !base.isEmpty, suffix.allSatisfy(isASCIIDigit) else { return nil }
        if suffix.count == 8 { return base }
        if suffix.count == 6 {
            let month = Int(suffix.dropFirst(2).prefix(2)) ?? 0
            let day = Int(suffix.suffix(2)) ?? 0
            if (1...12).contains(month) && (1...31).contains(day) { return base }
        }
        return nil
    }

    /// 推理档后缀（不分大小写，剩下的部分不能为空）。
    static func stripReasoningEffortSuffix(_ id: String) -> String? {
        for suffix in reasoningEffortSuffixes {
            if let base = stripSuffixIgnoringASCIICase(id, suffix) { return base }
        }
        return nil
    }

    /// `gemini-<版本>-flash-tiered` → `gemini-<版本>-flash`，版本是点分的 ASCII 数字段（每段非空）。
    static func stripGeminiFlashTieredSuffix(_ id: String) -> String? {
        guard id.hasPrefix("gemini-"), id.hasSuffix("-flash-tiered") else { return nil }
        let start = id.index(id.startIndex, offsetBy: "gemini-".count)
        let end = id.index(id.endIndex, offsetBy: -"-flash-tiered".count)
        guard start < end else { return nil }
        let version = id[start..<end]
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(isASCIIDigit) }) else { return nil }
        return "gemini-\(version)-flash"
    }

    /// Claude 的 `-thinking` 变体按基础模型计价；只认 `claude-` 开头、且不是 Desktop 的非 Anthropic 前缀
    /// （`kimi-k2-thinking` 这类第三方 thinking 型号有自己的价，绝不剥）。
    private static func stripClaudeThinkingSuffix(_ id: String) -> String? {
        guard id.hasPrefix("claude-"), stripDesktopNonAnthropicPrefix(id) == nil,
              id.hasSuffix("-thinking") else { return nil }
        let base = String(id.dropLast("-thinking".count))
        return base.utf8.count > "claude-".utf8.count ? base : nil
    }

    /// 对齐 strip_ascii_case_insensitive_suffix：末尾按 ASCII 不分大小写等于 `suffix`、且前面还剩东西时返回前段。
    static func stripSuffixIgnoringASCIICase(_ s: String, _ suffix: String) -> String? {
        let bytes = Array(s.utf8), tail = Array(suffix.utf8)
        guard bytes.count > tail.count else { return nil }
        let split = bytes.count - tail.count
        for (b, t) in zip(bytes[split...], tail) where asciiLower(b) != asciiLower(t) { return nil }
        return String(decoding: bytes[..<split], as: UTF8.self)
    }

    static func asciiLower(_ b: UInt8) -> UInt8 { (65...90).contains(b) ? b + 32 : b }

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
}
