import XCTest

// 跨源去重（effective_usage_log_filter）：session 系日志若在 ±10min 窗口内存在指纹
// 匹配的成功 proxy 行，则剔除 session 行，防止同一笔请求被双算。
//
// 回归背景（上游 4bfb3fc3 / v3.19.1）：Claude Code 与 Claude Desktop 共用同一套
// message id —— 走 Desktop 网关的请求以 `claude-desktop` 落 proxy 行，而 session
// 导入器以 `claude` 落 session_log 行。旧实现要求 app_type 精确相等，两者匹配不上，
// 于是同一笔请求既算 proxy 又算 session。
//
// **本组用例按「杀变异体」设计**：初版 6 个用例里有 5 个在把生产代码退回
// `left = right` 后仍然全过（等于没测到东西），而「比展示折叠更窄」这条不变量
// 更是完全没覆盖。现在每个用例都对应一个具体变异体，注释里写明它杀的是哪个；
// 加用例前请先确认它能杀掉某个现有用例杀不掉的变异体，否则只是徒增运行时间。
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

    /// 指纹一致的一对行：proxy 侧与 session 侧的 app_type / 时间差可配。
    private func insertPair(proxyApp: String, sessionApp: String = "claude",
                            sessionSource: String = "session_log",
                            offset: Int64 = 60, at t: Int64,
                            sessionInput: Int64 = 100) throws {
        try Fixture.insertLog(dbPath, id: "proxy-row", app: proxyApp,
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t,
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "session-row", app: sessionApp,
                              model: "claude-sonnet-5", input: sessionInput, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: t + offset,
                              dataSource: sessionSource)
    }

    private func requestCount(around t: Int64, span: Int64 = 1200) throws -> Int {
        try store.rangeSummaryLogsOnly(UsageFilter(start: t - span, end: t + span)).requests
    }

    // MARK: - 汇总口径

    /// 杀变异体：`left = right`（即整个 v3.19.1 改动被撤销）、以及 left/right 互换。
    /// 这是本轮改动的核心行为，唯一一个撤销生产代码后必挂的用例。
    func testClaudeSessionDedupedAgainstClaudeDesktopProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", at: t)
        XCTAssertEqual(try requestCount(around: t), 1, "session 行应被 claude-desktop 的 proxy 行去重")
    }

    /// 杀变异体：把匹配改成「两侧都按展示口径折叠」（`fold(l)=fold(proxy)`）。
    ///
    /// 这是 `dedupAppTypeMatch` 注释里「比 foldedAppL 更窄」那句话的唯一证据：
    /// 放宽只朝一个方向——`claude` 的 session 行可以匹配 `claude-desktop` 的 proxy 行，
    /// 反过来不成立。两侧都折叠的话下面这组就会被误去重。
    func testDesktopSessionNotDedupedAgainstClaudeProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude", sessionApp: "claude-desktop", at: t)
        XCTAssertEqual(try requestCount(around: t), 2,
                       "放宽是单向的：claude-desktop 的 session 行不该被 claude 的 proxy 行吞掉")
    }

    /// 杀变异体：整条 app_type 匹配子句被删除（那样任意 app 之间都会互相去重）。
    func testClaudeSessionNotDedupedAgainstUnrelatedAppProxy() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "codex", at: t)
        XCTAssertEqual(try requestCount(around: t), 2, "跨无关 app_type 不应去重")
    }

    /// 杀变异体：±600s 窗口常数被改大或改小。
    /// 只断言「601 不去重」是不够的——那只证明窗口 < 601；必须两侧都钉死。
    func testDedupWindowBoundaryIsExactly600Seconds() throws {
        let inside = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", offset: 600, at: inside)
        XCTAssertEqual(try requestCount(around: inside), 1, "偏移 600s 仍在窗口内，应去重")

        let outside = Fixture.ts(2026, 6, 12, 12)
        try Fixture.insertLog(dbPath, id: "proxy-far", app: "claude-desktop",
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: outside,
                              dataSource: "proxy", providerId: "p1")
        try Fixture.insertLog(dbPath, id: "session-far", app: "claude",
                              model: "claude-sonnet-5", input: 100, output: 20,
                              cacheRead: 10, cacheCreation: 5, createdAt: outside + 601,
                              dataSource: "session_log")
        XCTAssertEqual(try requestCount(around: outside), 2, "偏移 601s 已出窗口，不应去重")
    }

    /// 杀变异体：token 指纹比对被削弱（少比一个维度就会误去重）。
    func testDedupRequiresMatchingTokenFingerprint() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", at: t, sessionInput: 101)
        XCTAssertEqual(try requestCount(around: t), 2, "input 差 1 个 token 就不该当成同一笔")
    }

    // MARK: - Tabs 口径（早前三处漏套过滤，Hero 去重而 Tab 不去重 → 同屏自相矛盾）

    /// 杀变异体：`statsWhere` 不套 effectiveUsageFilterL。
    func testProviderStatsDedupsAcrossSources() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", at: t)
        let rows = try store.providerStats(LogQueryFilter(start: t - 1200, end: t + 1200))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.requestCount }, 1,
                       "Provider Stats 必须与 Hero 同口径，否则同一笔钱被拆给两个 provider")
        XCTAssertEqual(rows.count, 1)
    }

    /// 杀变异体：同上（modelStats 与 providerStats 共用 statsWhere，但分别断言更好定位）。
    func testModelStatsDedupsAcrossSources() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", at: t)
        let rows = try store.modelStats(LogQueryFilter(start: t - 1200, end: t + 1200))
        XCTAssertEqual(rows.reduce(0) { $0 + $1.requestCount }, 1)
    }

    /// 杀变异体：`requestLogs` 不套 effectiveUsageFilterL（重复行会直接列在面板上，
    /// 且 total 翻倍导致分页错位）。
    func testRequestLogsDedupsAcrossSources() throws {
        let t = Fixture.ts(2026, 6, 10, 12)
        try insertPair(proxyApp: "claude-desktop", at: t)
        let page = try store.requestLogs(LogQueryFilter(start: t - 1200, end: t + 1200),
                                         page: 0, pageSize: 20)
        XCTAssertEqual(page.total, 1)
        XCTAssertEqual(page.rows.map(\.requestId), ["proxy-row"], "保留 proxy 行，剔除 session 行")
    }
}
