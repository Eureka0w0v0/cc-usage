import Foundation

// 会话日志的请求计时，逐条对齐 cc-switch v4.0.12 session_usage.rs（estimated_latency_ms /
// estimated_first_token_ms / ChainNodes / MessageTiming / resolve_request_start_ms，以及
// refresh_session_log_entry_on_conn 的合并规则）。
//
// 会话日志没有请求计时，只能拿时间戳相减估出来：
//   * 耗时 = 回复各块写完时刻里最晚的 − 请求起点。起点从回复第一块的父行往上找，跳过 attachment，取第一个
//     用户消息 / 工具结果的时间戳。含首字等待，所以是估算值；
//   * 首字 = 第一块是思考块时，块写完的时刻 − thinkingDurationMs − 请求起点。第一块是文字或工具调用时，块的
//     时间戳只是它写完的时刻，推不出首字。
// 落在合理范围外的不要：耗时记 0、首字为 nil，界面显示「—」——与库里 latency_ms / first_token_ms 的约定相同。
//
// SessionOverlay 给每个还有未入库内容的文件留一个 ClaudeTimingTracker：从 db 游标起读时先喂游标前最多 256KB 的
// 回看窗口，之后每读一段接着喂这一段的每一行；这一段里出现过的回复各估一次，再按 merged 的规则并进已有的行。OmpOverlay 不用估（OMP 自己记了
// duration / ttft），只借用这里的合理范围。
enum SessionTiming {
    /// 估算出的请求耗时短于这个毫秒数就不要：真实请求不可能这么快，多半是起点取错了。
    static let minPlausibleLatencyMs: Int64 = 100
    /// 长于这个毫秒数也不要：中间多半夹了休眠或长时间的重试等待。
    static let maxPlausibleLatencyMs: Int64 = 60 * 60 * 1000
    /// 增量读取时往读取起点前回看的字节数（上游 CHAIN_SEED_BYTES）。回复的第一块常常紧跟在读取起点后面，
    /// 它的起点行（用户消息、工具结果）却在前面；起点行比这还远（比如中间夹了带图片的工具结果）的那条不估。
    static let chainSeedBytes: Int64 = 256 * 1024
    /// 找请求起点时沿父链往上最多走这么多行（上游 MAX_CHAIN_HOPS）。
    static let maxChainHops = 32

    /// 一条请求的计时：耗时（含首字等待）和首字（推不出来为 nil）。
    struct Estimate: Equatable {
        var latencyMs: Int64
        var firstTokenMs: Int64?
    }

    /// 耗时落在 [100ms, 1h] 里才要。
    static func plausibleLatency(_ ms: Int64) -> Int64? {
        (minPlausibleLatencyMs...maxPlausibleLatencyMs).contains(ms) ? ms : nil
    }

    /// 首字必须落在 (0, 耗时]，否则说明起点或首字取错了。
    static func plausibleFirstToken(_ ms: Int64, latency: Int64) -> Int64? {
        ms > 0 && ms <= latency ? ms : nil
    }

    /// 起点到结束（estimated_latency_ms）。相减溢出同样不要。
    static func latency(start: Int64, end: Int64) -> Int64? {
        let (ms, overflow) = end.subtractingReportingOverflow(start)
        return overflow ? nil : plausibleLatency(ms)
    }

    /// 起点到开始输出（estimated_first_token_ms）。
    static func firstToken(start: Int64, firstOutput: Int64, latency: Int64) -> Int64? {
        let (ms, overflow) = firstOutput.subtractingReportingOverflow(start)
        return overflow ? nil : plausibleFirstToken(ms, latency: latency)
    }

    /// 一行已有的计时并上这一轮新估的：耗时取大——后面的块到了，回复结束得更晚；首字只看第一块，先前有的
    /// 不覆盖、没推出来的才补；这一轮估不出来就原样保留。耗时 0 = 没有计时。
    static func merged(latencyMs: Int64, firstTokenMs: Int64?, with new: Estimate?)
        -> (latencyMs: Int64, firstTokenMs: Int64?) {
        guard let new else { return (latencyMs, firstTokenMs) }
        return (max(new.latencyMs, latencyMs), firstTokenMs ?? new.firstTokenMs)
    }

    /// JSON 里的整数（serde_json 的 as_i64）：布尔、带小数的都不算。NSDecimalNumber 先挡掉，
    /// 别让它进下面的 CFNumber 判断。
    static func jsonInteger(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, !(n is NSDecimalNumber),
              CFGetTypeID(n) != CFBooleanGetTypeID(), !CFNumberIsFloatType(n) else { return nil }
        return n.int64Value
    }

    /// JSON 里的毫秒数（可以带小数），四舍五入到整毫秒。布尔、字符串、非有限值、装不进 Int64 的都不算。
    static func jsonMillis(_ value: Any?) -> Int64? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let rounded = n.doubleValue.rounded()
        guard rounded.isFinite else { return nil }
        return Int64(exactly: rounded)
    }
}

/// 一个文件从 db 游标读到现在的对话链和回复计时（对齐 session_usage.rs 的 ChainNodes / MessageTiming）。
/// 由 SessionOverlay 跨刷新 tick 保留、续读时接着往里加，进度重建（db 游标推进、文件被重写或消失）时丢掉。
struct ClaudeTimingTracker {
    /// 一行日志在对话链上的位置，只留估算请求耗时用得到的三样。
    private struct ChainNode {
        var parent: UUID?
        var timestampMs: Int64?
        /// attachment 行的时间戳不可靠（有的是回复开始后才补记的），找请求起点时跳过。
        var isAttachment: Bool
    }

    /// 一条回复（同一个 message.id 的所有内容块）的计时线索。
    private struct MessageTiming {
        /// 最先出现的那一块的父行，请求起点沿它往上找。
        var firstParent: UUID?
        /// 最先出现的那一块是不是这条回复的第一块（apiBlockIndex 为 0；旧版日志没有这个字段，按是处理）。
        /// 不是的话（前面的块在回看窗口外）起点会取晚、速度偏高，宁可不估。
        var startsAtFirstBlock: Bool
        /// 回复开始输出的时刻：第一块是思考块时，用块写完的时刻减去 thinkingDurationMs。
        var firstOutputMs: Int64?
        /// 各块写完时刻里最晚的一个，即回复结束。
        var endMs: Int64?
    }

    private var chain: [UUID: ChainNode] = [:]
    private var timings: [String: MessageTiming] = [:]

    /// 记一行完整解析过的日志：带 uuid 的进对话链（record_chain_node）；assistant 行再记进所属回复的计时
    /// （record_block_timing）——最先出现的块定起点，各块里最晚的定结束。
    mutating func record(_ obj: NSDictionary) {
        let type = obj["type"] as? String
        let timestampMs = (obj["timestamp"] as? String).flatMap(RFC3339.epochMillis)
        recordChainNode(uuid: obj["uuid"] as? String, parentUuid: obj["parentUuid"] as? String,
                        timestampMs: timestampMs, isAttachment: type == "attachment")
        guard type == "assistant",
              let msgId = (obj["message"] as? NSDictionary)?["id"] as? String else { return }
        var timing = timings[msgId] ?? Self.firstSeen(obj, blockEndMs: timestampMs)
        timing.endMs = Self.later(timing.endMs, timestampMs)
        timings[msgId] = timing
    }

    /// 记一行快扫出来的链信息（JSONLScan.chainFields；assistant 行不走快扫，所以这里只有对话链）。
    mutating func record(_ fields: JSONLScan.ChainFields) {
        recordChainNode(uuid: fields.uuid, parentUuid: fields.parentUuid,
                        timestampMs: fields.timestamp.flatMap(RFC3339.epochMillis),
                        isAttachment: fields.type == "attachment")
    }

    private mutating func recordChainNode(uuid: String?, parentUuid: String?, timestampMs: Int64?,
                                          isAttachment: Bool) {
        guard let id = Self.uuid(uuid) else { return }
        chain[id] = ChainNode(parent: Self.uuid(parentUuid), timestampMs: timestampMs, isAttachment: isAttachment)
    }

    /// 这条回复的计时：只给写完了的回复算（这一段读到的代表行带 stop_reason），而且要看得到它的第一块；
    /// 估不出来为 nil。
    func estimate(messageId: String, hasStopReason: Bool) -> SessionTiming.Estimate? {
        guard hasStopReason, let timing = timings[messageId], timing.startsAtFirstBlock,
              let start = requestStartMs(timing.firstParent), let end = timing.endMs,
              let latency = SessionTiming.latency(start: start, end: end) else { return nil }
        let firstToken = timing.firstOutputMs.flatMap {
            SessionTiming.firstToken(start: start, firstOutput: $0, latency: latency)
        }
        return SessionTiming.Estimate(latencyMs: latency, firstTokenMs: firstToken)
    }

    /// 请求起点：从回复第一块的父行往上，跳过 attachment，第一个别的行（用户消息、工具结果、出错重试的
    /// system 行）的时间戳（resolve_request_start_ms）。最多走 maxChainHops 行。
    private func requestStartMs(_ firstParent: UUID?) -> Int64? {
        var cursor = firstParent
        for _ in 0..<SessionTiming.maxChainHops {
            guard let id = cursor, let node = chain[id] else { return nil }
            if !node.isAttachment { return node.timestampMs }
            cursor = node.parent
        }
        return nil
    }

    private static func firstSeen(_ obj: NSDictionary, blockEndMs: Int64?) -> MessageTiming {
        let index = obj["apiBlockIndex"]
        let startsAtFirstBlock = index == nil || SessionTiming.jsonInteger(index) == 0
        return MessageTiming(
            firstParent: uuid(obj["parentUuid"] as? String),
            startsAtFirstBlock: startsAtFirstBlock,
            firstOutputMs: startsAtFirstBlock ? blockEndMs.flatMap { thinkingStartMs(obj, blockEndMs: $0) } : nil,
            endMs: nil)
    }

    /// 思考块开始的时刻：块写完的时刻减去 thinkingDurationMs。不是思考块、没有这个字段（旧版 Claude Code）时为 nil。
    private static func thinkingStartMs(_ obj: NSDictionary, blockEndMs: Int64) -> Int64? {
        guard let duration = SessionTiming.jsonInteger(obj["thinkingDurationMs"]), duration > 0,
              let content = (obj["message"] as? NSDictionary)?["content"] as? NSArray,
              content.count > 0,
              (content[0] as? NSDictionary)?["type"] as? String == "thinking" else { return nil }
        let (start, overflow) = blockEndMs.subtractingReportingOverflow(duration)
        return overflow ? nil : start
    }

    /// 行里的 uuid 字段（parse_line_uuid）。只认带连字符的标准写法，Claude Code 一直这么写；上游的 uuid crate
    /// 还认不带连字符、带花括号、带 urn: 前缀的写法，遇到那些写法这里只会少估一条，不会估错。
    private static func uuid(_ value: String?) -> UUID? {
        value.flatMap(UUID.init(uuidString:))
    }

    /// Option::max 的语义：nil 比任何值都小。
    private static func later(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return max(a, b)
    }
}
