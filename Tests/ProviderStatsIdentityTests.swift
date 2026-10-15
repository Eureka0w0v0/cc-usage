import XCTest

// Provider Stats 的行身份是 (provider_id, app_type)（对齐上游 v4.0.7 #8032）。
//
// 「Claude」筛选把 Claude Code 和 Claude Desktop 折叠在一起，同一个供应商两边都配过时，
// 会回来两行 id、名字都一样的记录。行里必须带 appType，embed 的表格才拿得到唯一的 key，
// 否则 React 遇到重复 key，切换应用后会留下旧的行。
final class ProviderStatsIdentityTests: XCTestCase {
    private var dbPath = ""
    private var sessionsDir = ""
    private let t = Fixture.ts(2026, 10, 10, 12)

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("provider-identity")
        sessionsDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-identity-omp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            atPath: (sessionsDir as NSString).appendingPathComponent("-Proj"),
            withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
        try? FileManager.default.removeItem(atPath: sessionsDir)
        Fixture.cleanTempDirs()
    }

    /// 杀变异体：appType 读错列或没有回填（两行不再分别是 claude 与 claude-desktop）。
    func testFoldedClaudeRowsCarryTheirOwnAppType() throws {
        try Fixture.exec(dbPath, """
        INSERT INTO providers(id, name, app_type) VALUES('shared-p1','Shared Provider','claude');
        INSERT INTO providers(id, name, app_type) VALUES('shared-p1','Shared Provider','claude-desktop');
        """)
        try Fixture.insertLog(dbPath, id: "code", app: "claude", input: 100, output: 10, cost: 2,
                              createdAt: t, dataSource: "proxy", providerId: "shared-p1")
        try Fixture.insertLog(dbPath, id: "desktop", app: "claude-desktop", input: 200, output: 20,
                              cost: 1, createdAt: t, dataSource: "proxy", providerId: "shared-p1")

        let rows = try Fixture.store(dbPath)
            .providerStats(LogQueryFilter(start: t - 60, end: t + 60, appType: "claude"))
        XCTAssertEqual(rows.map(\.providerId), ["shared-p1", "shared-p1"])
        XCTAssertEqual(rows.map(\.providerName), ["Shared Provider", "Shared Provider"])
        XCTAssertEqual(rows.map(\.appType), ["claude", "claude-desktop"], "按成本降序，Claude Code 在前")
    }

    /// overlay 行和库内行同一套身份：按 (provider, app) 分组，只并进同一 (provider, app) 的行。
    /// 杀变异体：overlay 仍只按 providerId 分组（同一个 OMP provider 打两家模型时被并成一行）。
    func testOverlayRowsSplitByAppLikeDatabaseRows() throws {
        let lines = [
            ompLine(rid: "r-claude", model: "claude-opus-5", cost: 0.5),
            ompLine(rid: "r-grok", model: "grok-4.5", cost: 0.25),
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            toFile: ((sessionsDir as NSString).appendingPathComponent("-Proj") as NSString)
                .appendingPathComponent("sess.jsonl"),
            atomically: true, encoding: .utf8)
        let store = UsageStore(path: dbPath, overlay: try Fixture.emptyOverlay(),
                               ompOverlay: OmpOverlay(sessionsDir: sessionsDir, minRefreshInterval: 0))

        let rows = try store.providerStats(LogQueryFilter())
        XCTAssertEqual(rows.map { "\($0.appType)/\($0.providerId)" },
                       ["claude/_omp_gw", "grokbuild/_omp_gw"])
        XCTAssertEqual(rows.map(\.requestCount), [1, 1])
    }

    /// OMP 的 assistant 消息行（同一个 provider「gw」，模型家族由调用方给）。
    private func ompLine(rid: String, model: String, cost: Double) -> String {
        #"""
        {"type":"message","id":"e1","timestamp":"2026-10-10T03:00:00.000Z","message":{"role":"assistant","provider":"gw","model":"\#(model)","responseId":"\#(rid)","timestamp":\#(t * 1000),"usage":{"input":10,"output":100,"cacheRead":0,"cacheWrite":0,"totalTokens":110,"cost":{"input":0.1,"output":0.1,"cacheRead":0,"cacheWrite":0,"total":\#(cost)}}}}
        """#
    }
}
