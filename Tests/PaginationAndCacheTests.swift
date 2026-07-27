import XCTest
import SQLite3

// 覆盖两处新增行为：
//
//   1. requestLogs 的二路归并分页。旧实现把符合条件的增量行**整批**塞进第 0 页
//      (无视 pageSize)，于是 total 把它们算了进去、第 1 页之后却一条不给——逐页
//      拉全量既取不回全集，跨页时间序也是断的。现在两路按 created_at DESC 归并后
//      统一切页。
//
//   2. DirListCache 的失效检测。文件列表现在带缓存，只在目录 mtime 变动时重新
//      枚举——必须证明「新文件 / 新目录」一出现就被看见，且「文件内容追加」这种
//      不改父目录 mtime 的变化也绝不会被预检误判成「无事发生」。
final class PaginationAndCacheTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var overlay: SessionOverlay!
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("pagemerge")
        try Fixture.exec(dbPath,
            "INSERT INTO model_pricing VALUES('claude-sonnet-5','3','15','0.3','3.75');")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-pm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        overlay = SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
        Fixture.cleanTempDirs()
    }

    // MARK: - 夹具

    private func proj(_ rel: String) -> String {
        ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent(rel)
    }

    private static let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private func iso(_ epoch: Int64) -> String {
        Self.isoFmt.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// 一条计费的 assistant 行，created_at 由 epoch 精确指定。
    private func line(id: String, at epoch: Int64, output: Int = 10) -> String {
        #"{"type":"assistant","sessionId":"s1","timestamp":"\#(iso(epoch))","message":{"id":"\#(id)","stop_reason":"end_turn","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"#
    }

    private func write(_ lines: [String], to path: String) throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func makeStore() throws -> UsageStore {
        UsageStore(path: dbPath, overlay: overlay, ompOverlay: try Fixture.emptyOmpOverlay())
    }

    // MARK: - 1. 归并分页

    /// 库内行与增量行时间交错，逼出真正的归并（简单拼接会当场露馅）。
    func testPagesMergeOverlayAndDBInTimeOrder() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        for (i, off) in [100, 300, 500].enumerated() {
            try Fixture.insertLog(dbPath, id: "dblog\(i)", output: 1, createdAt: base + Int64(off))
        }
        try write([line(id: "m1", at: base + 200),
                   line(id: "m2", at: base + 400),
                   line(id: "m3", at: base + 600)], to: proj("sess.jsonl"))

        let store = try makeStore()
        // 全局降序应为：m3(600) db2(500) m2(400) db1(300) m1(200) db0(100)
        let expected = ["session:m3", "dblog2", "session:m2", "dblog1", "session:m1", "dblog0"]

        var collected: [String] = []
        for p in 0..<4 {
            let page = try store.requestLogs(LogQueryFilter(), page: p, pageSize: 2)
            XCTAssertEqual(page.total, 6, "total 必须含增量行且与页无关")
            XCTAssertLessThanOrEqual(page.rows.count, 2, "第 \(p) 页超出了 pageSize")
            collected.append(contentsOf: page.rows.map(\.requestId))
        }
        XCTAssertEqual(collected, expected, "跨页拼接应等于全局时间倒序，且无重无漏")
    }

    /// 增量行数量远超 pageSize 时，第 0 页也只能给 pageSize 条
    /// （旧实现在这里会把 50 条全吐出来）。
    func testPageZeroNeverExceedsPageSizeWithManyOverlayRows() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write((0..<50).map { line(id: "x\($0)", at: base + Int64($0)) }, to: proj("sess.jsonl"))

        let page = try makeStore().requestLogs(LogQueryFilter(), page: 0, pageSize: 5)
        XCTAssertEqual(page.rows.count, 5)
        XCTAssertEqual(page.total, 50)
        XCTAssertEqual(page.rows.map(\.requestId),
                       ["session:x49", "session:x48", "session:x47", "session:x46", "session:x45"])
    }

    /// 没有增量行时的纯库内分页不受归并改动影响。
    func testDBOnlyPaginationUnaffected() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        for i in 0..<5 {
            try Fixture.insertLog(dbPath, id: "d\(i)", output: 1, createdAt: base + Int64(i))
        }
        let store = try makeStore()
        let p0 = try store.requestLogs(LogQueryFilter(), page: 0, pageSize: 2)
        let p1 = try store.requestLogs(LogQueryFilter(), page: 1, pageSize: 2)
        let p2 = try store.requestLogs(LogQueryFilter(), page: 2, pageSize: 2)
        XCTAssertEqual(p0.total, 5)
        XCTAssertEqual(p0.rows.map(\.requestId), ["d4", "d3"])
        XCTAssertEqual(p1.rows.map(\.requestId), ["d2", "d1"])
        XCTAssertEqual(p2.rows.map(\.requestId), ["d0"])
    }

    /// 翻过尾页要给空数组，不能越界崩。
    func testPageBeyondEndIsEmpty() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "only", output: 1, createdAt: base)
        try write([line(id: "m1", at: base + 10)], to: proj("sess.jsonl"))
        let page = try makeStore().requestLogs(LogQueryFilter(), page: 9, pageSize: 20)
        XCTAssertTrue(page.rows.isEmpty)
        XCTAssertEqual(page.total, 2)
    }

    // MARK: - 2. 文件列表缓存的失效

    /// 追加不会改父目录 mtime——目录缓存会命中，但逐文件 mtime 必须让预检失败。
    /// 这是缓存与短路两层叠加后最容易漏掉的一格。
    func testAppendIsSeenEvenThoughDirMtimeUnchanged() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        let path = proj("sess.jsonl")
        try write([line(id: "a1", at: base)], to: path)
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        fh.seekToEndOfFile()
        fh.write((line(id: "a2", at: base + 1) + "\n").data(using: .utf8)!)
        try fh.close()

        XCTAssertEqual(Set(overlay.pendingRows(db: db).map(\.requestId)),
                       ["session:a1", "session:a2"])
    }

    /// 同目录里新出现的会话文件必须立刻被看见。
    func testNewSiblingFileInvalidatesCache() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write([line(id: "b1", at: base)], to: proj("one.jsonl"))
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        try write([line(id: "b2", at: base + 1)], to: proj("two.jsonl"))
        XCTAssertEqual(Set(overlay.pendingRows(db: db).map(\.requestId)),
                       ["session:b1", "session:b2"])
    }

    /// 会话目录先于 subagents/ 存在，subagents/ 后来才长出来——只有把会话目录本身
    /// 记进缓存的目录集，这一层的变化才看得见。
    func testSubagentsDirCreatedLaterInvalidatesCache() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write([line(id: "c1", at: base)], to: proj("main.jsonl"))
        // 会话目录此刻存在但还没有 subagents/
        try FileManager.default.createDirectory(atPath: proj("sessdir"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        try write([line(id: "c2", at: base + 1)], to: proj("sessdir/subagents/agent.jsonl"))
        XCTAssertEqual(Set(overlay.pendingRows(db: db).map(\.requestId)),
                       ["session:c1", "session:c2"],
                       "会话目录下新建的 subagents/ 未被发现——目录集漏记了会话目录本身")
    }

    /// workflows 那一层同理（缓存要一路记到最深的枚举点）。
    func testWorkflowDirCreatedLaterInvalidatesCache() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write([line(id: "w1", at: base)], to: proj("sessdir/subagents/a.jsonl"))
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        try write([line(id: "w2", at: base + 1)],
                  to: proj("sessdir/subagents/workflows/wf_1/b.jsonl"))
        XCTAssertEqual(Set(overlay.pendingRows(db: db).map(\.requestId)),
                       ["session:w1", "session:w2"])
    }

    /// 文件消失后其行要跟着消失——短路逻辑不能把「少了一个文件」看成无事发生。
    func testVanishedFileStillDropsItsRows() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write([line(id: "v1", at: base)], to: proj("gone.jsonl"))
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        try FileManager.default.removeItem(atPath: proj("gone.jsonl"))
        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty)
    }

    /// cc-switch 补录后，叠加层要按 request_id 让位——库水位变动必须打破短路。
    func testDBBackfillBreaksShortCircuit() throws {
        let base = Fixture.ts(2026, 6, 10, 12)
        try write([line(id: "p1", at: base), line(id: "p2", at: base + 1)],
                  to: proj("sess.jsonl"))
        XCTAssertEqual(overlay.pendingRows(db: db).count, 2)

        // 文件一个字节没动，只有库长了一行
        try Fixture.insertLog(dbPath, id: "session:p1", output: 10, createdAt: base)
        XCTAssertEqual(overlay.pendingRows(db: db).map(\.requestId), ["session:p2"])
    }
}
