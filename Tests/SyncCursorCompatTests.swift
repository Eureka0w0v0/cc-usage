import XCTest
import SQLite3

// session_log_sync 游标三态兼容（cc-switch v3.20.1 / schema v18）。
//
// 上游把 Claude 路径改成字节游标，并把 `last_line_offset` **固定写 0**
// （session_usage.rs:710，注释原话「字节游标语义下行号不再维护，置 0 明确
// 表示行号游标不可用」）。叠加层若继续按行号跳过，升级当天就会从第 0 行重扫
// 每个活跃会话文件；其中 30 天前的行明细已被 rollup_and_prune 删除、
// request_id 去重对其失明 → 与 usage_daily_rollups 双算。
//
// 三态：A 旧库（无列）/ B 已升级未重扫（NULL）/ C 新版写过（字节位，可能是 0）。
// 每个用例都注明它负责杀哪个变异体。
final class SyncCursorCompatTests: XCTestCase {
    private var dbPath = ""
    private var projectsDir = ""
    private var overlay: SessionOverlay!
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("cursor")
        try Fixture.exec(dbPath,
            "INSERT INTO model_pricing VALUES('claude-sonnet-5','3','15','0.3','3.75');")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-cur-\(UUID().uuidString)")
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
    }

    private func openDB() throws {
        if db != nil { sqlite3_close(db) }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    /// 模拟上游 v17→v18 迁移：两列都是 nullable ADD COLUMN，存量行保持 NULL。
    private func migrateToV18() throws {
        try Fixture.exec(dbPath, """
        ALTER TABLE session_log_sync ADD COLUMN last_byte_offset INTEGER;
        ALTER TABLE session_log_sync ADD COLUMN last_tail_fingerprint INTEGER;
        """)
        try openDB()
    }

    private func assistantLine(id: String, output: Int) -> String {
        #"{"type":"assistant","sessionId":"s1","timestamp":"2026-08-28T10:00:00Z","message":{"id":"\#(id)","stop_reason":"end_turn","model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":\#(output)}}}"#
    }

    /// 写 3 行会话，返回 (路径, 每行结尾处的累计字节数)。
    /// byteAfter[i] = 前 i+1 行（含换行）的总字节数，正是上游游标会停的位置。
    @discardableResult
    private func writeThreeLines() throws -> (path: String, byteAfter: [Int64]) {
        let lines = [
            assistantLine(id: "m1", output: 10),
            assistantLine(id: "m2", output: 20),
            assistantLine(id: "m3", output: 30),
        ]
        let path = ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent("sess.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        var acc: Int64 = 0
        var marks: [Int64] = []
        for l in lines {
            acc += Int64(l.utf8.count) + 1   // +1 = "\n"
            marks.append(acc)
        }
        return (path, marks)
    }

    private func ids(_ rows: [OverlayRow]) -> Set<String> {
        Set(rows.map { $0.requestId })
    }

    // MARK: - A 态：旧库（无 last_byte_offset 列）

    /// 杀变异体「无条件按字节 seek」——老库没有该列，只能走行号路径。
    /// 也是整支改动的回归保护：A 态行为必须与改动前逐字节一致。
    func testLegacyDBUsesLineOffset() throws {
        let f = try writeThreeLines()
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync VALUES('\(f.path)', 0, 2);")   // 已消化前 2 行
        XCTAssertEqual(ids(overlay.pendingRows(db: db)), ["session:m3"])
    }

    // MARK: - B 态：已升级但该文件还没被新版扫过（列存在，值为 NULL）

    /// 🔴 杀变异体「COALESCE(last_byte_offset, 0)」。
    /// NULL 被当成字节位 0 的话，会从头重扫整个文件 → 产出 3 条而非 1 条，
    /// 这正是升级当天双算的形态。
    func testNullByteOffsetFallsBackToLineOffset() throws {
        let f = try writeThreeLines()
        try migrateToV18()
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset) VALUES('\(f.path)', 0, 2, NULL);")
        XCTAssertEqual(ids(overlay.pendingRows(db: db)), ["session:m3"],
                       "NULL 字节游标必须回落行号路径，不能当成 0")
    }

    // MARK: - C 态：新版写过（字节位真实，行号恒 0）

    /// 杀变异体「继续读 last_line_offset」——C 态行号恒 0，照读会从头重扫。
    func testByteOffsetWinsOverZeroedLineOffset() throws {
        let f = try writeThreeLines()
        try migrateToV18()
        // 上游形态：字节位停在第 2 行末，行号被写死 0
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset) VALUES('\(f.path)', 0, 0, \(f.byteAfter[1]));")
        XCTAssertEqual(ids(overlay.pendingRows(db: db)), ["session:m3"],
                       "应从字节游标续读，行号 0 不得让它从头重扫")
    }

    /// 🔴 杀变异体「byteOffset == 0 时回落行号路径」（COALESCE 的另一半）。
    /// 0 是 C 态合法的字节位（cc-switch 扫过但一行未消化），此时必须整文件解析；
    /// 若回落到行号路径，这里的 line_offset=2 会让它少产出 2 条。
    func testZeroByteOffsetIsLegalNotMissing() throws {
        let f = try writeThreeLines()
        try migrateToV18()
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset) VALUES('\(f.path)', 0, 2, 0);")
        XCTAssertEqual(ids(overlay.pendingRows(db: db)),
                       ["session:m1", "session:m2", "session:m3"],
                       "字节位 0 是合法起点，不得被当成缺失而回落行号")
    }

    // MARK: - 越界（外部截断 / 重写）

    /// 🔴 杀变异体「越界就从 0 重扫」。上游对截断/重写的处理是「游标钉至 EOF、
    /// 不重放旧区间」，因为重放已被 rollup 剪掉的区间会永久放大统计。
    func testOutOfRangeByteOffsetPinsToEOFInsteadOfReplaying() throws {
        let f = try writeThreeLines()
        try migrateToV18()
        let beyond = f.byteAfter[2] + 4096      // 文件被外部截短，游标越过了 EOF
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset) VALUES('\(f.path)', 0, 0, \(beyond));")
        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty,
                      "越界游标必须钳到 EOF 零产出，绝不能回退到 0 重放整个文件")
    }

    // MARK: - 游标形态切换（用户升级 cc-switch 的那一刻）

    /// 杀变异体「切换游标形态后仍复用进程内旧进度」。
    /// A 态扫过一轮后 cc-switch 升级并消化全文，第二轮必须收敛为空，
    /// 而不是把已消化区间再产出一遍。
    func testCursorFormatSwitchDoesNotReplay() throws {
        let f = try writeThreeLines()
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync VALUES('\(f.path)', 0, 1);")   // A 态：已消化第 1 行
        XCTAssertEqual(ids(overlay.pendingRows(db: db)), ["session:m2", "session:m3"])

        // cc-switch 升级 → 迁移加列 → 扫完整个文件，写字节游标并把行号清 0
        try migrateToV18()
        try Fixture.exec(dbPath,
            "UPDATE session_log_sync SET last_line_offset = 0, last_byte_offset = \(f.byteAfter[2]) WHERE file_path = '\(f.path)';")
        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty,
                      "cc-switch 已消化全文，叠加层必须收敛为空")
    }

    /// 杀变异体「samePosition 只比 lineOffset」。C 态下行号恒 0、只有字节位在动，
    /// 只比行号会把「cc-switch 又消化了两行」误判成「游标没动」，于是继续沿用
    /// 进程内旧进度，已被消化的行赖在叠加层里不走。
    func testByteCursorAdvanceDetectedWhileLineOffsetStaysZero() throws {
        let f = try writeThreeLines()
        try migrateToV18()
        try Fixture.exec(dbPath,
            "INSERT INTO session_log_sync (file_path, last_modified, last_line_offset, last_byte_offset) VALUES('\(f.path)', 0, 0, \(f.byteAfter[0]));")
        XCTAssertEqual(ids(overlay.pendingRows(db: db)), ["session:m2", "session:m3"])

        // cc-switch 再扫一轮，字节游标推进到文件末；行号自始至终是 0
        try Fixture.exec(dbPath,
            "UPDATE session_log_sync SET last_byte_offset = \(f.byteAfter[2]) WHERE file_path = '\(f.path)';")
        XCTAssertTrue(overlay.pendingRows(db: db).isEmpty,
                      "字节游标推进必须被识别为「cc-switch 有进展」")
    }
}
