import Foundation
import SQLite3

/// 逐 tick 回放：把真实会话日志按随机小块追加到工作目录，每块调一次 pendingRows，打每一拍的结果摘要，
/// 最后和「新建一个叠加层一次读完」逐行比。
///
/// 叠加层每 5 秒续读、cc-switch 隔很久批量导入，所以「跨 tick 的状态」是一次读完的对拍看不到的（见
/// SessionOverlay.FileMark.timing）。handoff 模式再模拟 cc-switch 中途入库：写 session_log_sync 游标
/// （字节 / 行号两种）、把这个文件当前的行写进明细，下一拍叠加层要把这部分交接掉，不能双算。
///
/// 全部随机来自 seed，mtime 由这里写死递增：同一份代码跑两遍摘要必须逐字相同。
final class DumpReplay {
    enum Kind { case claude, omp }

    private struct Source {
        let path: String              // 工作目录里的目标文件
        var lines: [Data]
        var next = 0                  // 下一个要写的行号
        var held = Data()             // 上一拍只写了一半的行，剩下的部分
        var written: Int64 = 0        // 已写字节（含写了一半的那部分）
        var complete: Int64 = 0       // 最后一个完整行之后的字节位置
        var completeLines: Int64 = 0
    }

    private let kind: Kind
    private let sourceDir: String
    private let work: String
    private var rng: UInt64
    private let handoff: Bool
    private var sources: [Source] = []
    private var clock: Int = 1_900_000_000
    private let db: OpaquePointer

    private static let linesPerFile = 6000
    private static let handoffEvery = 29
    private static let rewriteEvery = 37
    private static let version = "4.0.12"

    init(kind: Kind, db dbPath: String, sources: String, work: String, seed: UInt64, handoff: Bool) {
        self.kind = kind
        sourceDir = sources
        self.work = work
        rng = seed
        self.handoff = handoff
        try? FileManager.default.removeItem(atPath: work)
        try? FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let copy = (work as NSString).appendingPathComponent("replay.db")
        do {
            try FileManager.default.copyItem(atPath: dbPath, toPath: copy)
            // 冻结库是只读的，拷贝会带上只读属性；这份要写游标和明细
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: copy)
        } catch {
            FileHandle.standardError.write(Data("拷库失败：\(error)\n".utf8))
            exit(3)
        }
        db = dumpOpen(copy, flags: SQLITE_OPEN_READWRITE)
        exec("DELETE FROM session_log_sync")
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            print("!! SQL 失败：\(sql)\n\(String(cString: sqlite3_errmsg(db)))")
            exit(3)
        }
    }

    /// splitmix64。
    private func random(_ bound: Int) -> Int {
        rng &+= 0x9E3779B97F4A7C15
        var z = rng
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }

    private var root: String {
        (work as NSString).appendingPathComponent(kind == .claude ? "projects" : "sessions")
    }

    private func loadSources() {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: sourceDir)) ?? [])
            .filter { $0.hasSuffix(".jsonl") }.sorted()
        for (i, name) in names.enumerated() {
            guard let data = FileManager.default.contents(atPath: (sourceDir as NSString).appendingPathComponent(name)) else {
                continue
            }
            var lines: [Data] = []
            var start = data.startIndex
            while lines.count < Self.linesPerFile, let nl = data[start...].firstIndex(of: 0x0A) {
                lines.append(Data(data[start...nl]))
                start = nl + 1
            }
            let dir = (root as NSString).appendingPathComponent("p\(i)")
            sources.append(Source(path: (dir as NSString).appendingPathComponent("s\(i).jsonl"), lines: lines))
        }
    }

    /// 给一个文件追加一块；有时把最后一行只写一半，下一拍再补完——叠加层绝不能把半行当成已处理。
    private func append(_ i: Int) {
        var chunk = sources[i].held
        sources[i].held = Data()
        let count = min(1 + random(12), sources[i].lines.count - sources[i].next)
        for line in sources[i].lines[sources[i].next ..< sources[i].next + count] { chunk.append(line) }
        sources[i].next += count
        if random(8) == 0, let last = sources[i].lines[..<sources[i].next].last, last.count > 2 {
            let keep = 1 + random(last.count - 1)
            sources[i].held = Data(chunk.suffix(last.count - keep))
            chunk = Data(chunk.dropLast(last.count - keep))
        }
        write(i, chunk)
    }

    private func write(_ i: Int, _ chunk: Data) {
        let path = sources[i].path
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: path) { FileManager.default.createFile(atPath: path, contents: nil) }
        guard let fh = FileHandle(forWritingAtPath: path) else { exit(3) }
        _ = try? fh.seekToEnd()
        try? fh.write(contentsOf: chunk)
        try? fh.close()
        sources[i].written += Int64(chunk.count)
        if let last = chunk.lastIndex(of: 0x0A) {
            sources[i].complete = sources[i].written - Int64(chunk.endIndex - last - 1)
        }
        sources[i].completeLines += Int64(chunk.filter { $0 == 0x0A }.count)
        stamp(path)
    }

    /// mtime 写死、严格递增：不靠文件系统时钟的分辨率，也让结果和跑的时刻无关。
    private func stamp(_ path: String) {
        clock += 1
        var times = [timeval(tv_sec: clock, tv_usec: 0), timeval(tv_sec: clock, tv_usec: 0)]
        _ = utimes(path, &times)
    }

    private func mtimeNs(_ path: String) -> Int64 {
        var st = stat()
        return stat(path, &st) == 0 ? Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec) : 0
    }

    func run() {
        loadSources()
        print("== sources \(sources.map(\.lines.count))")
        switch kind {
        case .claude:
            let overlay = SessionOverlay(projectsDir: root, minRefreshInterval: 0, ccSwitchVersion: { Self.version })
            loop(read: { overlay.pendingRows(db: self.db) }, event: handoffClaude)
            finish(overlay.pendingRows(db: db),
                   SessionOverlay(projectsDir: root, minRefreshInterval: 0, ccSwitchVersion: { Self.version })
                       .pendingRows(db: db))
        case .omp:
            let overlay = OmpOverlay(sessionsDir: root, minRefreshInterval: 0)
            loop(read: { overlay.pendingRows(db: self.db) }, event: handoffOmp)
            finish(overlay.pendingRows(db: db), OmpOverlay(sessionsDir: root, minRefreshInterval: 0).pendingRows(db: db))
        }
    }

    private func loop(read: () -> [OverlayRow], event: (Int, [OverlayRow]) -> Void) {
        var tick = 0
        while let i = pick() {
            append(i)
            tick += 1
            let rows = read()
            let text = rows.map(DumpFormat.overlay).sorted()
            print("tick \(tick) file=\(i) rows=\(rows.count) digest=\(DumpFormat.digest(text))")
            guard handoff else { continue }
            if tick % Self.handoffEvery == 0 { event(i, rows) }
            if kind == .omp, tick % Self.rewriteEvery == 0 { truncate(i) }
        }
        // 写了一半的行补完，再读一拍
        for i in sources.indices where !sources[i].held.isEmpty {
            let rest = sources[i].held
            sources[i].held = Data()
            write(i, rest)
        }
        _ = read()
    }

    private func pick() -> Int? {
        let open = sources.indices.filter { sources[$0].next < sources[$0].lines.count }
        return open.isEmpty ? nil : open[random(open.count)]
    }

    private func finish(_ ticked: [OverlayRow], _ once: [OverlayRow]) {
        let a = ticked.map(DumpFormat.overlay).sorted()
        let b = once.map(DumpFormat.overlay).sorted()
        print("== final ticked=\(a.count) once=\(b.count) same=\(a == b)")
        let diff = Set(a).symmetricDifference(b).sorted()
        print("== ticked vs once 差异 \(diff.count)")
        for line in diff.prefix(50) { print("~ \(line)") }
        for line in a { print(line) }
    }

    // MARK: - 模拟 cc-switch 入库

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ s: String) {
        sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT_DEST)
    }

    /// 明细写入和 cc-switch 一样带 session 行的形状；只写用到的列。
    private func insertLogs(_ rows: [OverlayRow]) {
        exec("BEGIN")
        var stmt: OpaquePointer?
        let sql = """
        INSERT OR IGNORE INTO proxy_request_logs(request_id, provider_id, app_type, model,
          input_tokens, output_tokens, cache_read_tokens, cache_creation_tokens,
          total_cost_usd, latency_ms, first_token_ms, status_code, created_at, data_source)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exit(3) }
        defer { sqlite3_finalize(stmt) }
        for r in rows.sorted(by: { $0.requestId < $1.requestId }) {
            sqlite3_reset(stmt)
            bind(stmt, 1, r.requestId)
            bind(stmt, 2, r.providerId)
            bind(stmt, 3, r.appType)
            bind(stmt, 4, r.model)
            sqlite3_bind_int64(stmt, 5, r.input)
            sqlite3_bind_int64(stmt, 6, r.output)
            sqlite3_bind_int64(stmt, 7, r.cacheRead)
            sqlite3_bind_int64(stmt, 8, r.cacheCreation)
            bind(stmt, 9, String(format: "%.6f", r.totalCost))
            sqlite3_bind_int64(stmt, 10, r.latencyMs)
            if let ms = r.firstTokenMs { sqlite3_bind_int64(stmt, 11, ms) } else { sqlite3_bind_null(stmt, 11) }
            sqlite3_bind_int64(stmt, 12, r.statusCode)
            sqlite3_bind_int64(stmt, 13, r.createdAt)
            bind(stmt, 14, r.dataSource)
            _ = sqlite3_step(stmt)
        }
        exec("COMMIT")
    }

    /// cc-switch 把文件 i 读到当前完整行：写游标（奇偶交替字节 / 行号两种形态）和这个文件现有的行。
    private func handoffClaude(_ i: Int, _ rows: [OverlayRow]) {
        let path = sources[i].path
        let mine = rows.filter { $0.sourceFile == path }
        insertLogs(mine)
        let byCursorByte = (sources[i].next / 7) % 2 == 0
        let sql = "INSERT OR REPLACE INTO session_log_sync(file_path, last_modified, last_line_offset, last_synced_at, last_byte_offset)"
            + " VALUES(?, ?, ?, 0, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exit(3) }
        defer { sqlite3_finalize(stmt) }
        bind(stmt, 1, path)
        sqlite3_bind_int64(stmt, 2, mtimeNs(path))
        sqlite3_bind_int64(stmt, 3, byCursorByte ? 0 : sources[i].completeLines)
        if byCursorByte { sqlite3_bind_int64(stmt, 4, sources[i].complete) } else { sqlite3_bind_null(stmt, 4) }
        _ = sqlite3_step(stmt)
        print("handoff file=\(i) rows=\(mine.count) \(byCursorByte ? "byte=\(sources[i].complete)" : "line=\(sources[i].completeLines)")")
    }

    /// 上游先写账本、再写明细：这里隔着来，账本有的行和明细有的行都要被叠加层剔掉。
    private func handoffOmp(_ i: Int, _ rows: [OverlayRow]) {
        let path = sources[i].path
        let mine = rows.filter { $0.sourceFile == path }.sorted { $0.requestId < $1.requestId }
        let half = mine.count / 2
        insertLogs(Array(mine[..<half]))
        exec("BEGIN")
        var stmt: OpaquePointer?
        let sql = "INSERT OR IGNORE INTO session_usage_dedup(data_source, request_id, semantic_id, has_entry_id) VALUES(?,?,?,1)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { exit(3) }
        defer { sqlite3_finalize(stmt) }
        for r in mine[half...] {
            sqlite3_reset(stmt)
            bind(stmt, 1, r.dataSource)
            bind(stmt, 2, r.requestId)
            bind(stmt, 3, "semantic-\(r.requestId)")
            _ = sqlite3_step(stmt)
        }
        exec("COMMIT")
        print("handoff file=\(i) rows=\(mine.count)")
    }

    /// 文件被改写（变短）：续读位置失效，必须从头重读。从一半的行重新接着追加。
    private func truncate(_ i: Int) {
        let keep = sources[i].next / 2
        var data = Data()
        for line in sources[i].lines[..<keep] { data.append(line) }
        FileManager.default.createFile(atPath: sources[i].path, contents: data)
        sources[i].next = keep
        sources[i].held = Data()
        sources[i].written = Int64(data.count)
        sources[i].complete = Int64(data.count)
        sources[i].completeLines = Int64(keep)
        stamp(sources[i].path)
        print("truncate file=\(i) keep=\(keep)")
    }
}
