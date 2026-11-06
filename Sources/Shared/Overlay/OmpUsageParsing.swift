import Foundation
import CryptoKit

// Oh My Pi 会话日志的逐条解析与行身份，逐条对齐上游 v4.0.22 的 Pi 引擎
// （src-tauri/src/services/session_usage_pi.rs；OMP flavor 见 session_usage_omp.rs）：
// parse_usage_record / pi_request_identity / parse_timestamp_millis / parse_costs / token_count。
// 这里只放纯函数：一条已解析的 JSON（JSONSerialization 的 NSDictionary）→ 一条用量记录或 nil。
// 文件级规则（header、续读、跨文件去重、入库剔除）在 OmpOverlay。
enum OmpUsage {
    // MARK: - Flavor 常量（session_usage_omp.rs::OMP）

    static let appType = "omp"
    static let dataSource = "omp_session"
    static let providerPlaceholder = "_omp_session"
    static let idPrefix = "omp_session"
    static let hashTag = "omp-session"
    static let label = "Oh My Pi"

    static let unknownModel = "unknown"
    static let maxUsageLabelBytes = 512
    static let maxErrorChars = 4096
    static let minSQLiteUnixMillis: Int64 = -62_167_219_200_000
    static let maxSQLiteUnixMillis: Int64 = 253_402_300_799_999

    /// 计入用量的五种条目。前两种以外的 rawValue 与上游写进哈希的 kind 逐字相同。
    enum Kind: String {
        case assistant
        case toolResult = "tool_result"
        case compaction
        case branchSummary = "branch_summary"
        case modelUsage = "model_usage"

        /// 有归属：provider / model / stopReason / errorMessage 从 carrier 取。
        var attributed: Bool { self == .assistant || self == .modelUsage }
    }

    struct Costs: Equatable {
        var input = 0.0
        var output = 0.0
        var cacheRead = 0.0
        var cacheWrite = 0.0
        var total = 0.0

        /// PiCosts::reported：total > 0 用 total，否则用四项之和；仍不大于 0 → nil（交给查价）。
        var reported: Costs? {
            let t = total > 0 ? total : input + output + cacheRead + cacheWrite
            guard t > 0 else { return nil }
            var c = self
            c.total = t
            return c
        }
    }

    struct Record: Equatable {
        var requestId: String
        var semanticId: String
        var hasEntryId: Bool
        var kind: Kind
        var providerId: String
        var model: String
        var requestModel: String
        var input: Int64
        var output: Int64
        var cacheRead: Int64
        var cacheWrite: Int64
        var costs: Costs
        var latencyMs: Int64
        var statusCode: Int64
        var errorMessage: String?
        var createdAt: Int64
        var sessionId: String
    }

    // MARK: - parse_usage_record

    /// 一条 entry → 用量记录。`sessionTimestamp` 是 header 的时间（秒），`fileTimestamp` 是文件 mtime（秒），
    /// 都只在 entry 自己没有可用时间戳时兜底。
    static func record(from entry: NSDictionary, sessionId: String,
                       sessionTimestamp: Int64?, fileTimestamp: Int64) -> Record? {
        guard let type = entry["type"] as? String else { return nil }
        let kind: Kind
        let usage: Any
        let carrier: NSDictionary?
        switch type {
        case "message":
            guard let message = entry["message"] as? NSDictionary else { return nil }
            switch message["role"] as? String {
            case "assistant": kind = .assistant
            case "toolResult": kind = .toolResult
            default: return nil
            }
            guard let u = message["usage"] else { return nil }
            usage = u
            carrier = message
        case "compaction", "branch_summary":
            guard let u = entry["usage"] else { return nil }
            kind = type == "compaction" ? .compaction : .branchSummary
            usage = u
            carrier = nil
        case "model_usage":
            // Oh My Pi 把对话之外的模型调用（自动思考判定、任务小组件等）记在这里，请求元数据在顶层。
            guard let u = entry["usage"] else { return nil }
            kind = .modelUsage
            usage = u
            carrier = entry
        default:
            return nil
        }
        let attributed = kind.attributed

        let eventMs = timestampMillis(entry["timestamp"]) ?? timestampMillis(carrier?["timestamp"])
        let usageDict = usage as? NSDictionary
        let input = tokenCount(usageDict?["input"])
        let output = tokenCount(usageDict?["output"])
        let cacheRead = tokenCount(usageDict?["cacheRead"])
        let cacheWrite = tokenCount(usageDict?["cacheWrite"])
        let costs = parseCosts(usageDict?["cost"])
        let stopReason = attributed ? nonemptyString(carrier?["stopReason"]) : nil
        let failed = stopReason == "error" || stopReason == "aborted"
        // 失败的请求即使没有用量也记一条（计入请求数、不计入成功）
        if input == 0, output == 0, cacheRead == 0, cacheWrite == 0, costs.reported == nil, !failed {
            return nil
        }

        let providerId: String
        let model: String
        let requestModel: String
        if attributed {
            guard let carrier else { return nil }
            providerId = boundedLabel(carrier["provider"], fallback: providerPlaceholder)
            let requested = boundedLabel(carrier["model"], fallback: unknownModel)
            model = nonemptyString(carrier["responseModel"]).map(truncateUsageLabel) ?? requested
            requestModel = requested
        } else {
            providerId = providerPlaceholder
            model = unknownModel
            requestModel = unknownModel
        }

        let created = eventMs.map { $0 / 1000 } ?? sessionTimestamp ?? fileTimestamp
        let createdAt = min(max(created, minSQLiteUnixMillis / 1000), maxSQLiteUnixMillis / 1000)

        var statusCode: Int64 = 200
        var errorMessage: String?
        if attributed, failed {
            let aborted = stopReason == "aborted"
            let fallback = "\(label) request \(aborted ? "aborted" : "failed")"
            let raw = nonemptyString(carrier?["errorMessage"]) ?? fallback
            errorMessage = String(String.UnicodeScalarView(raw.unicodeScalars.prefix(maxErrorChars)))
            statusCode = aborted ? 499 : 500
        }

        let id = identity(entry: entry, kind: kind, usage: usage, carrier: carrier)
        return Record(requestId: id.requestId, semanticId: id.semanticId, hasEntryId: id.hasEntryId,
                      kind: kind, providerId: providerId, model: model, requestModel: requestModel,
                      input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite,
                      costs: costs,
                      latencyMs: attributed ? latency(entry: entry, carrier: carrier) : 0,
                      statusCode: statusCode, errorMessage: errorMessage,
                      createdAt: createdAt, sessionId: sessionId)
    }

    /// Oh My Pi 在调用上记了实测的 `duration`（毫秒，含首字等待）：四舍五入后落在合理区间才用；
    /// 否则用 carrier 的 timestamp（请求开始）到 entry 的 timestamp（写入时刻）的差值估。都不行记 0。
    private static func latency(entry: NSDictionary, carrier: NSDictionary?) -> Int64 {
        if let d = positiveRoundedMillis(carrier?["duration"]), let l = SessionTiming.plausibleLatency(d) {
            return l
        }
        guard let start = timestampMillis(carrier?["timestamp"]),
              let end = timestampMillis(entry["timestamp"]) else { return 0 }
        let (diff, overflow) = end.subtractingReportingOverflow(start)
        return overflow ? 0 : SessionTiming.plausibleLatency(diff) ?? 0
    }

    /// `as_f64().filter(> 0).map(round)`：数字（整数或浮点，布尔不算）大于 0 才取，四舍五入（远离零）。
    private static func positiveRoundedMillis(_ value: Any?) -> Int64? {
        guard let n = number(value) else { return nil }
        let d = n.doubleValue
        guard d > 0 else { return nil }
        return Int64(exactly: d.rounded())
    }

    // MARK: - 字段读取（逐条对齐上游的小函数）

    /// JSON 数字（布尔不算——JSONSerialization 把 true/false 也桥成 NSNumber）。
    static func number(_ value: Any?) -> NSNumber? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n
    }

    /// 整数型的 JSON 数字（不含浮点）。JSONSerialization 对整数给 q / Q，对带小数点或指数的给 d，
    /// 与 serde_json 的 PosInt / NegInt / Float 分类一致。
    private static func integer(_ value: Any?) -> (signed: Int64?, unsigned: UInt64?)? {
        guard let n = number(value), !CFNumberIsFloatType(n) else { return nil }
        if String(cString: n.objCType) == "Q" { return (nil, n.uint64Value) }
        return (n.int64Value, nil)
    }

    /// token_count：`as_u64()`（非负整数；浮点、负数、布尔都算 0），再钳到 u32 上限。
    static func tokenCount(_ value: Any?) -> Int64 {
        guard let i = integer(value) else { return 0 }
        let u: UInt64
        if let unsigned = i.unsigned {
            u = unsigned
        } else if let signed = i.signed, signed >= 0 {
            u = UInt64(signed)
        } else {
            return 0
        }
        return Int64(min(u, UInt64(UInt32.max)))
    }

    /// parse_timestamp_millis（Pi 引擎版）：整数在 ±1e11 以内按秒、否则按毫秒；字符串按 RFC 3339；
    /// 浮点、布尔、其他一律无效；结果超出 SQLite 能表示的范围也无效。
    static func timestampMillis(_ value: Any?) -> Int64? {
        let ms: Int64
        if let i = integer(value) {
            let t: Int64
            if let signed = i.signed {
                t = signed
            } else if let unsigned = i.unsigned, unsigned <= UInt64(Int64.max) {
                t = Int64(unsigned)
            } else {
                return nil
            }
            ms = (-100_000_000_000...100_000_000_000).contains(t) ? t * 1000 : t
        } else if number(value) != nil {
            return nil
        } else if let s = value as? String, let parsed = RFC3339.epochMillis(s) {
            ms = parsed
        } else {
            return nil
        }
        return (minSQLiteUnixMillis...maxSQLiteUnixMillis).contains(ms) ? ms : nil
    }

    /// parse_costs：每项取数字或数字字符串，负数按 0。
    static func parseCosts(_ value: Any?) -> Costs {
        let cost = value as? NSDictionary
        func amount(_ key: String) -> Double { max(0, decimal(cost?[key]) ?? 0) }
        return Costs(input: amount("input"), output: amount("output"), cacheRead: amount("cacheRead"),
                     cacheWrite: amount("cacheWrite"), total: amount("total"))
    }

    /// parse_decimal：数字原样；字符串按十进制或科学计数法解析（不认十六进制、inf、nan）。
    private static func decimal(_ value: Any?) -> Double? {
        if let n = number(value) {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        guard let s = value as? String, !s.lowercased().contains("x"),
              let d = Double(s), d.isFinite else { return nil }
        return d
    }

    /// nonempty_string：字符串、去掉首尾空白（Unicode White_Space，同 Rust `str::trim`）后非空。
    static func nonemptyString(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let scalars = s.unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return nil }
        return String(scalars[first...last])
    }

    /// bounded_label：非空字符串或兜底值，截到 512 字节。
    static func boundedLabel(_ value: Any?, fallback: String) -> String {
        truncateUsageLabel(nonemptyString(value) ?? fallback)
    }

    /// truncate_usage_label：超过 512 字节时在不切断字符的前提下截断。
    static func truncateUsageLabel(_ s: String) -> String {
        guard s.utf8.count > maxUsageLabelBytes else { return s }
        var bytes = 0
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            let width = UTF8.width(scalar)
            guard bytes + width <= maxUsageLabelBytes else { break }
            bytes += width
            out.append(scalar)
        }
        return String(out)
    }

    /// pi-subagents 投影（带 usage 的 toolResult）里引用的子会话文件（details 里所有 `sessionFile` 字符串）。
    /// 这些文件都已在本轮导入时，投影就是重复计数，要跳过（duplicates_imported_sessions）。
    static func projectionSessionFiles(_ entry: NSDictionary) -> [String] {
        guard entry["type"] as? String == "message",
              let message = entry["message"] as? NSDictionary,
              message["role"] as? String == "toolResult", message["usage"] != nil,
              let details = message["details"] else { return [] }
        var links: [String] = []
        collectSessionFiles(details, into: &links)
        return links
    }

    private static func collectSessionFiles(_ value: Any, into links: inout [String]) {
        if let object = value as? NSDictionary {
            for (key, field) in object {
                if key as? String == "sessionFile", let link = field as? String {
                    links.append(link)
                } else {
                    collectSessionFiles(field, into: &links)
                }
            }
        } else if let array = value as? NSArray {
            for item in array { collectSessionFiles(item, into: &links) }
        }
    }

    // MARK: - pi_request_identity

    /// semantic_id 只看内容（同一条用量被复制进别的会话文件时相同）；request_id 有 entry id 时由
    /// 「种类 + id + 顶层 timestamp」决定，没有 entry id 时等于 semantic_id。标签与版本号和上游逐字相同——
    /// 上游的去重账本是持久的，这两个值变了就会和账本对不上。
    static func identity(entry: NSDictionary, kind: Kind, usage: Any, carrier: NSDictionary?)
        -> (requestId: String, semanticId: String, hasEntryId: Bool) {
        var semantic = CanonicalHasher()
        semantic.field("\(hashTag)-semantic-v1")
        semantic.field(kind.rawValue)
        for (label, value) in [("entry_timestamp", entry["timestamp"]),
                               ("message_timestamp", carrier?["timestamp"])] {
            if let value {
                semantic.field(label)
                semantic.json(value)
            }
        }
        if let carrier {
            for key in ["provider", "model", "responseModel", "responseId", "api",
                        "toolCallId", "toolName", "stopReason", "errorMessage"] {
                if let value = carrier[key] {
                    semantic.field(key)
                    semantic.json(value)
                }
            }
            if let content = carrier["content"] {
                semantic.field("content")
                semantic.json(content)
            }
        } else if let summary = entry["summary"] {
            semantic.field("summary")
            semantic.json(summary)
        }
        semantic.field("usage")
        semantic.json(usage)
        let semanticId = "\(idPrefix)_semantic:\(semantic.hexDigest())"

        guard let entryId = nonemptyString(entry["id"]) else { return (semanticId, semanticId, false) }
        var request = CanonicalHasher()
        request.field("\(hashTag)-request-v3")
        request.field(kind.rawValue)
        request.field(entryId)
        if let timestamp = entry["timestamp"] { request.json(timestamp) }
        return ("\(idPrefix):\(request.hexDigest())", semanticId, true)
    }
}

/// 上游 `hash_field` / `hash_json` 的移植：每个字段前缀 8 字节大端长度；JSON 按类型编码，对象键按 UTF-8
/// 字节序排序；数字按 serde_json 的输出（整数原样，浮点见 RyuFormat）。
///
/// 已知边角差异：JSON 里写成 `-0` 的数，serde_json 解析成浮点 -0.0（输出 "-0.0"），JSONSerialization
/// 给整数 0（输出 "0"）。只影响含 `-0` 且没有 entry id 的条目的 semantic_id。
struct CanonicalHasher {
    private var sha = SHA256()

    mutating func field(_ s: String) {
        var s = s
        s.withUTF8 { field(bytes: UnsafeRawBufferPointer($0)) }
    }

    mutating func field(bytes: UnsafeRawBufferPointer) {
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { sha.update(bufferPointer: $0) }
        sha.update(bufferPointer: bytes)
    }

    /// `hash_field(&(len as u64).to_be_bytes())`：长度本身作为一个 8 字节字段。
    private mutating func lengthField(_ count: Int) {
        var be = UInt64(count).bigEndian
        withUnsafeBytes(of: &be) { field(bytes: $0) }
    }

    mutating func json(_ value: Any) {
        switch value {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                field("bool")
                field(n.boolValue ? "true" : "false")
            } else if CFNumberIsFloatType(n) {
                field("number")
                field(RyuFormat.string(n.doubleValue))
            } else {
                field("number")
                field(n.stringValue)
            }
        case let s as String:
            field("string")
            field(s)
        case let array as NSArray:
            field("array")
            lengthField(array.count)
            for item in array { json(item) }
        case let object as NSDictionary:
            field("object")
            lengthField(object.count)
            let keys = object.allKeys.compactMap { $0 as? String }
                .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for key in keys {
                field(key)
                json(object[key] as Any)
            }
        default:
            // NSNull（JSONSerialization 只会产出以上几种）
            field("null")
        }
    }

    func hexDigest() -> String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out = [UInt8]()
        out.reserveCapacity(64)
        for byte in sha.finalize() {
            out.append(digits[Int(byte >> 4)])
            out.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// serde_json（1.0.149，上游 v4.0.22 锁定的版本）输出 f64 的格式：最短往返数字，再按十进制指数选排版——
/// 整数值且不超过 16 位写成 `100.0`；小数点落在前 16 位内写成 `12.34`；1e-5 及以上的小数写成 `0.0000846`；
/// 其余用科学计数法，正指数带加号：`5e-7`、`1e+16`、`1.2345678901234568e+17`。以上排版规则逐条用上游
/// 实际输出核对过（见 OmpUsageParsingTests）。最短数字取自 Swift 的 description（同为最短往返）。
///
/// 已知差异：serde_json 默认的浮点解析不保证就近舍入（有效数字超过 2^53 时先转成 f64 再除以 10 的幂，
/// 会二次舍入，如 `9007199254740993.0` 它解析成 …994，JSONSerialization 给 …992）。只影响没有 entry id、
/// usage 里又有 17 位有效数字浮点的条目的 semantic_id；Oh My Pi 的条目都有 id，request_id 不经过这里。
enum RyuFormat {
    static func string(_ d: Double) -> String {
        guard d != 0 else { return d.sign == .minus ? "-0.0" : "0.0" }
        let text = "\(d.magnitude)"
        var mantissa = Substring(text)
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<e]
            exponent = Int(text[text.index(after: e)...]) ?? 0
        }
        let parts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let fraction = parts.count > 1 ? parts[1] : ""
        var digits = Array((parts[0] + fraction).utf8)
        var k = exponent - fraction.count
        while digits.count > 1, digits.first == UInt8(ascii: "0") { digits.removeFirst() }
        while digits.count > 1, digits.last == UInt8(ascii: "0") {
            digits.removeLast()
            k += 1
        }
        let n = digits.count
        let kk = n + k   // 10^(kk-1) <= |d| < 10^kk
        let all = String(decoding: digits, as: UTF8.self)
        let body: String
        if k >= 0, kk <= 16 {
            body = all + String(repeating: "0", count: k) + ".0"
        } else if kk > 0, kk <= 16 {
            body = all.prefix(kk) + "." + all.dropFirst(kk)
        } else if kk > -5, kk <= 0 {
            body = "0." + String(repeating: "0", count: -kk) + all
        } else {
            let e = kk - 1
            let exp = e > 0 ? "e+\(e)" : "e\(e)"
            body = n == 1 ? all + exp : all.prefix(1) + "." + all.dropFirst(1) + exp
        }
        return (d.sign == .minus ? "-" : "") + body
    }
}
