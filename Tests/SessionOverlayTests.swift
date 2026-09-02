import XCTest
import SQLite3

// SessionOverlay 端到端：临时 projects 目录 + 临时库，覆盖 JSONL 解析、message.id 去重、
// 库内定价、增量续读与「入库即剔除」的交接语义。
final class SessionOverlayTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var overlay: SessionOverlay!
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("overlay")
        try Fixture.exec(dbPath,
            "INSERT INTO model_pricing VALUES('claude-sonnet-5','3','15','0.3','3.75');")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-ovl-\(UUID().uuidString)")
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
    }

    private func sessionFile(_ name: String = "sess.jsonl") -> String {
        ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent(name)
    }

    private func writeSession(_ lines: [String]) throws -> String {
        let path = sessionFile()
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func assistantLine(id: String, output: Int, input: Int = 100,
                               stop: Bool, ts: String = "2026-07-08T10:00:00Z") -> String {
        let stopField = stop ? "\"stop_reason\":\"end_turn\"," : ""
        return #"{"type":"assistant","sessionId":"s1","timestamp":"\#(ts)","message":{"id":"\#(id)",\#(stopField)"model":"claude-sonnet-5","usage":{"input_tokens":\#(input),"output_tokens":\#(output)}}}"#
    }

    func testParseDedupAndPricing() throws {
        _ = try writeSession([
            assistantLine(id: "m1", output: 10, stop: false),
            assistantLine(id: "m1", output: 20, stop: true),           // stop_reason 优先 → 替换
            assistantLine(id: "m2", output: 0, input: 0, stop: true),  // 零用量 → 不计
            #"{"type":"user","text":"hi"}"#,                           // 非 assistant → 不计
        ])
        let rows = overlay.pendingRows(db: db)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.requestId, "session:m1")
        XCTAssertEqual(r.output, 20)
        XCTAssertEqual(r.createdAt, ISO8601Lenient.epochSeconds("2026-07-08T10:00:00Z"))
        // 100×$3/1M + 20×$15/1M
        XCTAssertEqual(r.totalCost, 0.0006, accuracy: 1e-12)
    }

    // 库里没有该模型（上游 seed 尚未收录 Fable 5.1）→ 回落内置表，且缓存读按 $0.25 而非 $1。
    // 负责杀的变异体：删掉内置表 fable-5-1 行（成本归 0）/ 缓存读抄成 1（成本 1.002）。
    func testUnseededModelFallsBackToBuiltinWithQuarterCacheRead() throws {
        _ = try writeSession([
            #"{"type":"assistant","sessionId":"s1","timestamp":"2026-09-01T10:00:00Z","message":{"id":"f1","stop_reason":"end_turn","model":"claude-fable-5-1","usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":1000000,"cache_creation_input_tokens":0}}}"#,
        ])
        let rows = overlay.pendingRows(db: db)
        XCTAssertEqual(rows.count, 1)
        let r = try XCTUnwrap(rows.first)
        XCTAssertEqual(r.model, "claude-fable-5-1")
        XCTAssertEqual(r.cacheReadCost, 0.25, accuracy: 1e-12)
        // 100×$10/1M + 20×$50/1M + 1M×$0.25/1M
        XCTAssertEqual(r.totalCost, 0.252, accuracy: 1e-12)
    }

    func testIncrementalAppendAndPruneOnceInDB() throws {
        let file = try writeSession([assistantLine(id: "m1", output: 10, stop: true)])
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        // 文件尾部追加一行；同时 cc-switch「补录」了 m1 → 重扫后应只剩 m3
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: file))
        fh.seekToEndOfFile()
        fh.write((assistantLine(id: "m3", output: 7, stop: true) + "\n").data(using: .utf8)!)
        try fh.close()
        try Fixture.insertLog(dbPath, id: "session:m1", output: 10, createdAt: 1)


        let rows = overlay.pendingRows(db: db)
        XCTAssertEqual(rows.map(\.requestId), ["session:m3"])
        XCTAssertEqual(rows.first?.output, 7)
    }
}
