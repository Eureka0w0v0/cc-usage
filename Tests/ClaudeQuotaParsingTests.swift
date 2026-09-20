import XCTest

/// `ClaudeQuotaParser` 的规则打靶。
///
/// 每个用例注释里写明它负责杀哪个变异体（把生产代码按该说法改坏时必须有用例报红），
/// 避免写出「撤销生产改动照样全过」的空用例。
final class ClaudeQuotaParsingTests: XCTestCase {

    // MARK: - 夹具

    /// 旧格式顶层窗口
    private func window(_ utilization: Any, resetsAt: Any = NSNull()) -> [String: Any] {
        ["utilization": utilization, "resets_at": resetsAt]
    }

    /// `limits[]` 里的模型专属周限额
    private func scoped(
        model: Any?,
        percent: Any,
        kind: Any = "weekly_scoped",
        group: Any = "weekly",
        surface: Any = NSNull(),
        resetsAt: Any = NSNull()
    ) -> [String: Any] {
        var scope: [String: Any] = ["surface": surface]
        if let model { scope["model"] = ["display_name": model] }
        return [
            "kind": kind, "group": group, "percent": percent,
            "scope": scope, "resets_at": resetsAt,
        ]
    }

    private func names(_ tiers: [QuotaTier]) -> [String] { tiers.map(\.name) }

    private func tier(_ tiers: [QuotaTier], _ name: String) -> QuotaTier? {
        tiers.first { $0.name == name }
    }

    // MARK: - 旧格式顶层窗口

    /// 杀：legacyTier 读错 key / 不读 resets_at。
    func testLegacyWindowsParsed() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(12.5, resetsAt: "2026-09-21T10:00:00Z"),
            "seven_day": window(80),
        ])
        XCTAssertEqual(names(tiers), ["five_hour", "seven_day"])
        XCTAssertEqual(tier(tiers, "five_hour")?.utilization, 12.5)
        XCTAssertNotNil(tier(tiers, "five_hour")?.resetsAt)
        XCTAssertNil(tier(tiers, "seven_day")?.resetsAt, "resets_at 为 null 时窗口仍有效")
    }

    /// 杀：把「utilization 缺失/null 就跳过」改成默认 0。
    func testWindowWithoutUtilizationIsSkipped() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": ["resets_at": "2026-09-21T10:00:00Z"],
            "seven_day": window(NSNull()),
            "seven_day_opus": window(3),
        ])
        XCTAssertEqual(names(tiers), ["seven_day_opus"])
    }

    /// 杀：删掉「未知顶层窗口」那一段（API 新加窗口类型会整个消失）。
    func testUnknownWindowIsKeptWithItsOwnName() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(1),
            "thirty_day": window(42),
        ])
        XCTAssertEqual(names(tiers), ["five_hour", "thirty_day"])
        XCTAssertEqual(tier(tiers, "thirty_day")?.utilization, 42)
    }

    /// 杀：从 nonTierKeys 里漏掉 extra_usage / spend（它们会被当成窗口混进码片）。
    func testNonWindowKeysAreNotTreatedAsTiers() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(1),
            "extra_usage": ["utilization": 55, "is_enabled": true],
            "spend": ["utilization": 9],
            "member_dashboard_available": true,
        ])
        XCTAssertEqual(names(tiers), ["five_hour"])
    }

    // MARK: - 新格式 limits[]（本轮新增能力）

    /// 杀：整个 applyScopedLimits 不实现 / 把 limits 当成非窗口键直接忽略。
    /// 这正是本轮修的 bug——Fable 周限额此前一条都读不到。
    func testScopedWeeklyLimitBecomesTier() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(10),
            "limits": [scoped(model: "Fable", percent: 63.5, resetsAt: "2026-09-25T00:00:00Z")],
        ])
        XCTAssertEqual(names(tiers), ["five_hour", "seven_day_fable"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 63.5)
        XCTAssertNotNil(tier(tiers, "seven_day_fable")?.resetsAt)
    }

    /// 杀：把 percent 读成 utilization（新格式里没有 utilization 这个 key）。
    func testScopedReadsPercentNotUtilization() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [["kind": "weekly_scoped", "group": "weekly",
                        "utilization": 77,
                        "scope": ["model": ["display_name": "Opus"]]]]
        ])
        XCTAssertTrue(tiers.isEmpty, "只有 utilization 没有 percent 的条目不成立")
    }

    /// 杀：把「覆盖同名窗口」写成 append（面板会出现两个 seven_day_opus）。
    func testScopedOverridesLegacyWindowOfSameName() {
        let tiers = ClaudeQuotaParser.parse([
            "seven_day_opus": window(11),
            "limits": [scoped(model: "opus", percent: 88)],
        ])
        XCTAssertEqual(names(tiers), ["seven_day_opus"])
        XCTAssertEqual(tier(tiers, "seven_day_opus")?.utilization, 88, "新格式优先")
    }

    /// 杀：删掉 kind 判定（其它 kind 的限额会被误当周限额）。
    func testScopedIgnoresOtherKinds() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [scoped(model: "Sonnet", percent: 50, kind: "monthly_scoped")]
        ])
        XCTAssertTrue(tiers.isEmpty)
    }

    /// 杀：删掉 group 判定。
    func testScopedIgnoresOtherGroups() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [scoped(model: "Sonnet", percent: 50, group: "five_hour")]
        ])
        XCTAssertTrue(tiers.isEmpty)
    }

    /// 杀：删掉 scope.surface 判定——某个使用场景的子限额会被当成整个模型的周额度，
    /// 把真实剩余量显示成一个偏高的数。
    func testScopedSkipsSurfaceSubLimit() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                scoped(model: "Fable", percent: 95, surface: "code"),
                scoped(model: "Fable", percent: 20),
            ]
        ])
        XCTAssertEqual(names(tiers), ["seven_day_fable"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 20, "带 surface 的子限额不算数")
    }

    /// 杀：删掉 trim / lowercased（真实响应里 display_name 是 "Fable" 这种首字母大写）。
    func testScopedModelNameIsCaseAndSpaceInsensitive() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                scoped(model: "  SONNET  ", percent: 30),
                scoped(model: "OpUs", percent: 40),
            ]
        ])
        XCTAssertEqual(tier(tiers, "seven_day_sonnet")?.utilization, 30)
        XCTAssertEqual(tier(tiers, "seven_day_opus")?.utilization, 40)
    }

    /// 杀：把未知 display_name 兜底成某个 tier，或 display_name 缺失时崩/塞空名。
    func testScopedSkipsUnknownOrMissingModel() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                scoped(model: "Haiku", percent: 10),
                scoped(model: nil, percent: 20),
                scoped(model: 42, percent: 30),
            ]
        ])
        XCTAssertTrue(tiers.isEmpty)
    }

    /// 杀：删掉 seen 去重（后来者会盖掉先到的那条）。
    func testScopedFirstEntryWinsOnDuplicate() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                scoped(model: "Fable", percent: 60),
                scoped(model: "Fable", percent: 99),
            ]
        ])
        XCTAssertEqual(names(tiers), ["seven_day_fable"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 60)
    }

    /// 杀：删掉 isFinite / >= 0 判定（NaN 会让百分比渲染成 "nan%"，负数画出反向进度条）。
    func testScopedSkipsNonFiniteOrNegativePercent() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                scoped(model: "Fable", percent: Double.nan),
                scoped(model: "Opus", percent: -1),
                scoped(model: "Sonnet", percent: Double.infinity),
            ]
        ])
        XCTAssertTrue(tiers.isEmpty)
    }

    /// 杀：按 is_active 过滤，或把 0% 当成「没数据」丢掉。
    func testScopedZeroPercentIsValid() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [scoped(model: "Fable", percent: 0)]
        ])
        XCTAssertEqual(names(tiers), ["seven_day_fable"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 0)
    }

    /// 杀：把 limits 的逐条解析写成「一条畸形就整段放弃」。
    func testMalformedEntryDoesNotDropTheRest() {
        let tiers = ClaudeQuotaParser.parse([
            "limits": [
                "not a dict",
                ["kind": "weekly_scoped"],
                scoped(model: "Fable", percent: 44),
            ]
        ])
        XCTAssertEqual(names(tiers), ["seven_day_fable"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 44)
    }

    /// 杀：limits 不是数组时崩掉或被当成顶层窗口。
    func testLimitsOfWrongShapeIsIgnored() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(5),
            "limits": ["utilization": 70],
        ])
        XCTAssertEqual(names(tiers), ["five_hour"])
    }

    // MARK: - 排序

    /// 杀：删掉末尾排序——顺序会跟着字典哈希走，面板每次刷新码片跳位。
    func testTiersAreSortedByKnownOrderWithUnknownsLast() {
        let tiers = ClaudeQuotaParser.parse([
            "seven_day_sonnet": window(4),
            "thirty_day": window(5),
            "seven_day": window(6),
            "five_hour": window(7),
            "limits": [scoped(model: "Fable", percent: 8)],
        ])
        XCTAssertEqual(
            names(tiers),
            ["five_hour", "seven_day", "seven_day_fable", "seven_day_sonnet", "thirty_day"])
    }

    /// 杀：把 knownTiers 的顺序或内容改掉（它同时是展示序的真理源）。
    func testKnownTiersContract() {
        XCTAssertEqual(
            ClaudeQuotaParser.knownTiers,
            ["five_hour", "seven_day", "seven_day_fable", "seven_day_opus", "seven_day_sonnet"])
    }

    // MARK: - 整体形状

    /// 杀：把空响应解析成非空，或对空字典崩溃。
    func testEmptyResponseYieldsNoTiers() {
        XCTAssertTrue(ClaudeQuotaParser.parse([:]).isEmpty)
    }

    /// 真实响应形状的端到端回归：旧窗口 + 新 limits 混合。
    func testRealisticMixedResponse() {
        let tiers = ClaudeQuotaParser.parse([
            "five_hour": window(23.4, resetsAt: "2026-09-21T05:00:00Z"),
            "seven_day": window(61.0, resetsAt: "2026-09-25T00:00:00Z"),
            "extra_usage": ["is_enabled": false, "utilization": 0],
            "limits": [
                scoped(model: "Fable", percent: 12.0, resetsAt: "2026-09-25T00:00:00Z"),
                scoped(model: "Opus", percent: 47.5, resetsAt: "2026-09-25T00:00:00Z"),
                scoped(model: "Opus", percent: 99, surface: "agent"),
            ],
        ])
        XCTAssertEqual(names(tiers), ["five_hour", "seven_day", "seven_day_fable", "seven_day_opus"])
        XCTAssertEqual(tier(tiers, "seven_day_fable")?.utilization, 12.0)
        XCTAssertEqual(tier(tiers, "seven_day_opus")?.utilization, 47.5)
        XCTAssertTrue(tiers.allSatisfy { $0.planLabel == nil }, "套餐标签由 QuotaService 后贴")
    }
}
