import Foundation
import SQLite3

// 「未入库增量」只读叠加层。
//
// cc-switch 不在运行时,没人往 ~/.cc-switch/cc-switch.db 写数——本层直接增量
// 解析 ~/.claude/projects 的会话 JSONL(只读 cc-switch 记在 session_log_sync
// 里的行偏移**之后**的部分),按库里的 model_pricing 现场定价,在内存里把这批
// 「cc-switch 还没消化的用量」叠加到展示数字上。
//
// 安全性:全程零写入,cc-switch 永远是唯一写库方。等它回来把这些行正式入库,
// 本层按 request_id 精确去重、自动缩为空——数字无缝交接,绝不双算。
//
// 解析口径逐条对齐 cc-switch session_usage.rs:
//   * 文件收集三层:项目/*.jsonl、项目/会话/subagents/*.jsonl、
//     项目/会话/subagents/workflows/wf_*/​*.jsonl
//   * mtime(ns) <= session_log_sync.last_modified 的文件视为已全部消化
//   * 只认 type=="assistant" 且带 message.id + message.usage 的行
//   * 同一 message.id 去重:有 stop_reason 优先,同级取 output_tokens 更大者
//   * 任一计费维度(token) > 0 才计入;request_id = "session:" + message.id
//   * created_at 取顶层 RFC3339 timestamp,解析失败回落当前时间
//   * 定价:model_pricing 精确匹配 → 前缀匹配(候选生成含命名空间/日期
//     后缀/推理档后缀剥离,dot→dash),tokens × 每百万单价,倍率 1
//   * 未匹配到定价 → 成本 0(与 cc-switch 相同),tokens 照计
//
// 已知取舍:cc-switch 入库时还会做「session 行 vs 成功 proxy 行」的指纹去重
// (should_skip_session_insert)。本机没有 proxy 行,该规则恒为空操作,叠加层
// 不复刻;若用户开启代理模式,增量在 cc-switch 补录前可能与 proxy 行短暂并存。

public struct OverlayRow: Sendable {
    public var requestId: String
    public var model: String
    public var createdAt: Int64
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheCreation: Int64
    public var inputCost: Double
    public var outputCost: Double
    public var cacheReadCost: Double
    public var cacheCreationCost: Double
    public var totalCost: Double
    public var sessionId: String?
    var hasStopReason: Bool
    var sourceFile: String
}

public final class SessionOverlay {
    public static let shared = SessionOverlay()

    /// 两次真实扫描的最小间隔:一个刷新 tick 内 UsageStore 的多个查询共享同一次扫描。
    private let minRefreshInterval: TimeInterval = 2.0
    /// 定价表缓存时长(cc-switch 更新价格后最迟 5 分钟被叠加层看到)。
    private let pricingTTL: TimeInterval = 300

    private let lock = NSLock()
    private var rows: [String: OverlayRow] = [:]   // requestId → 待入库行
    private var lastRefresh: Date?

    /// 进程内续读进度(建立在 session_log_sync 偏移之上)。
    private struct FileMark {
        var mtimeNs: Int64      // 上次读完时的文件 mtime(ns)
        var bytesRead: Int64    // 已消费到的字节位置(完整行边界)
        var linesRead: Int64    // 已消费的行数(含 db 偏移内跳过的行)
        var dbOffset: Int64     // 建立本进度时 session_log_sync 的行偏移
    }
    private var marks: [String: FileMark] = [:]

    private struct Pricing { var input: Double; var output: Double; var cacheRead: Double; var cacheCreation: Double }
    private var pricingExact: [String: Pricing] = [:]
    private var pricingIds: [String] = []          // 前缀匹配用(短 id 优先)
    private var pricingLoadedAt: Date?

    private let projectsDir: String

    public init(projectsDir: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")) {
        self.projectsDir = projectsDir
    }

    // MARK: - 对外入口

    /// 返回当前「cc-switch 尚未入库」的用量行。db 为调用方已打开的只读连接,
    /// 用于读 session_log_sync / model_pricing / 已存在的 request_id。
    public func pendingRows(db: OpaquePointer) -> [OverlayRow] {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minRefreshInterval {
            return Array(rows.values)
        }
        refreshLocked(db)
        lastRefresh = Date()
        return Array(rows.values)
    }

    // MARK: - 扫描

    private func refreshLocked(_ db: OpaquePointer) {
        loadPricingIfStale(db)
        let sync = loadSyncTable(db)
        let files = collectJSONLFiles()

        var seenPaths = Set<String>()
        for path in files {
            seenPaths.insert(path)
            scanFileLocked(path, dbState: sync[path] ?? (lastModified: 0, offset: 0))
        }
        // 文件消失(会话被清理)→ 其待入库行一并移除
        let vanished = Set(marks.keys).subtracting(seenPaths)
        if !vanished.isEmpty {
            for p in vanished { marks.removeValue(forKey: p) }
            rows = rows.filter { !vanished.contains($0.value.sourceFile) }
        }
        pruneRowsAlreadyInDB(db)
    }

    /// 扫描单个文件的新增部分(对齐 sync_single_file)。
    private func scanFileLocked(_ path: String, dbState: (lastModified: Int64, offset: Int64)) {
        guard let st = statNanos(path) else { return }

        // cc-switch 已消化整个文件 → 丢掉本文件全部待入库行
        if st.mtimeNs <= dbState.lastModified {
            if marks.removeValue(forKey: path) != nil {
                rows = rows.filter { $0.value.sourceFile != path }
            }
            return
        }

        var startBytes: Int64 = 0
        var linesRead: Int64 = 0
        var skipLines = dbState.offset
        if let m = marks[path], m.dbOffset == dbState.offset, m.bytesRead <= st.size {
            // 在自己的进度上续读(不必重数 db 偏移内的行)
            startBytes = m.bytesRead
            linesRead = m.linesRead
            skipLines = 0
            if m.mtimeNs == st.mtimeNs { return }   // 内容未变
        } else {
            // db 偏移推进(cc-switch 刚跑过)或文件被重写 → 从头重建本文件的增量
            rows = rows.filter { $0.value.sourceFile != path }
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        if startBytes > 0 { try? fh.seek(toOffset: UInt64(startBytes)) }
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            marks[path] = FileMark(mtimeNs: st.mtimeNs, bytesRead: startBytes,
                                   linesRead: linesRead, dbOffset: dbState.offset)
            return
        }

        // 只消费完整行(带 \n);写了一半的最后一行留到下个 tick,
        // 避免把残缺 JSON 当作「已处理」而永久丢失(严于上游,口径不受影响)。
        var consumedBytes = startBytes
        var sessionId: String? = nil
        var idx = data.startIndex
        while idx < data.endIndex {
            guard let nl = data[idx...].firstIndex(of: 0x0A) else { break }
            let lineData = data[idx..<nl]
            idx = data.index(after: nl)
            consumedBytes = startBytes + Int64(idx - data.startIndex)
            linesRead += 1
            if skipLines > 0 && linesRead <= dbState.offset { continue }

            guard !lineData.isEmpty,
                  let obj = try? JSONSerialization.jsonObject(with: Data(lineData)) as? [String: Any]
            else { continue }

            if sessionId == nil, let sid = obj["sessionId"] as? String { sessionId = sid }
            guard obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let msgId = message["id"] as? String,
                  let usage = message["usage"] as? [String: Any]
            else { continue }

            let input = int64(usage["input_tokens"])
            let output = int64(usage["output_tokens"])
            let cacheRead = int64(usage["cache_read_input_tokens"])
            let cacheCreation = int64(usage["cache_creation_input_tokens"])
            // 任一计费维度 > 0 才计入(对齐上游 has_billable_tokens)
            guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { continue }

            let model = (message["model"] as? String) ?? "unknown"
            let hasStop = (message["stop_reason"] as? String) != nil
            let ts = (obj["timestamp"] as? String).flatMap(Self.parseRFC3339)
                ?? Int64(Date().timeIntervalSince1970)
            let requestId = "session:" + msgId

            // message.id 去重:stop_reason 优先,同级取 output 更大者(对齐上游)
            if let old = rows[requestId] {
                let replace = (hasStop && !old.hasStopReason)
                    || (hasStop == old.hasStopReason && output > old.output)
                if !replace { continue }
            }

            let p = findPricing(model)
            let ic = p.map { Double(input) * $0.input / 1_000_000 } ?? 0
            let oc = p.map { Double(output) * $0.output / 1_000_000 } ?? 0
            let crc = p.map { Double(cacheRead) * $0.cacheRead / 1_000_000 } ?? 0
            let ccc = p.map { Double(cacheCreation) * $0.cacheCreation / 1_000_000 } ?? 0

            rows[requestId] = OverlayRow(
                requestId: requestId, model: model, createdAt: ts,
                input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation,
                inputCost: ic, outputCost: oc, cacheReadCost: crc, cacheCreationCost: ccc,
                totalCost: ic + oc + crc + ccc,
                sessionId: sessionId, hasStopReason: hasStop, sourceFile: path
            )
        }

        marks[path] = FileMark(mtimeNs: st.mtimeNs, bytesRead: consumedBytes,
                               linesRead: linesRead, dbOffset: dbState.offset)
    }

    /// 已被 cc-switch 入库的行从叠加层剔除(request_id 精确去重的兜底)。
    private func pruneRowsAlreadyInDB(_ db: OpaquePointer) {
        let ids = Array(rows.keys)
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT request_id FROM proxy_request_logs WHERE request_id IN (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT_DEST)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    rows.removeValue(forKey: String(cString: c))
                }
            }
        }
    }

    // MARK: - 文件收集(对齐 collect_jsonl_files:固定三层,不递归)

    private func collectJSONLFiles() -> [String] {
        let fm = FileManager.default
        var files: [String] = []
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return files }
        for proj in projects {
            let projPath = (projectsDir as NSString).appendingPathComponent(proj)
            guard isDirectory(projPath) else { continue }
            guard let subs = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
            for sub in subs {
                let subPath = (projPath as NSString).appendingPathComponent(sub)
                if sub.hasSuffix(".jsonl") {
                    files.append(subPath)                    // 主会话
                } else if isDirectory(subPath) {
                    let subagents = (subPath as NSString).appendingPathComponent("subagents")
                    guard isDirectory(subagents) else { continue }
                    appendJSONLChildren(subagents, &files)   // 子 agent
                    let workflows = (subagents as NSString).appendingPathComponent("workflows")
                    if isDirectory(workflows),
                       let wfs = try? fm.contentsOfDirectory(atPath: workflows) {
                        for wf in wfs {                      // Workflow 子 agent
                            let wfPath = (workflows as NSString).appendingPathComponent(wf)
                            if isDirectory(wfPath) { appendJSONLChildren(wfPath, &files) }
                        }
                    }
                }
            }
        }
        return files
    }

    private func appendJSONLChildren(_ dir: String, _ files: inout [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for e in entries where e.hasSuffix(".jsonl") {
            files.append((dir as NSString).appendingPathComponent(e))
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// mtime 纳秒 + 文件大小(与上游 metadata_modified_nanos 同精度,用 stat 拿真 ns)。
    private func statNanos(_ path: String) -> (mtimeNs: Int64, size: Int64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        return (mtimeNs: ns, size: Int64(st.st_size))
    }

    // MARK: - session_log_sync / model_pricing

    private func loadSyncTable(_ db: OpaquePointer) -> [String: (lastModified: Int64, offset: Int64)] {
        var out: [String: (Int64, Int64)] = [:]
        var stmt: OpaquePointer?
        let sql = "SELECT file_path, last_modified, last_line_offset FROM session_log_sync"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            out[String(cString: c)] = (sqlite3_column_int64(stmt, 1), sqlite3_column_int64(stmt, 2))
        }
        return out
    }

    private func loadPricingIfStale(_ db: OpaquePointer) {
        if let at = pricingLoadedAt, Date().timeIntervalSince(at) < pricingTTL { return }
        var exact: [String: Pricing] = [:]
        var stmt: OpaquePointer?
        let sql = """
        SELECT model_id, input_cost_per_million, output_cost_per_million,
               cache_read_cost_per_million, cache_creation_cost_per_million FROM model_pricing
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: c)
            func col(_ i: Int32) -> Double {
                sqlite3_column_text(stmt, i).flatMap { Double(String(cString: $0)) } ?? 0
            }
            exact[id] = Pricing(input: col(1), output: col(2), cacheRead: col(3), cacheCreation: col(4))
        }
        pricingExact = exact
        pricingIds = exact.keys.sorted { $0.count < $1.count }   // 前缀匹配取最短命中,对齐 LENGTH ASC
        pricingLoadedAt = Date()
    }

    // MARK: - 定价匹配(对齐 find_model_pricing_row:候选精确匹配 → 前缀匹配)

    private func findPricing(_ modelId: String) -> Pricing? {
        let candidates = Self.pricingCandidates(modelId)
        for c in candidates {
            if let p = pricingExact[c] { return p }
        }
        for c in candidates where Self.shouldTryPrefixMatch(c) {
            // model_id LIKE 'c-%' ORDER BY LENGTH LIMIT 1(pricingIds 已按长度升序)
            if let hit = pricingIds.first(where: { $0.hasPrefix(c + "-") }) {
                return pricingExact[hit]
            }
        }
        return nil
    }

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

    // MARK: - 小工具

    private func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

    /// RFC3339 → epoch 秒(容忍小数秒)。解析逻辑与 QuotaService 共用 ISO8601Lenient
    /// (formatter 静态复用——本函数在冷启动全量扫描时逐行调用,是热路径)。
    static func parseRFC3339(_ s: String) -> Int64? {
        ISO8601Lenient.date(s).map { Int64($0.timeIntervalSince1970) }
    }
}
