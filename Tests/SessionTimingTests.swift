import XCTest
import SQLite3

// 叠加行的请求计时。cc-switch 不在时，还没入库的行由 SessionOverlay 现场解析会话日志得来，早先这些行的
// 速度、首字恒为「—」（2026-10-16 修复）。前半部分把 cc-switch v4.0.12 session_usage.rs 的计时用例
// （test_latency_* / test_first_token_* / test_partial_subagent_reply_*）逐条搬到叠加层上，日志行、时间戳、
// 断言值都与上游一致：叠加行现在显示的值，就是 cc-switch 将来补录时写进库的值。后半部分是上游的边界和
// 叠加层特有的路径（自己的续读、256KB 回看边界、旧行号游标、行被替换时保留计时）。
//
// 每个用例的注释写明它负责杀哪些变异体。
final class SessionTimingTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var overlay: SessionOverlay!
    private var db: OpaquePointer!
    private var hasByteColumn = false

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("timing")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-timing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        overlay = SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0)
        try openDB()
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db); db = nil }
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
        Fixture.cleanTempDirs()
    }

    private func openDB() throws {
        if db != nil { sqlite3_close(db) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    // MARK: - 小工具

    private func path(_ name: String = "session.jsonl") -> String {
        ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent(name)
    }

    private func write(_ lines: [String], to name: String = "session.jsonl") throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path(name), atomically: true, encoding: .utf8)
    }

    private func append(_ lines: [String], to name: String = "session.jsonl") throws {
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: path(name)))
        defer { try? fh.close() }
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }

    /// 这些行（含换行）的总字节数：上游游标停在完整行之后。
    private func bytes(_ lines: [String]) -> Int64 {
        lines.reduce(0) { $0 + Int64($1.utf8.count) + 1 }
    }

    /// cc-switch v18 起的字节游标（C 态）。last_modified 记 0：文件 mtime 恒比它新，叠加层从游标处续读。
    private func setByteCursor(_ offset: Int64, for name: String = "session.jsonl") throws {
        if !hasByteColumn {
            try Fixture.exec(dbPath, "ALTER TABLE session_log_sync ADD COLUMN last_byte_offset INTEGER;")
            hasByteColumn = true
            try openDB()
        }
        try Fixture.exec(dbPath, """
        INSERT OR REPLACE INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset)
        VALUES('\(path(name))', 0, 0, \(offset));
        """)
    }

    private func rows() -> [String: OverlayRow] {
        Dictionary(uniqueKeysWithValues: overlay.pendingRows(db: db).map { ($0.requestId, $0) })
    }

    private func chain(_ kind: String, _ n: Int, parent: Int?, _ ts: String) -> String {
        ClaudeLog.chain(kind, n, parent: parent, ts)
    }

    private func block(_ msg: String, _ n: Int, parent: Int, index: Int, _ ts: String,
                       output: Int = 900, finished: Bool = true) -> String {
        ClaudeLog.block(msg, n, parent: parent, index: index, ts, output: output, finished: finished)
    }

    private func thinking(_ msg: String, _ n: Int, parent: Int, _ ts: String, durationMs: Int,
                          finished: Bool = true, firstType: String = "thinking") -> String {
        ClaudeLog.thinking(msg, n, parent: parent, ts, durationMs: durationMs,
                           finished: finished, firstType: firstType)
    }

    // MARK: - 上游用例（日志与断言值同 session_usage.rs）

    /// 起点是工具结果：从第一块的父行往上找、跳过 attachment（含回复开始后才补记、时间戳比第一块还晚的那条）；
    /// 结束取各块里最晚的；并行工具调用的结果插在同一条回复的两块中间，不影响起点。
    /// 杀变异体：不跳 attachment（起点取成 13:00:05.001 → 7499）；起点沿最后一块的父行找（4500）；
    /// 结束取第一块（5000）。
    func testLatencySpansFromToolResultToLastBlock() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            chain("attachment", 2, parent: 1, "2026-06-07T13:00:00.003Z"),
            chain("attachment", 3, parent: 2, "2026-06-07T13:00:05.001Z"),
            block("msg_t", 4, parent: 3, index: 0, "2026-06-07T13:00:05.000Z"),
            block("msg_t", 5, parent: 4, index: 1, "2026-06-07T13:00:07.000Z"),
            chain("user", 6, parent: 5, "2026-06-07T13:00:08.000Z"),
            block("msg_t", 7, parent: 6, index: 2, "2026-06-07T13:00:12.500Z"),
        ])
        let r = try XCTUnwrap(rows()["session:msg_t"])
        XCTAssertEqual(r.latencyMs, 12_500)
        XCTAssertNil(r.firstTokenMs)
    }

    /// 首字只从以思考块开头的回复推出：块写完的时刻 − thinkingDurationMs − 起点，必须落在 (0, 耗时]。
    /// msg_text 是本仓补的：带了 thinkingDurationMs、第一块却是文字。
    /// 杀变异体：不看第一块的类型（msg_text → 1000）；不减 thinkingDurationMs（msg_think → 5000）；
    /// 首字不要求 > 0（msg_bad → −3000）。
    func testFirstTokenIsDerivedFromALeadingThinkingBlock() throws {
        try write([
            // 思考 3 秒、5 秒时写完：首字在 2 秒
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            thinking("msg_think", 2, parent: 1, "2026-06-07T13:00:05.000Z", durationMs: 3_000),
            block("msg_think", 3, parent: 2, index: 1, "2026-06-07T13:00:09.000Z"),
            // 第一块是工具调用：块的时间戳只是它写完的时刻，推不出首字
            chain("user", 4, parent: 3, "2026-06-07T13:00:10.000Z"),
            block("msg_tool", 5, parent: 4, index: 0, "2026-06-07T13:00:14.000Z"),
            // 思考时长比整段还长，起点对不上，不要
            chain("user", 6, parent: 5, "2026-06-07T13:00:20.000Z"),
            thinking("msg_bad", 7, parent: 6, "2026-06-07T13:00:22.000Z", durationMs: 5_000),
            // 第一块是文字：哪怕带了 thinkingDurationMs 也推不出首字
            chain("user", 8, parent: 7, "2026-06-07T13:00:30.000Z"),
            thinking("msg_text", 9, parent: 8, "2026-06-07T13:00:34.000Z", durationMs: 3_000, firstType: "text"),
        ])
        let r = rows()
        XCTAssertEqual(r["session:msg_think"]?.latencyMs, 9_000)
        XCTAssertEqual(r["session:msg_think"]?.firstTokenMs, 2_000)
        XCTAssertEqual(r["session:msg_tool"]?.latencyMs, 4_000)
        XCTAssertNil(try XCTUnwrap(r["session:msg_tool"]).firstTokenMs)
        XCTAssertEqual(r["session:msg_bad"]?.latencyMs, 2_000)
        XCTAssertNil(try XCTUnwrap(r["session:msg_bad"]).firstTokenMs)
        XCTAssertEqual(r["session:msg_text"]?.latencyMs, 4_000)
        XCTAssertNil(try XCTUnwrap(r["session:msg_text"]).firstTokenMs)
    }

    /// 子代理逐块写：读到第一块时还没有 stop_reason，不估计时；最后一块到了，耗时和首字一起补上——
    /// 首字靠读取起点前回看到的第一块。
    /// 杀变异体：叠加层续读时不回看（第二轮看不到第一块 → 0）。
    func testFirstTokenIsFilledInWhenAPartialReplyCompletes() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            thinking("msg_sub", 2, parent: 1, "2026-06-07T13:00:04.000Z", durationMs: 2_500, finished: false),
        ])
        let partial = try XCTUnwrap(rows()["session:msg_sub"])
        XCTAssertEqual(partial.latencyMs, 0)
        XCTAssertNil(partial.firstTokenMs)

        try append([block("msg_sub", 3, parent: 2, index: 1, "2026-06-07T13:00:08.000Z")])
        let done = try XCTUnwrap(rows()["session:msg_sub"])
        XCTAssertEqual(done.latencyMs, 8_000)
        XCTAssertEqual(done.firstTokenMs, 1_500)
    }

    /// 工具结果先落盘、被 cc-switch 上一轮读走，回复结束时才整条写出：起点行在 cc-switch 字节游标的前面。
    /// 叠加层从游标处读，要往前回看才找得到起点。
    /// 杀变异体：从 cc-switch 游标处起读时不回看（→ 0）。
    func testLatencyStartIsFoundBeforeTheCursor() throws {
        let before = [
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            chain("attachment", 2, parent: 1, "2026-06-07T13:00:00.003Z"),
        ]
        try write(before + [block("msg_t", 3, parent: 2, index: 0, "2026-06-07T13:00:09.000Z")])
        try setByteCursor(bytes(before))
        let r = rows()
        XCTAssertEqual(r.count, 1, "前提：游标前的行不计用量")
        XCTAssertEqual(r["session:msg_t"]?.latencyMs, 9_000)

        // 接着追加：回看窗口里的字节不能算进已读进度，否则续读会从新行中间开始
        try append([
            chain("user", 4, parent: 3, "2026-06-07T13:01:00.000Z"),
            block("msg_u", 5, parent: 4, index: 0, "2026-06-07T13:01:04.000Z"),
        ])
        XCTAssertEqual(rows()["session:msg_u"]?.latencyMs, 4_000)
    }

    /// 回复的各块逐块写：上一轮读到第一块时成行，耗时只算到第一块；后面的块到了（主会话的各块都带最终用量，
    /// 这一行不会被替换），耗时延长。
    /// 杀变异体：合并时沿用旧耗时、不取大（停在 5000）；只在行被替换时才更新计时（停在 5000）。
    func testLatencyIsExtendedWhenLaterBlocksArrive() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_t", 2, parent: 1, index: 0, "2026-06-07T13:00:05.000Z"),
        ])
        XCTAssertEqual(rows()["session:msg_t"]?.latencyMs, 5_000)

        try append([
            chain("user", 3, parent: 2, "2026-06-07T13:00:06.000Z"),
            block("msg_t", 4, parent: 3, index: 1, "2026-06-07T13:00:12.500Z"),
        ])
        XCTAssertEqual(rows()["session:msg_t"]?.latencyMs, 12_500)
    }

    /// 没有可靠起点就不估：看不到第一块（最先出现的是第 2 块）、父行不在文件里、起点和结束只差 20ms。
    /// 三条照常计用量，只是没有计时。
    /// 杀变异体：不要求看到第一块（msg_no_first → 9000）；去掉 100ms 下限（msg_instant → 20）。
    func testLatencyIsNotEstimatedWithoutAReliableStart() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_no_first", 2, parent: 1, index: 2, "2026-06-07T13:00:09.000Z"),
            block("msg_orphan", 3, parent: 9, index: 0, "2026-06-07T13:00:20.000Z"),
            chain("user", 4, parent: nil, "2026-06-07T13:01:00.000Z"),
            block("msg_instant", 5, parent: 4, index: 0, "2026-06-07T13:01:00.020Z"),
        ])
        let r = rows()
        XCTAssertEqual(r.count, 3)
        for msg in ["msg_no_first", "msg_orphan", "msg_instant"] {
            let row = try XCTUnwrap(r["session:\(msg)"], msg)
            XCTAssertEqual(row.latencyMs, 0, msg)
            XCTAssertNil(row.firstTokenMs, msg)
        }
    }

    /// 子代理第一块落盘时输出只有开头几个 token、没有 stop_reason；读恰好落在两块之间时先按中间值成行，
    /// 最后一块到了补全输出和耗时，结果与整条回复一轮读完相同；文件没新内容时再读一轮不变。
    /// 杀变异体：行被替换时没并入这一轮的计时（→ 0）。
    func testPartialSubagentReplyIsCompletedByItsFinalBlock() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_s", 2, parent: 1, index: 0, "2026-06-07T13:00:02.000Z", output: 5, finished: false),
        ])
        let partial = try XCTUnwrap(rows()["session:msg_s"])
        XCTAssertEqual(partial.output, 5)
        XCTAssertEqual(partial.latencyMs, 0)

        try append([block("msg_s", 3, parent: 2, index: 1, "2026-06-07T13:00:30.000Z", output: 4_660)])
        let completed = try XCTUnwrap(rows()["session:msg_s"])
        XCTAssertEqual(completed.output, 4_660)
        XCTAssertEqual(completed.latencyMs, 30_000)

        // 对照：整条回复一轮读完
        let whole = SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0)
        let w = try XCTUnwrap(whole.pendingRows(db: db).first { $0.requestId == "session:msg_s" })
        XCTAssertEqual(w.output, completed.output)
        XCTAssertEqual(w.latencyMs, completed.latencyMs)
        XCTAssertEqual(w.firstTokenMs, completed.firstTokenMs)

        // 只动 mtime、没有新内容：再读一轮，计时不变
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                              ofItemAtPath: path())
        XCTAssertEqual(rows()["session:msg_s"]?.latencyMs, 30_000)
    }

    // MARK: - 上游的其余边界

    /// 估算耗时超过 1 小时（中间多半夹了休眠或长时间的重试等待）就不要，恰好 1 小时还算。
    /// 杀变异体：去掉 1 小时上限（msg_long → 3600001）；上限改成严格小于（msg_hour → 0）。
    func testLatencyLongerThanAnHourIsDropped() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_hour", 2, parent: 1, index: 0, "2026-06-07T14:00:00.000Z"),
            chain("user", 3, parent: nil, "2026-06-07T15:00:00.000Z"),
            block("msg_long", 4, parent: 3, index: 0, "2026-06-07T16:00:00.001Z"),
        ])
        let r = rows()
        XCTAssertEqual(r["session:msg_hour"]?.latencyMs, 3_600_000)
        XCTAssertEqual(r["session:msg_long"]?.latencyMs, 0)
    }

    /// 起点沿父链往上最多找 32 行：中间隔 31 条 attachment 还找得到，隔 32 条就放弃。
    /// 杀变异体：跳数上限差一（31 或 33）。
    func testRequestStartIsSearchedAtMostThirtyTwoHopsUp() throws {
        func reply(_ msg: String, base: Int, attachments: Int, minute: Int) -> [String] {
            let at = { (s: String) in String(format: "2026-06-07T13:%02d:%@Z", minute, s) }
            var lines = [chain("user", base, parent: nil, at("00.000"))]
            for i in 0..<attachments {
                lines.append(chain("attachment", base + 1 + i, parent: base + i, at("00.001")))
            }
            lines.append(block(msg, base + 1 + attachments, parent: base + attachments, index: 0, at("09.000")))
            return lines
        }
        try write(reply("msg_31", base: 1, attachments: 31, minute: 0)
                  + reply("msg_32", base: 100, attachments: 32, minute: 1))
        let r = rows()
        XCTAssertEqual(r["session:msg_31"]?.latencyMs, 9_000)
        XCTAssertEqual(r["session:msg_32"]?.latencyMs, 0)
    }

    /// 回看窗口 256KB（上游 CHAIN_SEED_BYTES）：起点行在游标前 200KB 处还看得到；300KB 外看不到，
    /// 这条不估（上游同样只估得到窗口里的）。
    /// 杀变异体：回看窗口放大到 512KB（far → 9000）或缩到 128KB（near → 0）；窗口不从头开始时
    /// 没丢掉第一段半行（far 窗口里那半截大行本来就解析不出来，杀不到——由 near 兜住窗口从头开始的分支）。
    func testLookBehindWindowIsTwoHundredFiftySixKilobytes() throws {
        for (name, padKB) in [("near.jsonl", 200), ("far.jsonl", 300)] {
            let msg = "msg_" + name.replacingOccurrences(of: ".jsonl", with: "")
            let before = [
                chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
                ClaudeLog.padding(bytes: padKB * 1024),
            ]
            try write(before + [block(msg, 2, parent: 1, index: 0, "2026-06-07T13:00:09.000Z")], to: name)
            try setByteCursor(bytes(before), for: name)
        }
        let r = rows()
        XCTAssertEqual(r["session:msg_near"]?.latencyMs, 9_000)
        XCTAssertEqual(r["session:msg_far"]?.latencyMs, 0)
    }

    /// 结束取各块时间戳里最晚的（Option::max）：后写的块时间戳更早、或者干脆没有时间戳，都不能把结束往回拉。
    /// 杀变异体：结束取最后出现的那一块（msg_skew → 3000、msg_nots → 0）。
    func testReplyEndIsTheLatestBlockTimestamp() throws {
        let noTimestamp = block("msg_nots", 6, parent: 5, index: 1, "2026-06-07T13:01:09.000Z")
            .replacingOccurrences(of: #""timestamp":"2026-06-07T13:01:09.000Z","#, with: "")
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_skew", 2, parent: 1, index: 0, "2026-06-07T13:00:05.000Z"),
            block("msg_skew", 3, parent: 2, index: 1, "2026-06-07T13:00:03.000Z"),
            chain("user", 4, parent: nil, "2026-06-07T13:01:00.000Z"),
            block("msg_nots", 5, parent: 4, index: 0, "2026-06-07T13:01:05.000Z"),
            noTimestamp,
        ])
        XCTAssertFalse(noTimestamp.contains("timestamp"), "前提：第二块真的没有时间戳")
        let r = rows()
        XCTAssertEqual(r["session:msg_skew"]?.latencyMs, 5_000)
        XCTAssertEqual(r["session:msg_nots"]?.latencyMs, 5_000)
    }

    // MARK: - 叠加层特有的路径

    /// 起点行被叠加层自己的上一轮续读读走（cc-switch 不在、文件持续追加的常态）。
    /// 杀变异体：叠加层自己续读时不回看（→ 0）。
    func testLatencyStartIsFoundBeforeTheOverlaysOwnProgress() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            chain("attachment", 2, parent: 1, "2026-06-07T13:00:00.003Z"),
        ])
        XCTAssertTrue(rows().isEmpty)
        try append([block("msg_t", 3, parent: 2, index: 0, "2026-06-07T13:00:09.000Z")])
        XCTAssertEqual(rows()["session:msg_t"]?.latencyMs, 9_000)
    }

    /// 起点行是个大行（带截图的工具结果，几百 KB 到几 MB），上一轮续读已经读走，回复下一轮才到。叠加层每个
    /// 刷新 tick 都续读，每轮只回看 256KB 的话，回看窗口正好落在这个大行中间、起点就找不到了（真机复现过）；
    /// cc-switch 隔很久一次读完，起点和回复在同一次读取里，算得出来。对话链要跨轮保留。
    /// 杀变异体：续读时重新建对话链、只靠 256KB 回看（→ 0）。
    func testStartLineReadInAnEarlierTickIsKeptEvenIfHuge() throws {
        let hugeToolResult = chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z")
            .replacingOccurrences(of: #""sessionId":"session-t"}"#,
                                  with: #""sessionId":"session-t","toolUseResult":{"image":""# + String(repeating: "A", count: 600 * 1024) + #""}}"#)
        try write([hugeToolResult])
        XCTAssertTrue(rows().isEmpty)
        try append([block("msg_t", 2, parent: 1, index: 0, "2026-06-07T13:00:09.000Z")])
        XCTAssertEqual(rows()["session:msg_t"]?.latencyMs, 9_000)
    }

    /// 旧行号游标（A/B 态，cc-switch v18 之前写的）：被跳过的行上游只数不解析、不记进对话链，叠加层也不记。
    /// 起点在跳过的行里时这条不估，与 cc-switch 将来补录的值一致。
    /// 杀变异体：跳过的行也记进对话链（→ 9000）。
    func testLegacyLineCursorDoesNotRecordSkippedLines() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            chain("attachment", 2, parent: 1, "2026-06-07T13:00:00.003Z"),
            block("msg_t", 3, parent: 2, index: 0, "2026-06-07T13:00:09.000Z"),
        ])
        try Fixture.exec(dbPath, "INSERT INTO session_log_sync VALUES('\(path())', 0, 2);")
        let r = rows()
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r["session:msg_t"]?.latencyMs, 0)
    }

    /// 后来的块输出更大、替换了这一行，而这一轮估不出计时（结束拖到了 2 小时后，超出 1 小时的合理范围）：
    /// 保留先前估出的耗时（上游 refresh 的规则：这一轮估不出来就原样保留）。
    /// 杀变异体：替换出来的新行不带旧计时（→ 0）。
    func testReplacedRowKeepsTimingEstimatedEarlier() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            block("msg_t", 2, parent: 1, index: 0, "2026-06-07T13:00:05.000Z"),
        ])
        XCTAssertEqual(rows()["session:msg_t"]?.latencyMs, 5_000)

        try append([block("msg_t", 3, parent: 2, index: 1, "2026-06-07T15:00:05.000Z", output: 1_200)])
        let r = try XCTUnwrap(rows()["session:msg_t"])
        XCTAssertEqual(r.output, 1_200, "前提：输出更大的块替换了这一行")
        XCTAssertEqual(r.latencyMs, 5_000)
    }

    // MARK: - 合并规则、合理范围、日志里的数字（纯函数）

    /// 一行已有的计时并上新估的：耗时取大、首字先到先得；这一轮估不出来原样保留。
    /// 杀变异体：耗时直接用新值（第二条 → 3000）；首字用新值覆盖旧值（第三条 → 1000）；估不出来时清空旧值。
    func testMergeKeepsTheLongerLatencyAndTheFirstFirstToken() {
        func merged(_ latency: Int64, _ firstToken: Int64?, _ new: SessionTiming.Estimate?) -> [Int64?] {
            let r = SessionTiming.merged(latencyMs: latency, firstTokenMs: firstToken, with: new)
            return [r.latencyMs, r.firstTokenMs]
        }
        typealias E = SessionTiming.Estimate
        XCTAssertEqual(merged(0, nil, E(latencyMs: 5000, firstTokenMs: 2000)), [5000, 2000])
        XCTAssertEqual(merged(5000, nil, E(latencyMs: 3000, firstTokenMs: nil)), [5000, nil])
        XCTAssertEqual(merged(5000, 800, E(latencyMs: 6000, firstTokenMs: 1000)), [6000, 800])
        XCTAssertEqual(merged(5000, nil, E(latencyMs: 6000, firstTokenMs: 1000)), [6000, 1000])
        XCTAssertEqual(merged(5000, 800, nil), [5000, 800])
    }

    /// 合理范围：耗时 [100ms, 1h]，首字 (0, 耗时]；相减溢出返回 nil（Swift 整数溢出会直接崩）。
    /// 杀变异体：任一边界开闭写反；溢出时没拦住。
    func testPlausibleRangesAndOverflow() {
        XCTAssertNil(SessionTiming.latency(start: 0, end: 99))
        XCTAssertEqual(SessionTiming.latency(start: 0, end: 100), 100)
        XCTAssertEqual(SessionTiming.latency(start: 0, end: 3_600_000), 3_600_000)
        XCTAssertNil(SessionTiming.latency(start: 0, end: 3_600_001))
        XCTAssertNil(SessionTiming.latency(start: 5000, end: 1000))
        XCTAssertNil(SessionTiming.firstToken(start: 1000, firstOutput: 1000, latency: 5000))
        XCTAssertEqual(SessionTiming.firstToken(start: 1000, firstOutput: 1001, latency: 5000), 1)
        XCTAssertEqual(SessionTiming.firstToken(start: 1000, firstOutput: 6000, latency: 5000), 5000)
        XCTAssertNil(SessionTiming.firstToken(start: 1000, firstOutput: 6001, latency: 5000))
        // 相减溢出：回绕后恰好是 100，落在合理范围里，也必须拦住
        XCTAssertNil(SessionTiming.latency(start: Int64.max - 49, end: Int64.min + 50))
        XCTAssertNil(SessionTiming.firstToken(start: Int64.max - 49, firstOutput: Int64.min + 50, latency: 5000))
    }

    /// 日志里的数字：thinkingDurationMs / apiBlockIndex 只认整数（serde_json 的 as_i64：布尔、小数都不算）；
    /// OMP 的毫秒数可以带小数，四舍五入。
    /// 杀变异体：false 当成 0（apiBlockIndex: false 会被当成第一块）；3.0 当成整数；布尔当毫秒数。
    func testJSONNumberHelpers() throws {
        let json = #"{"i":3,"z":0,"f":3.0,"t":true,"fz":false,"s":"3","d":24760.5,"n":null}"#
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
        XCTAssertEqual(SessionTiming.jsonInteger(obj["i"]), 3)
        XCTAssertEqual(SessionTiming.jsonInteger(obj["z"]), 0)
        XCTAssertNil(SessionTiming.jsonInteger(obj["f"]))
        XCTAssertNil(SessionTiming.jsonInteger(obj["t"]))
        XCTAssertNil(SessionTiming.jsonInteger(obj["fz"]))
        XCTAssertNil(SessionTiming.jsonInteger(obj["s"]))
        XCTAssertNil(SessionTiming.jsonInteger(obj["n"]))
        XCTAssertNil(SessionTiming.jsonInteger(obj["missing"]))
        XCTAssertEqual(SessionTiming.jsonMillis(obj["d"]), 24_761)
        XCTAssertEqual(SessionTiming.jsonMillis(obj["i"]), 3)
        XCTAssertNil(SessionTiming.jsonMillis(obj["t"]))
        XCTAssertNil(SessionTiming.jsonMillis(obj["s"]))
        XCTAssertNil(SessionTiming.jsonMillis(obj["n"]))
    }

    /// apiBlockIndex 是 false / 小数 / null 时都不算第一块（上游 as_u64 取不出 0），这条回复不估。
    /// 杀变异体：apiBlockIndex 判定把布尔、小数或 null 当成 0。
    func testNonIntegerBlockIndexIsNotTheFirstBlock() throws {
        func reply(_ msg: String, _ base: Int, index: String, minute: Int) -> [String] {
            let line = ClaudeLog.block(msg, base + 1, parent: base, index: 0,
                                       String(format: "2026-06-07T13:%02d:09.000Z", minute))
                .replacingOccurrences(of: #""apiBlockIndex":0"#, with: #""apiBlockIndex":\#(index)"#)
            return [chain("user", base, parent: nil, String(format: "2026-06-07T13:%02d:00.000Z", minute)), line]
        }
        try write(reply("msg_false", 1, index: "false", minute: 0)
                  + reply("msg_float", 10, index: "0.0", minute: 1)
                  + reply("msg_null", 20, index: "null", minute: 2)
                  + reply("msg_zero", 30, index: "0", minute: 3))
        let r = rows()
        XCTAssertEqual(r["session:msg_false"]?.latencyMs, 0)
        XCTAssertEqual(r["session:msg_float"]?.latencyMs, 0)
        XCTAssertEqual(r["session:msg_null"]?.latencyMs, 0)
        XCTAssertEqual(r["session:msg_zero"]?.latencyMs, 9_000, "对照：整数 0 是第一块")
    }

    // MARK: - 走到 Request Logs

    /// Request Logs 里的叠加行带上计时（早先恒为 0 / nil，界面显示「—」）。
    /// 杀变异体：requestLogs 给叠加行写死 latencyMs 0 / firstTokenMs nil。
    func testRequestLogsCarryOverlayTiming() throws {
        try write([
            chain("user", 1, parent: nil, "2026-06-07T13:00:00.000Z"),
            thinking("msg_think", 2, parent: 1, "2026-06-07T13:00:05.000Z", durationMs: 3_000),
        ])
        let store = UsageStore(path: dbPath, overlay: overlay, ompOverlay: try Fixture.emptyOmpOverlay())
        let page = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 20)
        let row = try XCTUnwrap(page.rows.first { $0.requestId == "session:msg_think" })
        XCTAssertEqual(row.latencyMs, 5_000)
        XCTAssertEqual(row.firstTokenMs, 2_000)
        XCTAssertEqual(row.dataSource, "session_log")
    }
}
