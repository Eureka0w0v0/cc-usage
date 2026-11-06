import Foundation
import SQLite3
import os

// Oh My Pi（omp.sh）会话用量叠加层。
//
// cc-switch 从 v4.0.22 起自己导入 Oh My Pi 的会话用量（app_type `omp`、data_source `omp_session`，
// #9046）。本层因此和 SessionOverlay 定位相同：只叠加「cc-switch 还没入库」的那部分，入库后自动收敛；
// cc-switch 低于 4.0.22（或从没导入过）时库里没有这些行，本层就是 OMP 用量的唯一来源。
//
// 为了两种情况下数字一致、交接时不跳，本层产出的是「上游对当前会话文件做一次全量导入会得到的行」减去库里
// 已有的：
//   * 文件发现、逐条解析、行身份逐条移植上游（OmpSessionFiles / OmpUsage），整文件规则照 parse_pi_file：
//     超过 128 MiB、首条有效 JSON 不是 session header、header 没有合法 id、条目超过 500000 条 → 整个文件不计入；
//     末行还没写完（不是合法 JSON）就停在那里，下一轮再读；末行没有换行但已经是合法 JSON → 照样计入；
//   * 跨文件去重照上游的去重账本：按文件排序先到先得；request_id 见过就跳过；有 entry id 的只和没有 entry id
//     的行比 semantic_id，没有 entry id 的和所有行比；pi-subagents 投影指向的子会话都在本轮文件里时跳过投影；
//   * 入库剔除：request_id 出现在 proxy_request_logs，或出现在 session_usage_dedup（明细 30 天后被汇总删掉，
//     账本一直留着）；semantic 规则同上；
//   * 成本：自报成本 > 0 用自报，否则按库里的 model_pricing 现场算（omp 不属于输入含缓存的应用、缓存写入不分
//     1 小时档）；库里查不到再回落内置表，与查询层给零成本行补价的口径相同；
//   * 展示名照 provider_name_coalesce：providers 表 (id, omp) 的 name → `_omp_session` 显示
//     「Oh My Pi (Session)」→ provider_id 原文；首字恒为空（上游 OMP 行的 first_token_ms 是 NULL）。
//
// 全程只读。
public final class OmpOverlay: PendingUsageSource {
    public static let shared = OmpOverlay()

    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "overlay")

    /// 上游 `pi::MAX_TREE_ENTRIES`：行数超过它 + 1 时整个文件报错。
    static let maxTreeEntries: Int64 = 500_000
    /// 上游 `MAX_TREE_ID_BYTES`。
    static let maxTreeIdBytes = 256
    /// 认文件被改写用的尾部长度（同上游 REVISION_TAIL_BYTES）。
    static let tailBytes = 4096

    /// 两次真实扫描的最小间隔：一个刷新 tick 内 UsageStore 的多个查询共享同一次扫描。
    private let minRefreshInterval: TimeInterval
    /// 定价表缓存时长（cc-switch 改价后最迟这么久被叠加层看到）。
    private let pricingTTL: TimeInterval
    private let rootsProvider: () -> OmpSessionFiles.Roots

    private let lock = NSLock()
    private var rows: [String: OverlayRow] = [:]
    private var lastRefresh: Date?

    /// 一条解析出来的记录，连同它做投影去重要查的子会话链接。
    private struct Parsed {
        var record: OmpUsage.Record
        var links: [String]
    }

    /// 单个文件的续读状态。
    private struct FileState {
        var mtimeNs: Int64 = 0
        var size: Int64 = 0
        /// 已消费到的字节位置（最后一个换行之后）。
        var bytesRead: Int64 = 0
        /// 已消费的行数（含空行、坏行、title 行——上游按它卡条目上限）。
        var lines: Int64 = 0
        /// bytesRead 之前最多 4096 字节：下次续读前比对，对不上就是文件被改写，从头重读。
        var tail = Data()
        var sessionId: String?
        var sessionTimestamp: Int64?
        /// 文件级错误：整个文件不计入，直到文件再变。
        var failed = false
        var parsed: [Parsed] = []
        /// 末尾还没有换行、但已经是合法 JSON 的那一行（上游照样导入）。不推进 bytesRead，每次续读重算。
        var unterminated: Parsed?
        /// 末尾那行让整个文件报错（例如 header 之前的合法 JSON 不是 header）：只影响本轮。
        var unterminatedFails = false
    }
    private var files: [String: FileState] = [:]
    /// 本轮文件，按上游的排序。
    private var order: [String] = []
    private var lastRoots: OmpSessionFiles.Roots?
    private var dirCache = DirListCache()
    /// 判断「库变没变」用的水位：明细表的水位 + 本来源账本的行数。只看明细不够——上游先写账本、明细
    /// `INSERT OR IGNORE` 撞上已有的 request_id 时只有账本变。
    private struct DBState: Equatable {
        var logs: OverlayDB.Watermark?
        var ledger: Int64?
    }
    private var lastWatermark: DBState?
    /// 至少完整扫过一轮（库里没有 proxy_request_logs 时水位是 nil，不能拿它当「扫过」的标志）。
    private var primed = false
    private var pricing = PricingTable()
    private var pricingLoadedAt: Date?
    /// 已确认被 cc-switch 收录的 request_id。账本只增不减，确认过的不再反复查库；库的行数变少时（换库、恢复备份）
    /// 清空重查。
    private var imported: Set<String> = []
    /// 在 notImportedWatermark 这个库水位下查过、确认还没入库的 request_id：库没变就不再重查，只查新出现的行。
    private var notImported: Set<String> = []
    private var notImportedWatermark: DBState?
    /// 读失败、已经记过日志的文件：读失败时进度不动、每轮都重试，日志每个文件只记一次，读成功一次就移出。
    private var unreadable: Set<String> = []

    /// 生产用：根目录每轮按 cc-switch 的 settings.json 重新解析（`ompConfigDir` 改了能跟上）。
    init(roots: @escaping () -> OmpSessionFiles.Roots = { OmpSessionFiles.roots() },
         minRefreshInterval: TimeInterval = 2.0, pricingTTL: TimeInterval = 300) {
        self.rootsProvider = roots
        self.minRefreshInterval = minRefreshInterval
        self.pricingTTL = pricingTTL
    }

    /// 测试用：固定的会话根目录（不与 Pi 共用）。minRefreshInterval 传 0 免得测试睡过节流窗口。
    public convenience init(sessionsDir: String, minRefreshInterval: TimeInterval = 2.0,
                            pricingTTL: TimeInterval = 300) {
        self.init(roots: { OmpSessionFiles.Roots(omp: sessionsDir, pi: "") },
                  minRefreshInterval: minRefreshInterval, pricingTTL: pricingTTL)
    }

    // MARK: - 对外入口

    /// 当前全部还没入库的 OMP 用量行。db 用于查价、查展示名和剔除已入库的行。
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
        let roots = rootsProvider()
        if roots != lastRoots {
            lastRoots = roots
            dirCache = DirListCache()
            files.removeAll()
            rows.removeAll()
            imported.removeAll()
            notImported.removeAll()
            lastWatermark = nil
            primed = false
        }
        let discovered = dirCache.files { OmpSessionFiles.discover(roots) }
        let watermark = DBState(logs: OverlayDB.watermark(db), ledger: Self.ledgerCount(db))
        let pricingStale = pricingLoadedAt.map { Date().timeIntervalSince($0) >= pricingTTL } ?? true
        if primed, !pricingStale, watermark == lastWatermark,
           discovered == order, filesUnchangedLocked() { return }

        if pricingStale, let table = PricingTable.load(db) {
            pricing = table
            pricingLoadedAt = Date()
        }
        if let old = lastWatermark, Self.shrank(old, watermark) {
            imported.removeAll()
            notImported.removeAll()
        }

        order = discovered
        let present = Set(discovered)
        files = files.filter { present.contains($0.key) }
        for path in discovered {
            // 每个文件一个 autorelease 池：JSONSerialization 每行都产 Foundation 对象，消息里挂着整段回复正文，
            // 不排空的话要等整趟扫描结束才释放（WidgetKit 扩展的内存上限很紧）。
            autoreleasepool { scanLocked(path) }
        }
        rebuildLocked(db, watermark: watermark)
        lastWatermark = watermark
        primed = true
    }

    private func filesUnchangedLocked() -> Bool {
        for path in order {
            guard let s = files[path], let st = OverlayFileIO.fileStat(path),
                  s.mtimeNs == st.mtimeNs, s.size == st.size else { return false }
        }
        return true
    }

    private func scanLocked(_ path: String) {
        guard let st = OverlayFileIO.fileStat(path) else {
            files[path] = nil
            return
        }
        var state = files[path] ?? FileState()
        if files[path] != nil, state.mtimeNs == st.mtimeNs, state.size == st.size { return }
        guard st.size <= OmpSessionFiles.maxSessionBytes else {
            files[path] = FileState(mtimeNs: st.mtimeNs, size: st.size, failed: true)
            return
        }
        // 读失败时什么都不记（新 mtime 也不记）：进度和读到的行留着，下一轮 filesUnchangedLocked 不成立、接着重试。
        // 记下新 mtime 的话这个文件就再也不读了，用量静默变少。
        let data: Data
        do {
            if try state.failed || st.size < state.bytesRead || !tailMatches(path, state) {
                state = FileState()
            }
            let want = Int(st.size - state.bytesRead)
            data = want > 0 ? try OverlayFileIO.read(path, from: state.bytesRead, count: want) : Data()
            unreadable.remove(path)
        } catch {
            if unreadable.insert(path).inserted {
                Self.log.error("OMP 会话日志读取失败，下一轮重试: \(path, privacy: .private) \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        state.mtimeNs = st.mtimeNs
        state.size = st.size
        state.unterminated = nil
        state.unterminatedFails = false

        let fileTimestamp = st.mtimeNs / 1_000_000_000
        var consumed = 0
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            var off = 0
            while off < total, !state.failed {
                guard let nl = memchr(base + off, 0x0A, total - off) else { break }
                let lineLen = UnsafeRawPointer(nl) - (base + off)
                processLine(base + off, lineLen, into: &state, fileTimestamp: fileTimestamp)
                off += lineLen + 1
                consumed = off
            }
            // 末尾没有换行的那段：合法 JSON 就照上游当一行处理（只算本轮，不推进进度）
            if !state.failed, consumed < total {
                var probe = state
                processLine(base + consumed, total - consumed, into: &probe, fileTimestamp: fileTimestamp)
                if probe.failed {
                    state.unterminatedFails = true
                } else if probe.parsed.count > state.parsed.count {
                    state.unterminated = probe.parsed.last
                }
            }
        }
        if state.failed {
            state.parsed = []
        } else if consumed > 0 {
            state.tail = Self.newTail(old: state.tail, appended: data, count: consumed)
            state.bytesRead += Int64(consumed)
        }
        files[path] = state
    }

    /// 逐行规则照 parse_pi_file：行数先加一再卡上限；空行跳过；坏 JSON 跳过（末行没写完的由调用方处理）；
    /// header 之前 title 行跳过、别的合法 JSON 让整个文件报错；header 之后逐条解析。
    private func processLine(_ ptr: UnsafeRawPointer, _ len: Int, into state: inout FileState,
                             fileTimestamp: Int64) {
        state.lines += 1
        if state.lines > Self.maxTreeEntries + 1 {
            state.failed = true
            return
        }
        guard len > 0, !Self.isBlank(ptr, len) else { return }
        // 有 header 之后，只有带 "usage" 的行才可能成一条用量：先做一次子串命中，省掉绝大多数行的整行解析。
        if state.sessionId != nil, !JSONLScan.hasUsageMarker(ptr, len) { return }
        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: ptr), count: len, deallocator: .none)
        guard let value = try? JSONSerialization.jsonObject(with: line, options: .fragmentsAllowed) else {
            return
        }
        guard let sessionId = state.sessionId else {
            let entry = value as? NSDictionary
            let type = entry?["type"] as? String
            if type == "title" { return }   // Oh My Pi 在 header 前面放一个定宽的 title 行
            guard type == "session", let header = entry,
                  let id = header["id"] as? String, Self.isValidTreeId(id) else {
                state.failed = true
                return
            }
            state.sessionId = id
            state.sessionTimestamp = OmpUsage.timestampMillis(header["timestamp"]).map { $0 / 1000 }
            return
        }
        guard let entry = value as? NSDictionary,
              let record = OmpUsage.record(from: entry, sessionId: sessionId,
                                           sessionTimestamp: state.sessionTimestamp,
                                           fileTimestamp: fileTimestamp) else { return }
        state.parsed.append(Parsed(record: record, links: OmpUsage.projectionSessionFiles(entry)))
    }

    // MARK: - 去重、剔除、成行

    private func rebuildLocked(_ db: OpaquePointer, watermark: DBState) {
        let importedPaths = Set(order.map(Self.canonical))
        var seenRequest = Set<String>(), seenSemantic = Set<String>(), seenLegacy = Set<String>()
        var candidates: [(path: String, record: OmpUsage.Record)] = []
        for path in order {
            guard let s = files[path], !s.failed, !s.unterminatedFails else { continue }
            for p in s.parsed + (s.unterminated.map { [$0] } ?? []) {
                if !p.links.isEmpty, p.links.allSatisfy({ importedPaths.contains(Self.canonical($0)) }) {
                    continue   // 投影的用量已在子会话文件里，跳过免得重复
                }
                let r = p.record
                let seen = seenRequest.contains(r.requestId)
                    || (r.hasEntryId ? seenLegacy.contains(r.semanticId) : seenSemantic.contains(r.semanticId))
                if seen { continue }
                seenRequest.insert(r.requestId)
                seenSemantic.insert(r.semanticId)
                if !r.hasEntryId { seenLegacy.insert(r.semanticId) }
                candidates.append((path, r))
            }
        }
        let inDB = alreadyImportedLocked(db, candidates.map(\.record), watermark: watermark)
        let names = Self.providerNames(db)
        var next: [String: OverlayRow] = [:]
        for (path, r) in candidates where !inDB.contains(r.requestId) {
            next[r.requestId] = makeRow(r, path: path, names: names)
        }
        rows = next
    }

    private func makeRow(_ r: OmpUsage.Record, path: String, names: [String: String]) -> OverlayRow {
        var c = OmpUsage.Costs()
        if let reported = r.costs.reported {
            c = reported
        } else if let p = pricing.find(r.model) {
            let priced = p.cost(input: r.input, output: r.output, cacheRead: r.cacheRead, cacheCreation: r.cacheWrite)
            c.input = priced.input
            c.output = priced.output
            c.cacheRead = priced.cacheRead
            c.cacheWrite = priced.cacheCreation
            c.total = c.input + c.output + c.cacheRead + c.cacheWrite
        }
        let name = names[r.providerId]
            ?? (r.providerId == OmpUsage.providerPlaceholder ? "\(OmpUsage.label) (Session)" : r.providerId)
        return OverlayRow(
            requestId: r.requestId, model: r.model, createdAt: r.createdAt,
            input: r.input, output: r.output, cacheRead: r.cacheRead, cacheCreation: r.cacheWrite,
            inputCost: c.input, outputCost: c.output, cacheReadCost: c.cacheRead, cacheCreationCost: c.cacheWrite,
            totalCost: c.total,
            hasStopReason: true, sourceFile: path,
            appType: OmpUsage.appType, providerId: r.providerId, providerName: name,
            dataSource: OmpUsage.dataSource,
            latencyMs: r.latencyMs, firstTokenMs: nil,
            statusCode: r.statusCode, errorMessage: r.errorMessage, requestModel: r.requestModel)
    }

    /// 哪些候选行已被 cc-switch 收录（照 insert_pi_record 的判定：request_id 在账本或明细里；semantic_id 命中
    /// 账本里没有 entry id 的行（有 entry id 的记录）或任意行（没有 entry id 的记录））。
    private func alreadyImportedLocked(_ db: OpaquePointer, _ records: [OmpUsage.Record],
                                       watermark: DBState) -> Set<String> {
        if watermark != notImportedWatermark || watermark.logs == nil {
            notImported.removeAll()
            notImportedWatermark = watermark
        }
        var hits = Set(records.lazy.map(\.requestId).filter { self.imported.contains($0) })
        let pending = records.filter { !hits.contains($0.requestId) && !notImported.contains($0.requestId) }
        guard !pending.isEmpty else { return hits }
        let ids = pending.map(\.requestId)
        hits.formUnion(OverlayDB.matching(db, "SELECT request_id FROM proxy_request_logs WHERE request_id IN", ids))
        let hasLedger = Self.tableExists(db, "session_usage_dedup")
        if hasLedger {
            hits.formUnion(OverlayDB.matching(db, """
                SELECT request_id FROM session_usage_dedup
                WHERE data_source = '\(OmpUsage.dataSource)' AND request_id IN
                """, ids))
            // semantic 只在两种情况下起作用：本轮有没有 entry id 的记录，或账本里有没有 entry id 的旧行。
            let needsSemantic = pending.contains { !$0.hasEntryId } || SQLite.exists(db, """
                SELECT 1 FROM session_usage_dedup
                WHERE data_source = '\(OmpUsage.dataSource)' AND has_entry_id = 0 LIMIT 1
                """)
            if needsSemantic {
                let rest = pending.filter { !hits.contains($0.requestId) }
                let any = OverlayDB.matching(db, """
                    SELECT semantic_id FROM session_usage_dedup
                    WHERE data_source = '\(OmpUsage.dataSource)' AND semantic_id IN
                    """, rest.map(\.semanticId))
                let legacy = OverlayDB.matching(db, """
                    SELECT semantic_id FROM session_usage_dedup
                    WHERE data_source = '\(OmpUsage.dataSource)' AND has_entry_id = 0 AND semantic_id IN
                    """, rest.map(\.semanticId))
                for r in rest where r.hasEntryId ? legacy.contains(r.semanticId) : any.contains(r.semanticId) {
                    hits.insert(r.requestId)
                }
            }
        }
        imported.formUnion(hits)
        notImported.formUnion(pending.lazy.map(\.requestId).filter { !hits.contains($0) })
        return hits
    }

    /// 库是否变小（换库、恢复备份、汇总删明细）：变小时已确认的结论要重查。
    private static func shrank(_ old: DBState, _ new: DBState) -> Bool {
        if let o = old.logs, let n = new.logs, n.rows < o.rows { return true }
        if let o = old.ledger, let n = new.ledger, n < o { return true }
        return false
    }

    /// 本来源在账本里的行数（主键前缀是 data_source，走索引）。缺表为 nil。
    private static func ledgerCount(_ db: OpaquePointer) -> Int64? {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM session_usage_dedup WHERE data_source = '\(OmpUsage.dataSource)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int64(stmt, 0) : nil
    }

    private static func tableExists(_ db: OpaquePointer, _ name: String) -> Bool {
        SQLite.exists(db, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = '\(name)'")
    }

    /// providers 表里 Oh My Pi 的供应商名（provider_name_coalesce 的 `p.name`）。缺表或缺列时为空。
    private static func providerNames(_ db: OpaquePointer) -> [String: String] {
        var stmt: OpaquePointer?
        let sql = "SELECT id, name FROM providers WHERE app_type = '\(OmpUsage.appType)' AND name IS NOT NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let id = sqlite3_column_text(stmt, 0), let name = sqlite3_column_text(stmt, 1) else { continue }
            out[String(cString: id)] = String(cString: name)
        }
        return out
    }

    // MARK: - 小工具

    /// `fs::canonicalize`，取不到（文件不存在等）就用原路径——不存在的链接自然对不上本轮文件。
    private static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// 整行只有空白（Rust `str::trim` 之后为空）。JSON 行里出现的空白只会是 ASCII 的这几种。
    private static func isBlank(_ ptr: UnsafeRawPointer, _ len: Int) -> Bool {
        let bytes = ptr.assumingMemoryBound(to: UInt8.self)
        for i in 0..<len where ![0x20, 0x09, 0x0D, 0x0B, 0x0C].contains(bytes[i]) { return false }
        return true
    }

    /// pi::is_valid_tree_id：1…256 字节，首尾是 ASCII 字母数字，中间只允许字母数字、`-`、`_`、`.`。
    static func isValidTreeId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        func alnum(_ b: UInt8) -> Bool {
            (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
        }
        guard let first = bytes.first, let last = bytes.last, bytes.count <= maxTreeIdBytes,
              alnum(first), alnum(last) else { return false }
        return bytes.allSatisfy { alnum($0) || $0 == 0x2D || $0 == 0x5F || $0 == 0x2E }
    }

    /// 续读前确认上次读到的位置前面的内容没被改写（同上游比对旧 EOF 处的尾部）。
    private func tailMatches(_ path: String, _ state: FileState) throws -> Bool {
        guard state.bytesRead > 0, !state.tail.isEmpty else { return true }
        let start = state.bytesRead - Int64(state.tail.count)
        return try OverlayFileIO.read(path, from: start, count: state.tail.count) == state.tail
    }

    /// 新的尾部：旧尾部接上本次消费的字节，取最后 tailBytes 个，拷成独立的 Data（切片会把整段读入的缓冲留在内存里）。
    static func newTail(old: Data, appended: Data, count: Int) -> Data {
        let fromNew = min(count, tailBytes)
        let fromOld = min(old.count, tailBytes - fromNew)
        var out = Data(capacity: fromOld + fromNew)
        out.append(contentsOf: old.suffix(fromOld))
        out.append(contentsOf: appended[appended.startIndex + count - fromNew ..< appended.startIndex + count])
        return out
    }
}
