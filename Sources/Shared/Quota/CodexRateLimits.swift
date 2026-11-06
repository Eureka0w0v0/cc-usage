import Foundation

// Codex 限额快照的**纯解析层**：~/.codex/sessions 会话文件里 token_count 事件的 rate_limits。
//
// 和 ClaudeQuotaParsing 一样从 Sources/App 拆出来：测试 target 只编 `Tests` + `Sources/Shared`
// （见 project.yml），选桶规则留在 App 里就一行都测不到。读文件那半边（按修改时间挑最多 3 个
// 会话文件、每个尾读 256KB、宽容解码）仍在 App 的 CodexQuota。

public enum CodexRateLimits {
    /// 单个限额窗口的原始快照（还没做「过了 resets_at 归零」，那一步在 CodexQuota）。
    public struct RawWindow: Equatable, Sendable {
        /// "5H" / "7D" / "30D" / 其他按时长换算
        public let label: String
        public let usedPercent: Double
        /// epoch 秒；缺省为 0（视为未知，不归零）
        public let resetsAt: TimeInterval
    }

    /// 一条 token_count 事件里的 rate_limits。
    struct Snapshot: Equatable {
        /// rate_limits.limit_id；旧版 Codex 没有这个字段时为 nil。
        let limitId: String?
        let windows: [RawWindow]
    }

    /// 按新→旧依次给出各会话文件的尾读文本，返回该展示的那组窗口；都没有快照时返回空。
    ///
    /// 选桶：一个会话里 token_count 事件会交替带不同的 limit_id——`codex` 是主额度，刷新额度时
    /// 还会用 `codex_bengalfox`、`codex_spark` 等模型专属桶把同一份 token 信息再报一遍（上游 #5854
    /// 的发现）。菜单栏码片标的是 Codex 主额度，所以优先取主桶：同一文件里比更新的模型专属桶优先，
    /// 跨文件时也比更新文件里的模型专属桶优先（过了 resets_at 的窗口在 CodexQuota 归零，旧快照不会
    /// 误导）。所有文件都没有主桶时，退回最新文件里的最后一条，也就是改前的行为。
    /// `tails` 可以是惰性序列：命中主桶就不再读后面的文件。
    public static func select<S: Sequence>(tails: S) -> [RawWindow] where S.Element == String {
        var fallback: [RawWindow]?
        for text in tails {
            let found = scan(text)
            if let primary = found.primary { return primary.windows }
            if fallback == nil { fallback = found.newest?.windows }
        }
        return fallback ?? []
    }

    /// 主桶：limit_id 为 "codex"，或旧版 Codex 根本没有这个字段。
    static func isPrimary(_ limitId: String?) -> Bool {
        guard let id = limitId, !id.isEmpty else { return true }
        return id == "codex"
    }

    /// 一段尾读文本里最新的主桶快照与最新的任意快照（从后往前找）。
    /// 首行可能是被尾读切断的残行，JSON 解析不过自然跳过。
    static func scan(_ text: String) -> (primary: Snapshot?, newest: Snapshot?) {
        var newest: Snapshot?
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let s = parse(line) else { continue }
            if newest == nil { newest = s }
            if isPrimary(s.limitId) { return (s, newest) }
        }
        return (nil, newest)
    }

    /// 行结构 {timestamp, type, payload:{type:"token_count", rate_limits:{...}}}；容错直挂顶层。
    static func parse(_ line: Substring) -> Snapshot? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        let payload = obj["payload"] as? [String: Any] ?? obj
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var windows: [RawWindow] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["used_percent"] as? Double else { continue }
            let minutes = w["window_minutes"] as? Int ?? -1
            let resets = w["resets_at"] as? Double ?? 0
            windows.append(RawWindow(label: label(minutes: minutes), usedPercent: pct, resetsAt: resets))
        }
        guard !windows.isEmpty else { return nil }
        return Snapshot(limitId: limits["limit_id"] as? String, windows: windows)
    }

    static func label(minutes: Int) -> String {
        switch minutes {
        case ..<0:  return "?"
        case 300:   return "5H"
        case 10080: return "7D"    // 不叫 W：菜单栏里 W 已是「本周用量」，撞车没法读
        case 43200: return "30D"
        default:
            return minutes % 1440 == 0 ? "\(minutes / 1440)D"
                 : "\(Int((Double(minutes) / 60).rounded()))H"
        }
    }
}
