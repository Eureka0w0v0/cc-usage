import XCTest

// 跨源去重（effective_usage_log_filter）：session 系日志若在 ±10min 窗口内存在指纹
// 匹配的成功 proxy 行，则剔除 session 行，防止同一笔请求被双算。
//
// 回归背景（上游 4bfb3fc3 / v3.19.1）：Claude Code 与 Claude Desktop 共用同一套
// message id —— 走 Desktop 网关的请求以 `claude-desktop` 落 proxy 行，而 session
// 导入器以 `claude` 落 session_log 行。旧实现要求 app_type 精确相等，两者匹配不上，
// 于是同一笔请求既算 proxy 又算 session。修复后 claude 一侧放宽到 claude-desktop，
// 其余 app_type 仍保持精确比较（比展示口径折叠 foldedAppL 更窄）。
final class CrossSourceDedupTests: XCTestCase {
    private var dbPath = ""
    private var store: UsageStore!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("xsrcdedup")
        store = try Fixture.store(dbPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    /// 指纹一致的一对行：proxy 侧 app_type 可配，session 侧固定 claude。
    private func insertPair(proxyApp: String, sessionOffset: Int64, at t: Int64) throws {
        try Fixture.insertLog(dbPath, id: "proxy-\(proxyApp)", app: proxyApp,
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t,
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "session-row", app: "claude",
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t + sessionOffset,
                              dataSource: "session_log")
    }

    /// 核心回归：claude 的 session 行必须被 claude-desktop 的 proxy 行去重掉。
    func testClaudeSessionDedupedAgainstClaudeDesktopProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", sessionOffset: 60, at: t)

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(s.requests, 1, "session 行应被 claude-desktop proxy 行去重")
        XCTAssertEqual(s.input, 100, "不应双算 input")
    }

    /// 原有行为不回退：同 app_type（claude ↔ claude）照样去重。
    func testClaudeSessionDedupedAgainstClaudeProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude", sessionOffset: 60, at: t)

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(s.requests, 1)
        XCTAssertEqual(s.input, 100)
    }

    /// 放宽只针对 claude 一侧：codex 的 proxy 行不得吞掉 claude 的 session 行。
    func testClaudeSessionNotDedupedAgainstUnrelatedAppProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "codex", sessionOffset: 60, at: t)

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(s.requests, 2, "跨无关 app_type 不应去重")
        // codex 行走 fresh_input 归一：legacy 语义下 input 含 cache_read，
        // 归一后 100-10=90；claude 侧不归一仍是 100。故合计 190 而非 200。
        XCTAssertEqual(s.input, 190)
    }

    /// 反向不成立：codex 的 session 行不该被 claude-desktop 的 proxy 行吞掉
    /// （CASE 只在 right='claude' 时展开，right='codex' 时退化为精确比较）。
    func testCodexSessionNotDedupedAgainstClaudeDesktopProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "p-desktop", app: "claude-desktop",
                              model: "gpt-5.5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t,
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "s-codex", app: "codex",
                              model: "gpt-5.5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t + 60,
                              dataSource: "codex_session", providerId: "_codex_session")

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(s.requests, 2)
    }

    /// ±10min 窗口边界：超窗不去重（保证放宽 app_type 没顺带放宽时间窗）。
    func testDesktopDedupStillRespectsTenMinuteWindow() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", sessionOffset: 601, at: t)

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 1200, end: t + 1200))
        XCTAssertEqual(s.requests, 2, "超出 ±600s 窗口不应去重")
    }

    /// 指纹任一维度不同即不去重（token 数不匹配）。
    func testDesktopDedupRequiresMatchingTokenFingerprint() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try Fixture.insertLog(dbPath, id: "p-desktop", app: "claude-desktop",
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t,
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "s-claude", app: "claude",
                              model: "claude-sonnet-5", input: 101, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t + 60,
                              dataSource: "session_log")

        let s = try store.rangeSummaryLogsOnly(UsageFilter(start: t - 600, end: t + 600))
        XCTAssertEqual(s.requests, 2)
    }
}
