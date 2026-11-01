import XCTest
import SQLite3

// OmpOverlay 端到端：临时 sessions 目录 + 临时库。覆盖对齐上游 v4.0.22 OMP 导入后的口径——
// 整文件规则、跨文件去重、入库剔除（明细 / 账本 / semantic）、成本回落、展示名、续读与改写、
// 以及叠加行进入 UsageStore 后的分组与状态码。
final class OmpOverlayTests: XCTestCase {
    private var dbPath = ""
    private var sessionsDir = ""
    private var overlay: OmpOverlay!
    private var db: OpaquePointer!

    private static let title = #"{"type":"title","v":1,"title":"","updatedAt":"2026-10-29T13:17:48.750Z","pad":""}"#
    private static func header(_ id: String = "s1") -> String {
        #"{"type":"session","version":3,"id":"\#(id)","timestamp":"2026-10-29T13:16:32.926Z","cwd":"/work"}"#
    }

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("omp")
        sessionsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-omp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (sessionsDir as NSString).appendingPathComponent("-Proj"),
            withIntermediateDirectories: true)
        overlay = OmpOverlay(sessionsDir: sessionsDir, minRefreshInterval: 0, pricingTTL: 0)
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: sessionsDir)
    }

    private func path(_ name: String) -> String {
        ((sessionsDir as NSString).appendingPathComponent("-Proj") as NSString).appendingPathComponent(name)
    }

    /// 写一个会话文件：默认带 title 行与 header（Oh My Pi 的真实开头）。
    @discardableResult
    private func write(_ entries: [String], to name: String = "sess.jsonl", header: Bool = true,
                       trailingNewline: Bool = true) throws -> String {
        let p = path(name)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let lines = (header ? [Self.title, Self.header()] : []) + entries
        try (lines.joined(separator: "\n") + (trailingNewline ? "\n" : ""))
            .write(toFile: p, atomically: true, encoding: .utf8)
        return p
    }

    private func append(_ text: String, to name: String = "sess.jsonl") throws {
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: path(name)))
        try fh.seekToEnd()
        try fh.write(contentsOf: Data(text.utf8))
        try fh.close()
    }

    /// assistant 条目。cost = nil 表示不带自报成本（交给查价）。
    private func assistant(_ id: String, provider: String = "anthropic", model: String = "claude-opus-5-5",
                           input: Int = 10, output: Int = 100, cost: Double? = 0.5,
                           stop: String = "stop", error: String? = nil,
                           ts: String = "2026-10-29T13:17:42.984Z", duration: Double? = nil) -> String {
        let costJSON = cost.map { #","cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":\#($0)}"# } ?? ""
        let errorJSON = error.map { #","errorMessage":"\#($0)""# } ?? ""
        let durationJSON = duration.map { #","duration":\#($0)"# } ?? ""
        return #"{"type":"message","id":"\#(id)","parentId":null,"timestamp":"\#(ts)","message":{"role":"assistant","content":[],"provider":"\#(provider)","model":"\#(model)"\#(durationJSON),"usage":{"input":\#(input),"output":\#(output),"cacheRead":0,"cacheWrite":0\#(costJSON)},"stopReason":"\#(stop)"\#(errorJSON)}}"#
    }

    private func rows() -> [OverlayRow] { overlay.pendingRows(db: db) }

    private func requestId(_ line: String) throws -> String {
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
        return try XCTUnwrap(OmpUsage.record(from: entry, sessionId: "s1", sessionTimestamp: nil,
                                             fileTimestamp: 0)).requestId
    }

    // MARK: - 上游 imports_own_store_carriers_and_placeholders

    /// assistant、model_usage、0 用量的中断请求、compaction 占位——4 行，app_type 恒 omp。
    /// 负责杀的变异体：漏掉 model_usage / compaction；中断请求按 0 用量跳过；归属又按模型家族拆。
    func testImportsOwnStoreCarriersAndPlaceholders() throws {
        try write([
            #"{"type":"message","id":"call-1","parentId":null,"timestamp":"2026-10-29T13:17:42.984Z","message":{"role":"assistant","content":[{"type":"text","text":"ok"}],"api":"openai-completions","provider":"workbuddy","model":"deepseek-v4.1-flash","responseId":"chatcmpl-1","duration":6744.172099999996,"ttft":6192.651100000003,"usage":{"input":282,"output":194,"cacheRead":12800,"cacheWrite":0,"totalTokens":13276,"reasoningTokens":41,"cost":{"input":0.0000846,"output":0.0002328,"cacheRead":0.0000768,"cacheWrite":0,"total":0.0003942}},"stopReason":"toolUse"}}"#,
            #"{"type":"model_usage","id":"judge-1","parentId":"call-1","timestamp":"2026-10-29T13:26:53.160Z","purpose":"job-widget","api":"openai-completions","provider":"workbuddy","model":"deepseek-v4.1-flash","usage":{"input":312,"output":110,"cacheRead":2432,"cacheWrite":0,"totalTokens":2854,"cost":{"input":0.0000936,"output":0.000132,"cacheRead":0.000014592,"cacheWrite":0,"total":0.000240192}},"stopReason":"toolUse"}"#,
            #"{"type":"message","id":"call-2","parentId":"call-1","timestamp":"2026-10-29T13:28:00.000Z","message":{"role":"assistant","content":[],"api":"openai-completions","provider":"workbuddy","model":"deepseek-v4.1-flash","usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"totalTokens":0,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"aborted","errorMessage":"Request was aborted"}}"#,
            #"{"type":"compaction","id":"compact-1","parentId":"call-2","timestamp":"2026-10-29T13:29:00.000Z","summary":"summary","usage":{"input":11,"output":12,"cacheRead":2,"cacheWrite":3,"totalTokens":28,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}}}"#,
        ])
        let r = rows().sorted { $0.createdAt < $1.createdAt }
        XCTAssertEqual(r.count, 4)
        XCTAssertTrue(r.allSatisfy { $0.appType == "omp" && $0.dataSource == "omp_session" })
        XCTAssertEqual(r.map(\.input), [282, 312, 0, 11])
        XCTAssertEqual(r[0].latencyMs, 6744)
        XCTAssertNil(r[0].firstTokenMs, "上游 OMP 行没有首字")
        XCTAssertEqual(r.map(\.totalCost).reduce(0, +), 0.000634392, accuracy: 1e-12)
        XCTAssertEqual(r[2].statusCode, 499)
        XCTAssertEqual(r[2].errorMessage, "Request was aborted")
        XCTAssertEqual(r[3].providerId, "_omp_session")
        XCTAssertEqual(r[3].providerName, "Oh My Pi (Session)")
        XCTAssertEqual(r[3].model, "unknown")
    }

    /// 上游 subagent_sessions_older_than_the_first_sync_still_count：子会话文件里的用量照算；父会话 task 结果里
    /// 的 details.usage 不是 message.usage，不算。
    func testNestedSubagentSessionsCountAndTaskDetailsDoNot() throws {
        try write([
            assistant("a1", input: 100),
            #"{"type":"message","id":"task-1","parentId":"a1","timestamp":"2026-08-22T02:20:00.000Z","message":{"role":"toolResult","toolCallId":"call","toolName":"task","content":[],"details":{"usage":{"input":500,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":501,"cost":{"total":0}}}}}"#,
        ], to: "2026-08-22T02-12-51-066Z_parent.jsonl")
        try write([assistant("c1", input: 500)], to: "2026-08-22T02-12-51-066Z_parent/PageScout.jsonl")
        XCTAssertEqual(rows().map(\.input).reduce(0, +), 600)
    }

    /// pi-subagents 投影：带 usage 的 toolResult 指向的子会话都在本轮文件里 → 跳过；指向不存在的文件 → 照算。
    /// 负责杀的变异体：投影一律计入 / 一律跳过。
    func testToolResultProjectionSkippedOnlyWhenLinkedSessionsArePresent() throws {
        let child = try write([assistant("c1", input: 7)], to: "parent/child.jsonl")
        func projection(_ id: String, link: String) -> String {
            #"{"type":"message","id":"\#(id)","timestamp":"2026-10-30T02:00:00Z","message":{"role":"toolResult","toolCallId":"x","toolName":"task","content":[],"usage":{"input":7,"output":0,"cost":{"total":0}},"details":{"results":[{"sessionFile":"\#(link)"}]}}}"#
        }
        try write([projection("p-dup", link: child), projection("p-missing", link: path("gone.jsonl"))],
                  to: "parent.jsonl")
        XCTAssertEqual(Set(rows().map(\.requestId)),
                       Set([try requestId(assistant("c1", input: 7)),
                            try requestId(projection("p-missing", link: path("gone.jsonl")))]))
    }

    // MARK: - 整文件规则

    /// 负责杀的变异体：没有 header 也计入 / header 前的坏行让整个文件报错 / header id 不校验。
    func testFilesWithoutValidHeaderContributeNothing() throws {
        try write([assistant("x1")], to: "no-header.jsonl", header: false)
        try write([#"{"type":"session","id":"-bad id-"}"#, assistant("x2")], to: "bad-id.jsonl", header: false)
        try write(["not json at all", Self.title, Self.header("ok-1"), assistant("x3")], to: "garbage-first.jsonl",
                  header: false)
        XCTAssertEqual(rows().map(\.requestId), [try requestId(assistant("x3"))])
    }

    /// 超过 128 MiB 的文件整个不计入（用稀疏文件造，不占磁盘）。
    func testOversizedFileIsSkipped() throws {
        let p = try write([assistant("big")])
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: p))
        try fh.truncate(atOffset: UInt64(OmpSessionFiles.maxSessionBytes) + 1)
        try fh.close()
        XCTAssertTrue(rows().isEmpty)
    }

    /// 末行没有换行：不是合法 JSON → 等下一轮；已经是合法 JSON → 照上游计入，补上换行后不重复。
    func testUnterminatedTailCountsOnlyWhenItIsValidJSON() throws {
        try write([assistant("a1")])
        try append(String(assistant("a2").prefix(40)))
        XCTAssertEqual(rows().count, 1)
        try write([assistant("a1"), assistant("a2")], trailingNewline: false)
        XCTAssertEqual(rows().count, 2)
        try append("\n")
        XCTAssertEqual(rows().count, 2)
    }

    // MARK: - 续读

    func testIncrementalAppendRewriteAndVanish() throws {
        try write([assistant("a1")])
        XCTAssertEqual(rows().count, 1)
        try append(assistant("a2") + "\n")
        XCTAssertEqual(rows().count, 2)
        // 改写：内容整体换掉（长度还变长了）→ 从头重读，旧行不残留
        try write([assistant("b1"), assistant("b2"), assistant("b3")])
        XCTAssertEqual(Set(rows().map(\.requestId)),
                       Set(try ["b1", "b2", "b3"].map { try requestId(assistant($0)) }))
        try FileManager.default.removeItem(atPath: path("sess.jsonl"))
        XCTAssertTrue(rows().isEmpty)
    }

    // MARK: - 去重与入库剔除

    /// 同一条 entry 被复制进两个文件（fork）只算一次。负责杀的变异体：跨文件不去重。
    func testSameEntryInTwoFilesCountsOnce() throws {
        try write([assistant("dup")], to: "a.jsonl")
        try write([assistant("dup")], to: "b.jsonl")
        XCTAssertEqual(rows().count, 1)
    }

    /// cc-switch 已入库（明细在 / 只剩账本）→ 剔除。负责杀的变异体：只查明细不查账本；查账本不限 data_source。
    func testRowsAlreadyImportedByCcSwitchArePruned() throws {
        try write([assistant("in-logs"), assistant("in-ledger"), assistant("other-source"), assistant("pending")])
        try Fixture.insertLog(dbPath, id: try requestId(assistant("in-logs")), app: "omp", model: "m",
                              input: 1, output: 1, cost: 0, createdAt: 1, dataSource: "omp_session",
                              providerId: "anthropic")
        try Fixture.exec(dbPath, """
            INSERT INTO session_usage_dedup VALUES ('omp_session', '\(try requestId(assistant("in-ledger")))', 'x', 1);
            INSERT INTO session_usage_dedup VALUES ('pi_session', '\(try requestId(assistant("other-source")))', 'y', 1);
            """)
        XCTAssertEqual(Set(rows().map(\.requestId)),
                       Set([try requestId(assistant("other-source")), try requestId(assistant("pending"))]))
    }

    /// semantic 规则：有 entry id 的记录只认账本里没有 entry id 的同内容行。
    /// 负责杀的变异体：有 entry id 的记录也认 has_entry_id = 1 的 semantic 命中。
    func testSemanticLedgerMatchFollowsEntryIdRule() throws {
        let line = assistant("sem")
        try write([line])
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? NSDictionary)
        let semantic = try XCTUnwrap(OmpUsage.record(from: entry, sessionId: "s1", sessionTimestamp: nil,
                                                     fileTimestamp: 0)).semanticId
        try Fixture.exec(dbPath, "INSERT INTO session_usage_dedup VALUES ('omp_session', 'other', '\(semantic)', 1);")
        XCTAssertEqual(rows().count, 1, "has_entry_id = 1 的行不算重复")
        try Fixture.exec(dbPath, "INSERT INTO session_usage_dedup VALUES ('omp_session', 'legacy', '\(semantic)', 0);")
        XCTAssertTrue(rows().isEmpty, "没有 entry id 的旧行同内容 → 已入库")
    }

    /// 旧库（cc-switch < v17）没有账本表：只查明细，不报错。
    func testMissingLedgerTableIsTolerated() throws {
        try Fixture.exec(dbPath, "DROP TABLE session_usage_dedup;")
        try write([assistant("a1")])
        XCTAssertEqual(rows().count, 1)
    }

    /// 库里后来才入库的行，下一轮被剔除（库水位变了要重查）。
    func testRowImportedLaterIsPrunedOnNextRefresh() throws {
        try write([assistant("late")])
        XCTAssertEqual(rows().count, 1)
        try Fixture.insertLog(dbPath, id: try requestId(assistant("late")), app: "omp", model: "m",
                              input: 1, output: 1, cost: 0, createdAt: 2, dataSource: "omp_session",
                              providerId: "anthropic")
        XCTAssertTrue(rows().isEmpty)
    }

    // MARK: - 成本与展示名

    /// 自报成本 > 0 用自报；自报为 0 → 按库价；库里没有 → 内置表。负责杀的变异体：自报为 0 时不查价。
    func testZeroReportedCostFallsBackToPricing() throws {
        try Fixture.exec(dbPath, """
            INSERT INTO model_pricing VALUES ('grok-4.5', '2', '6', '0.30', '0');
            """)
        try write([
            assistant("own", model: "grok-4.5", input: 1_000_000, output: 0, cost: 0.75),
            assistant("db", model: "grok-4.5", input: 1_000_000, output: 1_000_000, cost: 0),
            assistant("builtin", model: "claude-opus-5-5", input: 1_000_000, output: 0, cost: nil),
            assistant("none", model: "totally-unknown-model", input: 5, output: 5, cost: nil),
        ])
        let byId = Dictionary(uniqueKeysWithValues: rows().map { ($0.requestId, $0) })
        XCTAssertEqual(byId[try requestId(assistant("own", model: "grok-4.5", input: 1_000_000, output: 0, cost: 0.75))]?.totalCost ?? -1, 0.75, accuracy: 1e-12)
        XCTAssertEqual(byId[try requestId(assistant("db", model: "grok-4.5", input: 1_000_000, output: 1_000_000, cost: 0))]?.totalCost ?? -1, 8, accuracy: 1e-9)
        let builtin = try XCTUnwrap(ModelPricing.lookup("claude-opus-5-5")).input
        XCTAssertEqual(byId[try requestId(assistant("builtin", model: "claude-opus-5-5", input: 1_000_000, output: 0, cost: nil))]?.totalCost ?? -1, builtin, accuracy: 1e-9)
        XCTAssertEqual(byId[try requestId(assistant("none", model: "totally-unknown-model", input: 5, output: 5, cost: nil))]?.totalCost ?? -1, 0)
    }

    /// 展示名照 provider_name_coalesce：providers 表 (id, omp) → 占位名 → 原文。别的应用同名供应商不算。
    func testProviderNameFollowsProvidersTable() throws {
        try Fixture.exec(dbPath, """
            INSERT INTO providers VALUES ('anthropic', 'Anthropic API', 'omp');
            INSERT INTO providers VALUES ('gw', 'Claude Gateway', 'claude');
            """)
        try write([assistant("a", provider: "anthropic"), assistant("g", provider: "gw")])
        let names = Dictionary(uniqueKeysWithValues: rows().map { ($0.providerId, $0.providerName) })
        XCTAssertEqual(names["anthropic"], "Anthropic API")
        XCTAssertEqual(names["gw"], "gw")
    }

    // MARK: - 进 UsageStore 之后

    /// OMP 叠加行进 omp 分组；中断 / 报错的请求计入请求数、不计入成功；状态码筛选能筛出来。
    func testStoreGroupsOmpRowsAndCountsFailures() throws {
        try write([
            assistant("ok-1", ts: "2026-10-29T13:17:42.984Z"),
            assistant("ok-2", ts: "2026-10-29T13:18:42.984Z"),
            assistant("err-1", output: 0, cost: 0, stop: "error", error: "upstream 529",
                      ts: "2026-10-29T13:19:42.984Z"),
        ])
        let store = UsageStore(path: dbPath, overlay: try Fixture.emptyOverlay(), ompOverlay: overlay)
        let all = try store.rangeSummary(UsageFilter(), calendar: Fixture.cal)
        XCTAssertEqual(all.requests, 3)
        XCTAssertEqual(all.successes, 2)
        let omp = try store.rangeSummary(UsageFilter(appType: "omp"), calendar: Fixture.cal)
        XCTAssertEqual(omp.requests, 3)
        let claude = try store.rangeSummary(UsageFilter(appType: "claude"), calendar: Fixture.cal)
        XCTAssertEqual(claude.requests, 0, "OMP 的 Claude 请求不再记到 Claude 分组")
        let failed = try store.requestLogs(LogQueryFilter(statusCode: 500), page: 0, pageSize: 20)
        XCTAssertEqual(failed.rows.map(\.errorMessage), ["upstream 529"])
        let stats = try store.providerStats(LogQueryFilter())
        XCTAssertEqual(stats.first?.successRate ?? 0, 200.0 / 3, accuracy: 1e-9)
    }
}
