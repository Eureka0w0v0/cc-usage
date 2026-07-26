import XCTest
import SQLite3

// OmpOverlay 端到端：临时 sessions 目录 + 临时库，覆盖 OMP 日志解析、归属分流、
// 自带成本采用、增量续读，以及与 SessionOverlay 共用命名空间的防双算语义。
final class OmpOverlayTests: XCTestCase {
    private var dbPath = ""
    private var sessionsDir = ""
    private var overlay: OmpOverlay!
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("omp")
        sessionsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-omp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (sessionsDir as NSString).appendingPathComponent("-Proj"),
            withIntermediateDirectories: true)
        overlay = OmpOverlay(sessionsDir: sessionsDir, minRefreshInterval: 0)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: sessionsDir)
    }

    private func sessionFile(_ name: String = "sess.jsonl") -> String {
        ((sessionsDir as NSString).appendingPathComponent("-Proj") as NSString)
            .appendingPathComponent(name)
    }

    @discardableResult
    private func write(_ lines: [String], to name: String = "sess.jsonl") throws -> String {
        let path = sessionFile(name)
        try (lines.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// OMP 的 assistant 消息行：usage 用 input/output/cacheRead/cacheWrite，
    /// 成本自带，timestamp 是毫秒 epoch。
    private func msgLine(rid: String, provider: String, model: String,
                         output: Int = 100, input: Int = 10,
                         cacheRead: Int = 0, cacheWrite: Int = 0,
                         cost: Double = 0.5, tsMs: Int64 = 1_785_072_483_377) -> String {
        #"""
        {"type":"message","id":"e1","timestamp":"2026-07-26T13:28:12.890Z","message":{"role":"assistant","provider":"\#(provider)","model":"\#(model)","responseId":"\#(rid)","timestamp":\#(tsMs),"usage":{"input":\#(input),"output":\#(output),"cacheRead":\#(cacheRead),"cacheWrite":\#(cacheWrite),"totalTokens":\#(input + output + cacheRead + cacheWrite),"cost":{"input":0.1,"output":0.2,"cacheRead":0.1,"cacheWrite":0.1,"total":\#(cost)}}}}
        """#
    }

    // MARK: - 归属分流（本次修复的核心：Claude 的账不能记到 Grok 头上，反之亦然）

    func testClassifyRoutesByModelFamily() {
        XCTAssertEqual(OmpOverlay.classify(provider: "anthropic", model: "claude-opus-5").appType, "claude")
        XCTAssertEqual(OmpOverlay.classify(provider: "custom-gateway", model: "grok-4.5").appType, "grokbuild")
        XCTAssertEqual(OmpOverlay.classify(provider: "google", model: "gemini-3-pro").appType, "gemini")
        XCTAssertEqual(OmpOverlay.classify(provider: "openai", model: "gpt-5.5").appType, "codex")
        XCTAssertEqual(OmpOverlay.classify(provider: "openai", model: "o3-mini").appType, "codex")
        // 第三方中转的 Claude 仍是 Claude（provider 名不参与家族判定）
        XCTAssertEqual(OmpOverlay.classify(provider: "xrapi", model: "claude-haiku-4-5").appType, "claude")
        // 认不出 → 归 claude，但 provider 名照实透出
        let unknown = OmpOverlay.classify(provider: "weird", model: "mystery-1")
        XCTAssertEqual(unknown.appType, "claude")
        XCTAssertEqual(unknown.providerName, "OMP (weird)")
    }

    func testProviderIdsAreDistinctPerProvider() {
        let a = OmpOverlay.classify(provider: "anthropic", model: "claude-opus-5")
        let g = OmpOverlay.classify(provider: "custom-gateway", model: "grok-4.5")
        XCTAssertNotEqual(a.providerId, g.providerId)
    }

    func testMixedProvidersSplitIntoOwnAppTypes() throws {
        try write([
            msgLine(rid: "msg_a1", provider: "anthropic", model: "claude-opus-5", output: 100, cost: 1.0),
            msgLine(rid: "gw-1", provider: "custom-gateway", model: "grok-4.5", output: 200, cost: 0),
        ])
        let rows = overlay.pendingRows(db: db)
        XCTAssertEqual(rows.count, 2)
        let claude = try XCTUnwrap(rows.first { $0.appType == "claude" })
        let grok = try XCTUnwrap(rows.first { $0.appType == "grokbuild" })
        XCTAssertEqual(claude.output, 100)
        XCTAssertEqual(grok.output, 200)
        XCTAssertEqual(claude.totalCost, 1.0, accuracy: 1e-12)
    }

    // MARK: - 解析

    func testUsesOwnCostAndMillisecondTimestamp() throws {
        try write([msgLine(rid: "msg_c1", provider: "anthropic", model: "claude-opus-5",
                           output: 453, input: 2, cacheRead: 49_679, cacheWrite: 166,
                           cost: 0.037212, tsMs: 1_785_072_483_377)])
        let r = try XCTUnwrap(overlay.pendingRows(db: db).first)
        XCTAssertEqual(r.input, 2)
        XCTAssertEqual(r.output, 453)
        XCTAssertEqual(r.cacheRead, 49_679)
        XCTAssertEqual(r.cacheCreation, 166)
        // 直接采用 OMP 自带成本，不走 cc-switch 价格表（那里根本没有这些自定义端点）
        XCTAssertEqual(r.totalCost, 0.037212, accuracy: 1e-12)
        XCTAssertEqual(r.createdAt, 1_785_072_483)   // 毫秒 → 秒
    }

    func testSkipsNonAssistantAndZeroUsage() throws {
        try write([
            #"{"type":"session","id":"s1","timestamp":"2026-07-26T13:00:00.000Z"}"#,
            #"{"type":"message","id":"u1","message":{"role":"user","content":"hi"}}"#,
            msgLine(rid: "msg_z", provider: "anthropic", model: "claude-opus-5",
                    output: 0, input: 0, cost: 0),
            msgLine(rid: "msg_ok", provider: "anthropic", model: "claude-opus-5", output: 5),
        ])
        XCTAssertEqual(overlay.pendingRows(db: db).map(\.requestId), ["session:msg_ok"])
    }

    func testIgnoresPartialTrailingLine() throws {
        let path = sessionFile()
        let good = msgLine(rid: "msg_p1", provider: "anthropic", model: "claude-opus-5", output: 9)
        try (good + "\n" + #"{"type":"message","message":{"role":"assis"#)
            .write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)
    }

    func testRecursesIntoSubagentDirectories() throws {
        let nested = ((sessionsDir as NSString).appendingPathComponent("-Proj") as NSString)
            .appendingPathComponent("sess/subagents")
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try (msgLine(rid: "msg_sub", provider: "anthropic", model: "claude-opus-5", output: 3) + "\n")
            .write(toFile: (nested as NSString).appendingPathComponent("Scout.jsonl"),
                   atomically: true, encoding: .utf8)
        XCTAssertEqual(overlay.pendingRows(db: db).map(\.requestId), ["session:msg_sub"])
    }

    // MARK: - request_id 命名空间（防双算的支点）

    func testRequestIdNamespaces() {
        // Anthropic msg id 与 cc-switch / SessionOverlay 同命名空间 → 同一条只算一次
        XCTAssertEqual(OmpOverlay.requestId(responseId: "msg_abc", path: "/x/a.jsonl", byteOffset: 0),
                       "session:msg_abc")
        // 其它 id 走私有命名空间，不会与库内行误撞
        XCTAssertEqual(OmpOverlay.requestId(responseId: "uuid-1", path: "/x/a.jsonl", byteOffset: 0),
                       "omp:uuid-1")
        // 无 id → 文件+偏移合成，重复扫描恒定
        XCTAssertEqual(OmpOverlay.requestId(responseId: nil, path: "/x/a.jsonl", byteOffset: 42),
                       "omp:a.jsonl@42")
        XCTAssertEqual(OmpOverlay.requestId(responseId: "", path: "/x/a.jsonl", byteOffset: 42),
                       "omp:a.jsonl@42")
    }

    func testPrunesRowsAlreadyInDB() throws {
        try write([msgLine(rid: "msg_d1", provider: "anthropic", model: "claude-opus-5", output: 10)])
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        // cc-switch（或 SessionOverlay 那条路径）已收录同一条 → 本层必须让位，绝不双算
        try Fixture.insertLog(dbPath, id: "session:msg_d1", output: 10, createdAt: 1)

        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty)
    }

    func testIncrementalAppend() throws {
        let path = try write([msgLine(rid: "msg_i1", provider: "anthropic", model: "claude-opus-5", output: 10)])
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)

        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        fh.seekToEndOfFile()
        fh.write((msgLine(rid: "msg_i2", provider: "anthropic", model: "claude-opus-5", output: 20) + "\n")
            .data(using: .utf8)!)
        try fh.close()


        XCTAssertEqual(Set(overlay.pendingRows(db: db).map(\.requestId)),
                       ["session:msg_i1", "session:msg_i2"])
    }

    func testVanishedFileDropsItsRows() throws {
        let path = try write([msgLine(rid: "msg_v1", provider: "anthropic", model: "claude-opus-5", output: 10)])
        XCTAssertEqual(overlay.pendingRows(db: db).count, 1)
        try FileManager.default.removeItem(atPath: path)

        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty)
    }

    // MARK: - 与 UsageStore 的合流

    func testStoreSplitsOmpUsageAcrossAppBuckets() throws {
        try write([
            msgLine(rid: "msg_s1", provider: "anthropic", model: "claude-opus-5",
                    output: 100, input: 10, cost: 1.0),
            msgLine(rid: "gw-s2", provider: "custom-gateway", model: "grok-4.5",
                    output: 200, input: 20, cost: 0),
        ])
        let store = UsageStore(path: dbPath,
                               overlay: try Fixture.emptyOverlay(),
                               ompOverlay: overlay)
        let ts = 1_785_072_483
        let byApp = try store.summaryByApp(
            UsageFilter(start: Int64(ts - 3600), end: Int64(ts + 3600)))

        let claude = try XCTUnwrap(byApp.first { $0.appType == "claude" })
        let grok = try XCTUnwrap(byApp.first { $0.appType == "grokbuild" })
        XCTAssertEqual(claude.summary.output, 100)
        XCTAssertEqual(claude.summary.cost, 1.0, accuracy: 1e-12)
        XCTAssertEqual(grok.summary.output, 200)
        XCTAssertEqual(grok.summary.cost, 0, accuracy: 1e-12)
    }

    func testStoreProviderStatsKeepProvidersSeparate() throws {
        try write([
            msgLine(rid: "msg_p1", provider: "anthropic", model: "claude-opus-5", output: 100, cost: 1.0),
            msgLine(rid: "gw-p2", provider: "custom-gateway", model: "grok-4.5", output: 200, cost: 0),
        ])
        let store = UsageStore(path: dbPath,
                               overlay: try Fixture.emptyOverlay(),
                               ompOverlay: overlay)
        let ts = Int64(1_785_072_483)
        let stats = try store.providerStats(LogQueryFilter(start: ts - 3600, end: ts + 3600))
        let names = Set(stats.map(\.providerName))
        XCTAssertTrue(names.contains("OMP (anthropic)"))
        XCTAssertTrue(names.contains("OMP (custom-gateway)"))
        let anthropic = try XCTUnwrap(stats.first { $0.providerName == "OMP (anthropic)" })
        XCTAssertEqual(anthropic.requestCount, 1)
        XCTAssertEqual(anthropic.totalCost, 1.0, accuracy: 1e-12)
    }

    /// 跨 overlay 防双算。这是 OmpOverlay 复用 "session:<msg_id>" 命名空间的全部意义，
    /// 也是 UsageStore.overlayRows 里那条「两层都非空 → 按 requestId 去重」分支唯一的
    /// 守卫：其余用例都把 SessionOverlay 置空（rows.isEmpty 恒真），该分支从不执行，
    /// 把它写成无条件 append 也照样全绿。
    func testSameMessageIdSeenByBothOverlaysCountsOnce() throws {
        let msgId = "msg_shared1"

        // OMP 侧记了这条 anthropic 响应
        try write([msgLine(rid: msgId, provider: "anthropic", model: "claude-opus-5",
                           output: 100, input: 10, cost: 1.0)])

        // Claude Code 侧也记了同一个 message.id
        let projects = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-omp-proj-\(UUID().uuidString)")
        let projDir = (projects as NSString).appendingPathComponent("p1")
        try FileManager.default.createDirectory(atPath: projDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: projects) }
        let ccLine = #"""
        {"type":"assistant","sessionId":"s1","timestamp":"2026-07-26T13:28:12Z","message":{"id":"\#(msgId)","stop_reason":"end_turn","model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":100}}}
        """#
        try (ccLine + "\n").write(
            toFile: (projDir as NSString).appendingPathComponent("s.jsonl"),
            atomically: true, encoding: .utf8)

        let store = UsageStore(
            path: dbPath,
            overlay: SessionOverlay(projectsDir: projects, minRefreshInterval: 0),
            ompOverlay: overlay)
        let ts = Int64(1_785_072_483)
        let s = try store.rangeSummary(UsageFilter(start: ts - 3600, end: ts + 3600))

        XCTAssertEqual(s.requests, 1, "同一 msg_id 被两层各看见一次，合流后必须只算一次")
        XCTAssertEqual(s.output, 100)
    }
}
