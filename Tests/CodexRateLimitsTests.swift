import XCTest

// Codex 限额快照选桶（CodexRateLimits.select）。
//
// 回归背景（上游 #5854 的发现）：一个会话里 token_count 事件会交替带不同的 rate_limits.limit_id——
// `codex` 是主额度，刷新额度时还会用 `codex_bengalfox`、`codex_spark` 等模型专属桶把同一份
// token 信息再报一遍。旧实现只取「最后一条 rate_limits」，菜单栏可能把模型专属桶的百分比当成
// Codex 主额度显示。
//
// 每个用例注释写明它负责杀的变异体。
final class CodexRateLimitsTests: XCTestCase {
    /// 一条 token_count 行；limitId 为 nil 时不写该字段（旧版 Codex 的形态）。
    private func line(_ limitId: String?, _ primary: Double, _ secondary: Double,
                      topLevel: Bool = false) -> String {
        let lid = limitId.map { #""limit_id":"\#($0)","# } ?? ""
        let rl = #"{\#(lid)"primary":{"used_percent":\#(primary),"window_minutes":300,"resets_at":1900000000},"secondary":{"used_percent":\#(secondary),"window_minutes":10080,"resets_at":1900000000}}"#
        if topLevel { return #"{"rate_limits":\#(rl)}"# }
        return #"{"timestamp":"2026-10-10T00:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":\#(rl)}}"#
    }

    private func tail(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

    private func summary(_ ws: [CodexRateLimits.RawWindow]) -> [String] {
        ws.map { "\($0.label)=\($0.usedPercent)" }
    }

    /// 杀变异体：退回「只取最后一条」（选桶规则整个撤销）。
    func testPrefersPrimaryBucketOverNewerSecondaryBucket() {
        let t = tail(line("codex", 10, 20), line("codex_spark", 90, 50))
        XCTAssertEqual(summary(CodexRateLimits.select(tails: [t])), ["5H=10.0", "7D=20.0"])
    }

    /// 杀变异体：只在单个文件内找主桶，跨文件时仍先返回最新文件的模型专属桶。
    func testOlderFilePrimaryBeatsNewerFileWithOnlySecondaryBuckets() {
        let newest = tail(line("codex_bengalfox", 70, 40))
        let older = tail(line("codex", 15, 25))
        XCTAssertEqual(summary(CodexRateLimits.select(tails: [newest, older])), ["5H=15.0", "7D=25.0"])
    }

    /// 杀变异体：主桶判定只认 "codex"，把旧版没有 limit_id 字段的行当成非主桶。
    func testLegacyLinesWithoutLimitIdCountAsPrimary() {
        let t = tail(line(nil, 5, 6), line("codex_spark", 90, 50))
        XCTAssertEqual(summary(CodexRateLimits.select(tails: [t])), ["5H=5.0", "7D=6.0"])
    }

    /// 杀变异体：找不到主桶时返回空（菜单栏变 "—"，比改前更差）/ 回落取的不是最新那条。
    func testFallsBackToNewestSnapshotWhenNoPrimaryAnywhere() {
        let newest = tail(line("codex_bengalfox", 33, 44), line("codex_spark", 90, 50))
        let older = tail(line("codex_bengalfox", 1, 2))
        XCTAssertEqual(summary(CodexRateLimits.select(tails: [newest, older])), ["5H=90.0", "7D=50.0"])
        XCTAssertEqual(CodexRateLimits.select(tails: [String]()), [])
    }

    /// 杀变异体：select 先把所有文件都读一遍（tails 是惰性序列，主桶命中后不该再读后面的文件）。
    func testStopsReadingFilesOnceThePrimaryBucketIsFound() {
        var touched: [Int] = []
        let files = [tail(line("codex", 10, 20)), tail(line("codex", 99, 99))]
        let tails = files.indices.lazy.map { i -> String in touched.append(i); return files[i] }
        XCTAssertEqual(summary(CodexRateLimits.select(tails: tails)), ["5H=10.0", "7D=20.0"])
        XCTAssertEqual(touched, [0])
    }

    /// 搬迁前后的解析口径：尾读切断的首行跳过、rate_limits 直挂顶层也认、窗口标签按时长换算。
    func testParseToleratesTruncatedFirstLineAndTopLevelRateLimits() {
        let t = "ed\":{\"used_percent\":77}}}\n" + tail(line("codex", 12, 34, topLevel: true))
        XCTAssertEqual(summary(CodexRateLimits.select(tails: [t])), ["5H=12.0", "7D=34.0"])
        XCTAssertEqual(CodexRateLimits.label(minutes: 300), "5H")
        XCTAssertEqual(CodexRateLimits.label(minutes: 10080), "7D")
        XCTAssertEqual(CodexRateLimits.label(minutes: 43200), "30D")
        XCTAssertEqual(CodexRateLimits.label(minutes: 1440), "1D")
        XCTAssertEqual(CodexRateLimits.label(minutes: 90), "2H")
        XCTAssertEqual(CodexRateLimits.label(minutes: -1), "?")
    }
}
