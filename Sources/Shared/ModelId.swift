import Foundation

/// 模型 id 归一化与定价候选链（对齐 cc-switch 的 model_pricing_candidates /
/// should_try_pricing_prefix_match）。纯字符串逻辑，ModelPricing 与两个 overlay 都依赖它。
/// 早前挂在 SessionOverlay 上，让定价模块反向依赖会话扫描器、形成 ModelPricing ↔ SessionOverlay
/// 的环；搬到这里之后依赖只剩单向：overlay → ModelPricing → ModelId。
enum ModelId {
    /// 对齐 model_pricing_candidates(裁剪版:只保留 Claude 会话日志会遇到的规则——
    /// 路径/冒号清洗、[1m] 上下文标记、命名空间前缀、ISO/8位/6位日期后缀、
    /// -v<N> 版本尾、推理档后缀、claude id 的 dot→dash。上游还有一条
    /// claude-<非Anthropic系>前缀剥离,Claude Code 日志不会产生,不复刻)。
    static func pricingCandidates(_ modelId: String) -> [String] {
        var cleaned = modelId
        if let idx = cleaned.range(of: "/", options: .backwards) { cleaned = String(cleaned[idx.upperBound...]) }
        if let idx = cleaned.firstIndex(of: ":") { cleaned = String(cleaned[..<idx]) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "-").lowercased()
        if cleaned.hasSuffix("[1m]") { cleaned = String(cleaned.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        if cleaned.isEmpty || ["unknown", "null", "none"].contains(cleaned) { return [] }

        var candidates: [String] = []
        var queue = [cleaned]
        while let candidate = queue.popLast() {
            if candidate.isEmpty || candidates.contains(candidate) { continue }
            candidates.append(candidate)
            // 命名空间:内嵌 claude- 起点 / 已知厂商前缀
            if let r = candidate.range(of: "claude-", options: .backwards), r.lowerBound != candidate.startIndex {
                queue.append(String(candidate[r.lowerBound...]))
            }
            for marker in ["openai.", "anthropic.", "google.", "moonshot.", "moonshotai.", "bedrock.", "global."]
            where candidate.hasPrefix(marker) {
                queue.append(String(candidate.dropFirst(marker.count)))
            }
            if let s = stripBedrockVersionSuffix(candidate) { queue.append(s) }
            if let s = stripDateSuffix(candidate) { queue.append(s) }
            for suffix in ["-minimal", "-low", "-medium", "-high", "-xhigh"]
            where candidate.hasSuffix(suffix) && candidate.count > suffix.count {
                queue.append(String(candidate.dropLast(suffix.count)))
            }
            if candidate.hasPrefix("claude-") && candidate.contains(".") {
                queue.append(candidate.replacingOccurrences(of: ".", with: "-"))
            }
        }
        return candidates
    }

    private static func stripBedrockVersionSuffix(_ id: String) -> String? {
        guard let r = id.range(of: "-v", options: .backwards) else { return nil }
        let base = String(id[..<r.lowerBound]), suffix = String(id[r.upperBound...])
        guard !base.isEmpty, !suffix.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        return base
    }

    /// -YYYY-MM-DD / -YYYYMMDD / -YYMMDD(6 位校验月日)三种日期尾巴。
    private static func stripDateSuffix(_ id: String) -> String? {
        let chars = Array(id)
        if chars.count > 11 {
            let s = chars.suffix(11)
            let a = Array(s)
            if a[0] == "-", a[1...4].allSatisfy(\.isNumber), a[5] == "-",
               a[6...7].allSatisfy(\.isNumber), a[8] == "-", a[9...10].allSatisfy(\.isNumber) {
                return String(chars.prefix(chars.count - 11))
            }
        }
        guard let r = id.range(of: "-", options: .backwards) else { return nil }
        let base = String(id[..<r.lowerBound]), suffix = String(id[r.upperBound...])
        guard !base.isEmpty, suffix.allSatisfy(\.isNumber) else { return nil }
        if suffix.count == 8 { return base }
        if suffix.count == 6 {
            let month = Int(suffix.dropFirst(2).prefix(2)) ?? 0
            let day = Int(suffix.suffix(2)) ?? 0
            if (1...12).contains(month) && (1...31).contains(day) { return base }
        }
        return nil
    }

    /// 对齐 should_try_pricing_prefix_match(claude ≥3 段、o系 ≥1 段、常见家族 ≥2 段)。
    static func shouldTryPrefixMatch(_ id: String) -> Bool {
        let dashes = id.filter { $0 == "-" }.count
        if id.hasPrefix("claude-") { return dashes >= 3 }
        if ["o1", "o3", "o4", "o5"].contains(where: { id.hasPrefix($0) }) { return dashes >= 1 }
        let families = ["gpt-", "gemini-", "deepseek-", "qwen-", "glm-", "kimi-", "minimax-"]
        return families.contains(where: { id.hasPrefix($0) }) && dashes >= 2
    }
}
