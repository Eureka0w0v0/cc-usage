import Foundation
import SQLite3

// OMP(Oh My Pi)会话用量叠加层。
//
// 与 SessionOverlay 的定位差别是根本性的:SessionOverlay 叠的是「cc-switch 迟早会
// 入库、只是现在还没消化」的增量;而 cc-switch 压根不认识 ~/.omp/agent/sessions,
// 永远不会把这些行写进库——所以本层是 OMP 用量在本应用里的**唯一**来源,不存在
// 「等它补录」这回事。
//
// 由此带来三点与 SessionOverlay 不同的做法:
//   1. 没有 session_log_sync 偏移可依赖(cc-switch 不扫这个目录)→ 续读进度完全由
//      本层维护,只认文件自身的 mtime/size;
//   2. 不查 model_pricing:OMP 日志里每条响应自带按其 models.yml 算好的 cost,直接
//      采用。custom-gateway 之类的自定义端点在 cc-switch 价格表里根本不存在,查了
//      也只会得到 0,反而把 OMP 已经算对的成本抹掉;
//   3. 一个日志里混着多家 provider,必须逐行分流到不同 app_type——走 anthropic 的
//      是 Claude(吃本机 Claude 订阅额度,和 5H/Week 徽标是同一笔账),走 custom-gateway
//      的是 Grok,两者不能混为一谈(见 classify)。
//
// 防双算:responseId 为 Anthropic 的 msg_xxx 时,request_id 采用与 cc-switch /
// SessionOverlay 完全相同的 "session:<msg_id>" 命名空间。这样既能被
// pruneRowsAlreadyInDB 按 request_id 精确剔除(万一将来同一条真被 cc-switch 入库),
// 也天然防止同一条响应被 SessionOverlay 和本层各算一次。
//
// 全程零写入,与 SessionOverlay 一样只读。
public final class OmpOverlay {
    public static let shared = OmpOverlay()

    /// 两次真实扫描的最小间隔:一个刷新 tick 内 UsageStore 的多个查询共享同一次扫描。
    private let minRefreshInterval: TimeInterval

    private let lock = NSLock()
    private var rows: [String: OverlayRow] = [:]
    private var lastRefresh: Date?

    /// 续读进度。没有 db 偏移参与,只需记住「读到哪、当时文件什么样」。
    private struct FileMark {
        var mtimeNs: Int64
        var bytesRead: Int64
    }
    private var marks: [String: FileMark] = [:]

    /// 上一次真正扫完时的库水位，供预检短路比对（见 nothingChangedLocked）。
    private var lastWatermark: JSONLScan.Watermark?

    /// 文件列表缓存（只在目录树形状变了才重新枚举）。始终在 lock 内使用。
    private let dirCache = DirListCache()

    private let sessionsDir: String

    /// minRefreshInterval 可注入：测试传 0 即可免掉「睡过节流窗口」的等待。
    public init(sessionsDir: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".omp/agent/sessions"),
        minRefreshInterval: TimeInterval = 2.0) {
        self.sessionsDir = sessionsDir
        self.minRefreshInterval = minRefreshInterval
    }

    // MARK: - 对外入口

    /// 当前全部 OMP 用量行。db 仅用于按 request_id 剔除已被 cc-switch 收录的行。
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

    // MARK: - 归属分流

    /// 把 OMP 的 provider/model 映射到 cc-switch 的 app_type 与展示用 provider 名。
    ///
    /// 归属按**模型家族**判定而非 provider 名:同一个 provider 可以配多个家族的模型,
    /// 而「这笔账算在谁头上」取决于打的是谁的模型。特别地,走 anthropic 的 Claude
    /// 请求消耗的就是本机 Claude 订阅额度,与 5H/Week 徽标同源,必须落在 claude 分组,
    /// 否则面板会出现「额度百分比在涨、Tokens 却不动」的自相矛盾。
    ///
    /// 认不出家族时归 claude:OMP 的默认模型就是 Claude,归主力分组好过让这些用量
    /// 再次凭空消失(provider 名照实显示,Provider Stats 里一眼能看出是哪来的)。
    static func classify(provider: String, model: String)
        -> (appType: String, providerId: String, providerName: String) {
        let m = model.lowercased()
        let appType: String
        if m.contains("claude") {
            appType = "claude"
        } else if m.contains("grok") {
            appType = "grokbuild"
        } else if m.contains("gemini") {
            appType = "gemini"
        } else if m.hasPrefix("gpt") || m.hasPrefix("codex")
                    || ["o1", "o3", "o4", "o5"].contains(where: { m.hasPrefix($0) }) {
            appType = "codex"
        } else {
            appType = "claude"
        }
        // 每家 provider 一个占位 id：Provider Stats 按 id 聚合，混在一个 "_omp" 里
        // 会把不同来源的花费叠成一行。
        let p = provider.isEmpty ? "unknown" : provider
        return (appType, "_omp_" + p, "OMP (\(p))")
    }

    // MARK: - 扫描

    private func refreshLocked(_ db: OpaquePointer) {
        let files = collectJSONLFiles()

        // 与 SessionOverlay 同理：刷新 tick 比节流窗长，每一轮都会真跑一次 refresh，
        // 而绝大多数轮次无事发生。这里没有 session_log_sync 参与，判定更简单。
        if nothingChangedLocked(files, db) { return }

        var seenPaths = Set<String>()
        for path in files {
            seenPaths.insert(path)
            // 每个文件一个 autorelease 池：JSONSerialization 每行都产 Foundation 对象，
            // 而 message 里挂着整段回复正文。不排空的话这些对象要等整趟扫描结束才释放，
            // 实测峰值常驻 313MB → 加池后 53MB（且快 30%，内存压力小了）。WidgetKit
            // 扩展的内存上限很紧，不加这一层会被系统直接掐掉。
            autoreleasepool { scanFileLocked(path) }
        }
        // 文件消失(会话被清理)→ 其行一并移除
        let vanished = Set(marks.keys).subtracting(seenPaths)
        if !vanished.isEmpty {
            for p in vanished { marks.removeValue(forKey: p) }
            rows = rows.filter { !vanished.contains($0.value.sourceFile) }
        }
        pruneRowsAlreadyInDB(db)
        lastWatermark = JSONLScan.dbWatermark(db)
    }

    /// 本轮扫描会不会产生任何变化？判定对齐 scanFileLocked 的「内容未变」分支：
    /// 文件集合与 marks 完全重合(既无新文件也无消失)，且每个文件的 mtime 与已读
    /// 字节都没动。再加一道库水位——OMP 的行理论上不会被 cc-switch 收录，但
    /// pruneRowsAlreadyInDB 确实依赖库内容，水位没动它就不可能有新命中。
    private func nothingChangedLocked(_ files: [String], _ db: OpaquePointer) -> Bool {
        guard let wm = lastWatermark, files.count == marks.count else { return false }
        for path in files {
            guard let m = marks[path], let st = statNanos(path),
                  m.bytesRead <= st.size,
                  m.mtimeNs == st.mtimeNs else { return false }
        }
        return JSONLScan.dbWatermark(db) == wm
    }

    private func scanFileLocked(_ path: String) {
        guard let st = statNanos(path) else { return }

        var startBytes: Int64 = 0
        if let m = marks[path] {
            if m.bytesRead <= st.size {
                if m.mtimeNs == st.mtimeNs { return }   // 内容未变
                startBytes = m.bytesRead
            } else {
                // 文件被截断/重写 → 丢掉本文件已解析的行，从头重建
                rows = rows.filter { $0.value.sourceFile != path }
            }
        }
        // marks 无记录 = 首次见到该文件，rows 里必然没有它的行——冷启动时 359 个文件
        // 若都白跑一次全量 filter，等于把整个结果字典重建几百遍（实测占掉九成扫描时间）。

        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        if startBytes > 0 { try? fh.seek(toOffset: UInt64(startBytes)) }
        guard let data = try? fh.readToEnd(), !data.isEmpty else {
            marks[path] = FileMark(mtimeNs: st.mtimeNs, bytesRead: startBytes)
            return
        }

        // 只消费完整行(带 \n)。写了一半的最后一行留到下个 tick,避免把残缺 JSON
        // 当作「已处理」而永久丢掉一条用量——OMP 正在写的当前会话每 tick 都会命中这里。
        //
        // 走裸指针:这里只需要找换行与子串,没有一处用得上 Data 的语义,而 Data 的
        // 下标/切片在 150MB 量级的日志上开销压倒性——本机实测同一批文件逐行切分
        // 377ms vs memchr 88ms,读文件本身才 19ms。切出来的行用 bytesNoCopy 包给
        // JSONSerialization,省掉每行一次的缓冲区拷贝(闭包内 data 保证存活)。
        var consumedBytes = startBytes
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            var off = 0
            while off < total {
                guard let nl = memchr(base + off, 0x0A, total - off) else { break }
                let lineBase = base + off
                let lineLen = UnsafeRawPointer(nl) - lineBase
                let lineStart = startBytes + Int64(off)
                off += lineLen + 1
                consumedBytes = startBytes + Int64(off)

                guard lineLen > 0, JSONLScan.hasUsageMarker(lineBase, lineLen) else { continue }
                let lineData = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: lineBase),
                                    count: lineLen, deallocator: .none)
                guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? NSDictionary
                else { continue }
                ingestLocked(obj, path: path, lineStart: lineStart)
            }
        }

        marks[path] = FileMark(mtimeNs: st.mtimeNs, bytesRead: consumedBytes)
    }

    /// 单行 JSON → 一条用量行。不命中计费条件时静默跳过。
    ///
    /// 全程走 NSDictionary 而非 `as? [String: Any]`：后者会把整棵子树递归桥接成 Swift
    /// 字典，而 message 里挂着整段回复正文——8000 多行日志下这一步就占了扫描的绝大部分
    /// 时间。NSDictionary 下标是零拷贝的，我们要的也只是几个标量字段。
    private func ingestLocked(_ obj: NSDictionary, path: String, lineStart: Int64) {
        guard obj["type"] as? String == "message",
              let message = obj["message"] as? NSDictionary,
              message["role"] as? String == "assistant",
              let usage = message["usage"] as? NSDictionary
        else { return }

        let input = int64(usage["input"])
        let output = int64(usage["output"])
        let cacheRead = int64(usage["cacheRead"])
        let cacheWrite = int64(usage["cacheWrite"])
        // 任一计费维度 > 0 才计入(与 SessionOverlay 同口径)
        guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { return }

        let model = (message["model"] as? String) ?? "unknown"
        let provider = (message["provider"] as? String) ?? "unknown"
        let cls = Self.classify(provider: provider, model: model)

        // message.timestamp 是毫秒 epoch;缺失时回落顶层 RFC3339 字符串。
        let ts: Int64
        if let ms = message["timestamp"] as? NSNumber {
            ts = ms.int64Value / 1000
        } else if let s = obj["timestamp"] as? String, let t = SessionOverlay.parseRFC3339(s) {
            ts = t
        } else {
            ts = Int64(Date().timeIntervalSince1970)
        }

        let requestId = Self.requestId(responseId: message["responseId"] as? String,
                                       path: path, byteOffset: lineStart)

        // OMP 自带成本,直接采用;缺 total 时用四维求和兜底。
        let cost = usage["cost"] as? NSDictionary
        let ic = double(cost?["input"]), oc = double(cost?["output"])
        let crc = double(cost?["cacheRead"]), ccc = double(cost?["cacheWrite"])
        let total = cost?["total"] != nil ? double(cost?["total"]) : ic + oc + crc + ccc

        // 同 responseId 重复出现(重试/分叉写入)→ 取 output 更大的那条
        if let old = rows[requestId], output <= old.output { return }

        rows[requestId] = OverlayRow(
            requestId: requestId, model: model, createdAt: ts,
            input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheWrite,
            inputCost: ic, outputCost: oc, cacheReadCost: crc, cacheCreationCost: ccc,
            totalCost: total,
            hasStopReason: true, sourceFile: path,
            appType: cls.appType, providerId: cls.providerId, providerName: cls.providerName,
            dataSource: "omp_session"
        )
    }

    /// Anthropic 的 msg_xxx 复用 cc-switch 的 "session:" 命名空间(可被库内行收敛、
    /// 也防与 SessionOverlay 自相双算);其余 id 走 "omp:" 私有命名空间;彻底没有
    /// id 时用「文件+字节偏移」合成——同一行重复扫描恒定,不会因重扫而膨胀。
    static func requestId(responseId: String?, path: String, byteOffset: Int64) -> String {
        if let rid = responseId, !rid.isEmpty {
            return rid.hasPrefix("msg_") ? "session:" + rid : "omp:" + rid
        }
        return "omp:\((path as NSString).lastPathComponent)@\(byteOffset)"
    }

    /// 已被 cc-switch 收录的行从叠加层剔除(仅对 "session:" 键可能命中)。
    private func pruneRowsAlreadyInDB(_ db: OpaquePointer) {
        let ids = rows.keys.filter { $0.hasPrefix("session:") }
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

    // MARK: - 文件收集

    /// OMP 的目录形状是 sessions/<folder>/<session>.jsonl 以及同名目录下的 subagent
    /// 日志(还可再嵌一层)。这里不像 SessionOverlay 那样对齐上游的固定三层——OMP 没有
    /// 需要逐条复刻的导入器,直接递归,层级怎么变都不会漏。
    ///
    /// 整趟枚举包在 DirListCache 里:这个目录下 .log 与 .md 占了 93%(10928 个条目里
    /// 只有 566 个 .jsonl),趟一遍就要 47.8ms,而目录形状几乎从不变。
    private func collectJSONLFiles() -> [String] {
        dirCache.files {
            let fm = FileManager.default
            guard isDirectory(sessionsDir) else { return ([], [sessionsDir]) }
            var files: [String] = []
            var dirs: [String] = []
            var stack = [sessionsDir]
            while let dir = stack.popLast() {
                dirs.append(dir)
                guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
                for e in entries {
                    let p = (dir as NSString).appendingPathComponent(e)
                    if e.hasSuffix(".jsonl") { files.append(p) }
                    else if isDirectory(p) { stack.append(p) }
                }
            }
            return (files, dirs)
        }
    }

    /// 走裸 stat 而非 FileManager.fileExists(atPath:isDirectory:)——后者要过一层
    /// Foundation 桥接，而这里每个刷新 tick 要判上百次。
    private func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    private func statNanos(_ path: String) -> (mtimeNs: Int64, size: Int64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        return (mtimeNs: ns, size: Int64(st.st_size))
    }

    // MARK: - 小工具

    private func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

    private func double(_ v: Any?) -> Double {
        if let n = v as? NSNumber { return n.doubleValue }
        return 0
    }
}
