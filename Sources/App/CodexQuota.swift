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

    private typealias Raw = CodexRateLimits.RawWindow

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
            return Window(label: w.label, usedPercent: reset ? 0 : w.usedPercent)
        }
    }

    /// 按修改时间新→旧翻最多 3 个会话文件（最新会话可能尚未产生 token_count 事件），
    /// 每个只尾读 256KB；选哪条快照由 Shared/CodexRateLimits.select 决定（可测）。
    /// tails 是惰性序列：选到结果就不再读后面的文件。
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
        let tails = files.sorted(by: { $0.1 > $1.1 }).prefix(3).lazy.compactMap { tailText(of: $0.0) }
        return CodexRateLimits.select(tails: tails)
    }

    private static func tailText(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let tail: UInt64 = 1 << 18
        try? handle.seek(toOffset: size > tail ? size - tail : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        // 尾读从任意字节偏移开始，必然可能切断多字节 UTF-8（会话里有中日文时概率很高）。
        // String(data:encoding:) 遇到非法序列返回 nil → 整个最新会话被判成「无 rate_limits」，
        // 回落到更旧的文件显示过期百分比，甚至三个都切坏时显示 "—"。改用永不失败的解码：
        // 被破坏的首行本来就是残行，parse 时 JSON 解析不过自然跳过。
        return String(decoding: data, as: UTF8.self)
    }
}
