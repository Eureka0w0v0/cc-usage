import Foundation

/// Codex（ChatGPT）限额快照：从 ~/.codex/sessions 最新会话文件的 token_count 事件里
/// 提取 rate_limits（used_percent / window_minutes / resets_at）。纯本地读文件，不联网。
///
/// 注意语义：快照是「最后一次用 Codex 时」的值——窗口过了 resets_at 即已重置，
/// 此时按 0% 展示，避免陈旧百分比误导。窗口标签按 window_minutes 自适应
/// （Plus/Pro = 5H + 周，Free = 30 天），不写死档位。
enum CodexQuota {
    struct Window: Equatable, Sendable {
        let label: String        // "5H" / "W" / "30D" / 其他按时长换算
        let usedPercent: Double
    }

    private struct Raw { let label: String; let pct: Double; let resetsAt: TimeInterval }

    private static let lock = NSLock()
    private static var cache: (at: Date, raw: [Raw])?

    /// 最新限额窗口列表；没装过 Codex / 找不到快照返回空。整个扫描 30s 节流
    /// （reload 每 5s 一次，尾读文件虽便宜也不必每轮都做）。
    static func latest(now: Date = Date()) -> [Window] {
        lock.lock(); defer { lock.unlock() }
        if let c = cache, now.timeIntervalSince(c.at) < 30 {
            return zeroed(c.raw, now: now)
        }
        let raw = scan()
        cache = (now, raw)
        return zeroed(raw, now: now)
    }

    /// 过了 resets_at 的窗口归零（窗口已重置，真实用量从 0 重新累计）。
    private static func zeroed(_ raw: [Raw], now: Date) -> [Window] {
        raw.map { w in
            let reset = w.resetsAt > 0 && now.timeIntervalSince1970 > w.resetsAt
            return Window(label: w.label, usedPercent: reset ? 0 : w.pct)
        }
    }

    /// 按修改时间新→旧翻最多 3 个会话文件（最新会话可能尚未产生 token_count 事件），
    /// 每个只尾读 256KB，从后往前找最后一条 rate_limits。
    private static func scan() -> [Raw] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                     options: [.skipsHiddenFiles]) else { return [] }
        var files: [(URL, Date)] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            files.append((url, m))
        }
        for (url, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(3) {
            if let raw = lastRateLimits(in: url) { return raw }
        }
        return []
    }

    private static func lastRateLimits(in file: URL) -> [Raw]? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 1 << 18
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            if let raw = parse(String(line)) { return raw }
        }
        return nil
    }

    private static func parse(_ line: String) -> [Raw]? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // 行结构 {timestamp, type, payload:{type:"token_count", rate_limits:{...}}}；容错直挂顶层
        let payload = obj["payload"] as? [String: Any] ?? obj
        guard let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        var out: [Raw] = []
        for key in ["primary", "secondary"] {
            guard let w = limits[key] as? [String: Any],
                  let pct = w["used_percent"] as? Double else { continue }
            let minutes = w["window_minutes"] as? Int ?? -1
            let resets = w["resets_at"] as? Double ?? 0
            out.append(Raw(label: label(minutes), pct: pct, resetsAt: resets))
        }
        return out.isEmpty ? nil : out
    }

    private static func label(_ minutes: Int) -> String {
        switch minutes {
        case ..<0:  return "?"
        case 300:   return "5H"
        case 10080: return "W"
        case 43200: return "30D"
        default:
            return minutes % 1440 == 0 ? "\(minutes / 1440)D"
                 : "\(Int((Double(minutes) / 60).rounded()))H"
        }
    }
}
