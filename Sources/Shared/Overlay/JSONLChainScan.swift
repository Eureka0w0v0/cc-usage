import Foundation

// 对话链行的快扫。估请求起点要把每一行（用户消息、工具结果、attachment）记进对话链，但只用得到顶层的
// uuid / parentUuid / timestamp / type 四个字段。这些行里工具结果、带图片的消息占了日志七成字节，为四个
// 短字段整行 JSONSerialization 太贵（冷启动全量重扫几百 MB 日志要多花约 1 秒）。这里只走顶层对象：字符串按转义找收尾
// 引号、对象和数组按深度整段跳过，不建任何 Foundation 对象。
//
// 只在有把握时给出结果，其余一律 .needsFullParse 交回整行解析，保证与整行解析的结果完全一致：
//   * 键或要取的值里有转义（得先解码才知道是什么，Claude Code 不会这么写）；
//   * assistant 行（还要记回复计时，见 ClaudeTimingTracker.record）；
//   * 结构不完整（半行）、顶层不是对象、对象后面还有别的字符。
// 本机全部会话日志里的对话链行（约 3GB）与整行解析逐行对拍零差异，快 35 倍（2026-10-16）。
extension JSONLScan {
    /// 对话链只用得到的四个顶层字段。值不是字符串时为 nil（上游 as_str 取不到，等于没有这个字段）。
    struct ChainFields: Equatable {
        var uuid: String?
        var parentUuid: String?
        var timestamp: String?
        var type: String?
    }

    enum ChainScan: Equatable {
        case fields(ChainFields)
        /// 快扫不了或不该快扫，交给 JSONSerialization 整行解析。
        case needsFullParse
    }

    static func chainFields(_ raw: UnsafeRawPointer, _ len: Int) -> ChainScan {
        let p = raw.assumingMemoryBound(to: UInt8.self)
        var i = skipSpace(p, 0, len)
        guard i < len, p[i] == ascii("{") else { return .needsFullParse }
        i = skipSpace(p, i + 1, len)
        var fields = ChainFields()
        if i < len, p[i] == ascii("}") {
            return skipSpace(p, i + 1, len) == len ? .fields(fields) : .needsFullParse
        }
        while true {
            guard i < len, p[i] == ascii("\""), let keyEnd = stringEnd(p, i + 1, len),
                  !containsBackslash(p, i + 1, keyEnd) else { return .needsFullParse }
            let key = ChainKey(p + i + 1, keyEnd - i - 1)
            i = skipSpace(p, keyEnd + 1, len)
            guard i < len, p[i] == ascii(":") else { return .needsFullParse }
            i = skipSpace(p, i + 1, len)
            guard i < len else { return .needsFullParse }

            var value: String?
            if p[i] == ascii("\"") {
                guard let valueEnd = stringEnd(p, i + 1, len) else { return .needsFullParse }
                if key != nil {
                    guard !containsBackslash(p, i + 1, valueEnd) else { return .needsFullParse }
                    value = String(decoding: UnsafeBufferPointer(start: p + i + 1, count: valueEnd - i - 1),
                                   as: UTF8.self)
                }
                i = valueEnd + 1
            } else {
                guard let next = skipNonString(p, i, len) else { return .needsFullParse }
                i = next
            }
            // 同名键后出现的覆盖先出现的（与整行解析成字典时一样）
            switch key {
            case .uuid?: fields.uuid = value
            case .parentUuid?: fields.parentUuid = value
            case .timestamp?: fields.timestamp = value
            case .type?: fields.type = value
            case nil: break
            }

            i = skipSpace(p, i, len)
            guard i < len else { return .needsFullParse }
            if p[i] == ascii(",") {
                i = skipSpace(p, i + 1, len)
                continue
            }
            guard p[i] == ascii("}"), skipSpace(p, i + 1, len) == len else { return .needsFullParse }
            return fields.type == "assistant" ? .needsFullParse : .fields(fields)
        }
    }

    private enum ChainKey {
        case uuid, parentUuid, timestamp, type

        init?(_ p: UnsafePointer<UInt8>, _ n: Int) {
            func equals(_ s: StaticString) -> Bool {
                s.utf8CodeUnitCount == n && memcmp(p, s.utf8Start, n) == 0
            }
            if equals("uuid") { self = .uuid }
            else if equals("parentUuid") { self = .parentUuid }
            else if equals("timestamp") { self = .timestamp }
            else if equals("type") { self = .type }
            else { return nil }
        }
    }

    private static func ascii(_ c: Unicode.Scalar) -> UInt8 { UInt8(ascii: c) }

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A }

    private static func skipSpace(_ p: UnsafePointer<UInt8>, _ from: Int, _ len: Int) -> Int {
        var i = from
        while i < len, isSpace(p[i]) { i += 1 }
        return i
    }

    private static func containsBackslash(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int) -> Bool {
        memchr(p + from, Int32(ascii("\\")), to - from) != nil
    }

    /// 字符串内容从 from 开始，返回收尾引号的下标：找下一个引号，它前面连续的反斜杠是奇数个就是被转义的，接着找。
    private static func stringEnd(_ p: UnsafePointer<UInt8>, _ from: Int, _ len: Int) -> Int? {
        var i = from
        while i < len, let hit = memchr(p + i, Int32(ascii("\"")), len - i) {
            let at = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - p
            var backslashes = 0
            while at - 1 - backslashes >= from, p[at - 1 - backslashes] == ascii("\\") { backslashes += 1 }
            if backslashes % 2 == 0 { return at }
            i = at + 1
        }
        return nil
    }

    /// 跳过一个不是字符串的值（对象、数组、数字、true / false / null），返回值之后的下标；结构不完整返回 nil。
    private static func skipNonString(_ p: UnsafePointer<UInt8>, _ from: Int, _ len: Int) -> Int? {
        guard p[from] == ascii("{") || p[from] == ascii("[") else {
            var i = from
            while i < len, !isSpace(p[i]), p[i] != ascii(","), p[i] != ascii("}"), p[i] != ascii("]") {
                if p[i] == ascii("\"") || p[i] == ascii("{") || p[i] == ascii("[") { return nil }
                i += 1
            }
            return i > from ? i : nil
        }
        var depth = 0
        var i = from
        while i < len {
            switch p[i] {
            case ascii("\""):
                guard let end = stringEnd(p, i + 1, len) else { return nil }
                i = end
            case ascii("{"), ascii("["):
                depth += 1
            case ascii("}"), ascii("]"):
                depth -= 1
                if depth == 0 { return i + 1 }
            default:
                break
            }
            i += 1
        }
        return nil
    }
}
