import XCTest
import SQLite3

// Claude 1 小时缓存写入计价（对齐 cc-switch v4.0.7 #7653 / calculator.rs）。
//
// 用例按「杀变异体」设计：每个用例的注释写明它负责杀哪个变异体，
// 加用例前先确认它能杀掉某个现有用例杀不掉的变异体。
final class ClaudeCacheWriteBillingTests: XCTestCase {

    // MARK: - 口径开关：跟着本机 CC Switch 的版本走

    /// 杀变异体：门槛写成 4.0.6 / 4.0.8；按字符串比较版本（"4.0.12" 会排在 "4.0.7" 前面）；
    /// 读不到版本时退回 5 分钟价。
    func testOneHourRateFollowsInstalledCCSwitchVersion() {
        let on: [String?] = [nil, "4.0.7", "4.0.12", "4.1.0", "5.0", "4.0.7-beta.1", "not-a-version"]
        let off = ["4.0.6", "4.0", "3.20.3", "3.20.4"]
        for v in on {
            XCTAssertTrue(ClaudeCacheWriteBilling.usesOneHourRate(ccSwitchVersion: v),
                          "\(v ?? "nil") 应按 1 小时价计")
        }
        for v in off {
            XCTAssertFalse(ClaudeCacheWriteBilling.usesOneHourRate(ccSwitchVersion: v),
                           "\(v) 补录时按 5 分钟价，现场也应按 5 分钟价")
        }
    }

    // MARK: - 成本拆分

    /// 数值取自上游 calculator.rs 的用例：Opus 4.8 缓存写入 $6.25/M，400 个 5 分钟写入 +
    /// 600 个 1 小时写入 = 0.0085。杀变异体：倍数写成 2（0.01）或 1.25（0.007188）；
    /// 开关关掉时仍乘 1.6。
    func testCostBillsOneHourShareAtOnePointSix() {
        XCTAssertEqual(ClaudeCacheWriteBilling.cost(tokens: 1000, oneHourTokens: 600,
                                                    pricePerMillion: 6.25, oneHourRate: true),
                       0.0085, accuracy: 1e-12)
        XCTAssertEqual(ClaudeCacheWriteBilling.cost(tokens: 1000, oneHourTokens: 600,
                                                    pricePerMillion: 6.25, oneHourRate: false),
                       0.00625, accuracy: 1e-12)
    }

    /// 1 小时部分钳在 [0, 总写入量] 之间（同上游 `min`；负数是坏数据，按 0 算）。
    /// 杀变异体：去掉上限（算出 0.004375）；去掉下限（算出 0.00060625）。
    func testOneHourShareIsClampedToTotalWrites() {
        XCTAssertEqual(ClaudeCacheWriteBilling.cost(tokens: 100, oneHourTokens: 1000,
                                                    pricePerMillion: 6.25, oneHourRate: true),
                       0.001, accuracy: 1e-12)
        XCTAssertEqual(ClaudeCacheWriteBilling.cost(tokens: 100, oneHourTokens: -5,
                                                    pricePerMillion: 6.25, oneHourRate: true),
                       0.000625, accuracy: 1e-12)
    }

    // MARK: - 读本机 CC Switch 的版本号

    /// CC Switch 升级是原地替换 .app，必须每次现读 Info.plist。
    /// 杀变异体：改用 Bundle(url:) 读（实例按路径缓存，第二次仍是 3.20.3）；只看第一个路径。
    func testInstalledVersionIsReadFreshFromInfoPlist() throws {
        let root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-ccswitch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let missing = (root as NSString).appendingPathComponent("A/CC Switch.app")
        let present = (root as NSString).appendingPathComponent("B/CC Switch.app")

        try writeInfoPlist(app: present, version: "3.20.3")
        XCTAssertEqual(ClaudeCacheWriteBilling.installedCCSwitchVersion(appPaths: [missing, present]),
                       "3.20.3")
        try writeInfoPlist(app: present, version: "4.0.12")
        XCTAssertEqual(ClaudeCacheWriteBilling.installedCCSwitchVersion(appPaths: [missing, present]),
                       "4.0.12", "原地升级后必须读到新版本")
        XCTAssertNil(ClaudeCacheWriteBilling.installedCCSwitchVersion(appPaths: [missing]))
    }

    private func writeInfoPlist(app: String, version: String) throws {
        let contents = (app as NSString).appendingPathComponent("Contents")
        try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = ["CFBundleShortVersionString": version,
                                   "CFBundleIdentifier": "com.ccswitch.desktop"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try data.write(to: URL(fileURLWithPath: (contents as NSString).appendingPathComponent("Info.plist")))
    }
}

/// SessionOverlay 端到端：1 小时写入按开关计价；开关翻转时已叠加的行重新定价。
final class OneHourCacheOverlayTests: XCTestCase {
    /// 可变的版本探针，模拟 CC Usage 运行期间 CC Switch 被升级。
    private final class VersionProbe { var value: String? }

    private var dbPath = ""
    private var projectsDir = ""
    private var db: OpaquePointer!
    private let probe = VersionProbe()
    private var overlay: SessionOverlay!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("overlay-1h")
        try Fixture.exec(dbPath,
            "INSERT INTO model_pricing VALUES('claude-opus-4-8','5','25','0.5','6.25');")
        projectsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-ovl1h-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (projectsDir as NSString).appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        // pricingTTL 0：每轮真扫都重判口径，测试不必睡过 5 分钟的缓存窗口
        overlay = SessionOverlay(projectsDir: projectsDir, minRefreshInterval: 0, pricingTTL: 0,
                                 ccSwitchVersion: { [probe] in probe.value })
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: projectsDir)
    }

    /// Claude Code 的回复行：缓存写入 1000 = 5 分钟 400 + 1 小时 600（上游用例同款数字）。
    private func line(id: String) -> String {
        #"{"type":"assistant","sessionId":"s1","timestamp":"2026-10-14T10:00:00Z","message":{"id":"\#(id)","stop_reason":"end_turn","model":"claude-opus-4-8","usage":{"input_tokens":2,"output_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":1000,"cache_creation":{"ephemeral_5m_input_tokens":400,"ephemeral_1h_input_tokens":600}}}}"#
    }

    @discardableResult
    private func write(_ lines: [String]) throws -> String {
        let path = ((projectsDir as NSString).appendingPathComponent("proj1") as NSString)
            .appendingPathComponent("sess.jsonl")
        try (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    private func append(_ path: String, _ line: String) throws {
        let fh = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        fh.seekToEndOfFile()
        fh.write(Data((line + "\n").utf8))
        try fh.close()
    }

    /// 杀变异体：overlay 不读 ephemeral_1h_input_tokens（0.00625）；把 5 分钟字段当成 1 小时（0.00775）。
    func testNewCCSwitchBillsOneHourWritesAtOnePointSix() throws {
        probe.value = "4.0.12"
        try write([line(id: "m1")])
        let r = try XCTUnwrap(overlay.pendingRows(db: db).first)
        XCTAssertEqual(r.cacheCreationCost, 0.0085, accuracy: 1e-12)
        // 2 × $5/M + 1 × $25/M + 0.0085
        XCTAssertEqual(r.totalCost, 0.008535, accuracy: 1e-12)
    }

    /// 3.20.x 补录时一律按 5 分钟价，现场也得这么算，否则一打开 CC Switch 数字就往下跳。
    /// 杀变异体：开关恒开。
    func testOldCCSwitchKeepsFiveMinuteRate() throws {
        probe.value = "3.20.3"
        try write([line(id: "m1")])
        let r = try XCTUnwrap(overlay.pendingRows(db: db).first)
        XCTAssertEqual(r.cacheCreationCost, 0.00625, accuracy: 1e-12)
    }

    /// CC Usage 运行期间 CC Switch 被升到 v4.0.7+：已叠加的行是按旧口径算的，必须清空重扫。
    /// 杀变异体：口径只在启动时判一次（m2 仍是 0.00625）；口径变了不清空（m1 停在 0.00625）。
    func testRuleFlipRepricesRowsAlreadyPending() throws {
        probe.value = "3.20.3"
        let file = try write([line(id: "m1")])
        XCTAssertEqual(try XCTUnwrap(overlay.pendingRows(db: db).first).cacheCreationCost,
                       0.00625, accuracy: 1e-12)

        probe.value = "4.0.12"
        try append(file, line(id: "m2"))   // 文件有变化，这一轮才会真扫（见 nothingChangedLocked）
        let rows = overlay.pendingRows(db: db).sorted { $0.requestId < $1.requestId }
        XCTAssertEqual(rows.map(\.requestId), ["session:m1", "session:m2"])
        for r in rows {
            XCTAssertEqual(r.cacheCreationCost, 0.0085, accuracy: 1e-12, r.requestId)
        }
    }
}
