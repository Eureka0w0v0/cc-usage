import Foundation

/// Claude Code 会话日志单行的解析和保留规则，逐条对齐 session_usage.rs（比照 OmpUsage 的拆法）。
/// 纯函数：SessionOverlay 只管读到哪一行、把结果放哪。
enum ClaudeUsage {
    /// 一行计费回复。
    struct Entry: Equatable {
        var messageId: String
        var model: String
        var createdAt: Int64
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheCreation: Int64
        /// 缓存写入里 1 小时那部分（对齐上游 claude_cache_creation_1h_tokens）
        var cacheCreation1h: Int64
        var hasStop: Bool
    }

    /// 与 cc-switch 补录时写的 request_id 同一命名空间（SESSION_REQUEST_ID_PREFIX + message.id）。
    static func requestId(_ messageId: String) -> String { "session:" + messageId }

    /// 单行 JSON → 一行计费回复；不命中计费条件时返回 nil。`now` 只在时间戳解析失败时才取。
    ///
    /// 走 NSDictionary 而非 `as? [String: Any]`:后者会把整棵子树递归桥接成 Swift
    /// 字典,而 message 里挂着整段回复正文——我们只要几个标量字段。
    static func entry(_ obj: NSDictionary, now: () -> Int64) -> Entry? {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? NSDictionary,
              let msgId = message["id"] as? String,
              let usage = message["usage"] as? NSDictionary
        else { return nil }

        let input = int64(usage["input_tokens"])
        let output = int64(usage["output_tokens"])
        let cacheRead = int64(usage["cache_read_input_tokens"])
        let cacheCreation = int64(usage["cache_creation_input_tokens"])
        let cacheCreation1h = int64((usage["cache_creation"] as? NSDictionary)?["ephemeral_1h_input_tokens"])
        // 任一计费维度 > 0 才计入(对齐上游 has_billable_tokens)
        guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { return nil }

        return Entry(messageId: msgId, model: (message["model"] as? String) ?? "unknown",
                     createdAt: (obj["timestamp"] as? String).flatMap(ISO8601Lenient.epochSeconds) ?? now(),
                     input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation,
                     cacheCreation1h: cacheCreation1h,
                     hasStop: (message["stop_reason"] as? String) != nil)
    }

    /// message.id 去重:stop_reason 优先,同级取 output 更大者(对齐上游)。
    static func replaces(hasStop: Bool, output: Int64, oldHasStop: Bool, oldOutput: Int64) -> Bool {
        (hasStop && !oldHasStop) || (hasStop == oldHasStop && output > oldOutput)
    }

    private static func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }
}
