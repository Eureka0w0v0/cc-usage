import XCTest

// 定价匹配候选生成 / 前缀匹配门槛 / RFC3339 解析——SessionOverlay 里
// 「口径对齐 cc-switch」最密集的纯函数，上游 rebuild 时的第一道回归防线。
final class PricingCandidatesTests: XCTestCase {

    func testDateSuffixStripped() {
        // ISO 日期尾 / 8 位 / 6 位（校验月日）三种形态
        XCTAssertTrue(SessionOverlay.pricingCandidates("claude-sonnet-5-2026-01-01").contains("claude-sonnet-5"))
        XCTAssertTrue(SessionOverlay.pricingCandidates("claude-sonnet-5-20260101").contains("claude-sonnet-5"))
        XCTAssertTrue(SessionOverlay.pricingCandidates("claude-haiku-4-5-251001").contains("claude-haiku-4-5"))
        // 6 位但月日非法 → 不当日期剥
        XCTAssertFalse(SessionOverlay.pricingCandidates("model-991399").contains("model"))
    }

    func testNamespaceAndBedrockForms() {
        // 厂商前缀 + 版本尾 + 冒号清洗（bedrock 风格 id）
        let c = SessionOverlay.pricingCandidates("anthropic.claude-3-5-sonnet-20241022-v2:0")
        XCTAssertTrue(c.contains("claude-3-5-sonnet"))
        // 路径形式取最后一段
        XCTAssertTrue(SessionOverlay.pricingCandidates("openrouter/anthropic/claude-sonnet-5").contains("claude-sonnet-5"))
        // 内嵌 claude- 起点
        XCTAssertTrue(SessionOverlay.pricingCandidates("bedrock.claude-sonnet-5").contains("claude-sonnet-5"))
    }

    func testContextMarkerAndDotDash() {
        // [1m] 上下文标记剥离
        XCTAssertTrue(SessionOverlay.pricingCandidates("claude-sonnet-4-5[1m]").contains("claude-sonnet-4-5"))
        // claude id 的 dot→dash
        XCTAssertTrue(SessionOverlay.pricingCandidates("Claude-Opus-4.1").contains("claude-opus-4-1"))
    }

    func testReasoningSuffixStripped() {
        XCTAssertTrue(SessionOverlay.pricingCandidates("gpt-5-mini-high").contains("gpt-5-mini"))
        XCTAssertTrue(SessionOverlay.pricingCandidates("o3-mini-low").contains("o3-mini"))
    }

    func testUnknownIsEmpty() {
        XCTAssertTrue(SessionOverlay.pricingCandidates("unknown").isEmpty)
        XCTAssertTrue(SessionOverlay.pricingCandidates("").isEmpty)
        XCTAssertTrue(SessionOverlay.pricingCandidates("null").isEmpty)
    }

    func testShouldTryPrefixMatch() {
        // claude 需 ≥3 段横杠
        XCTAssertFalse(SessionOverlay.shouldTryPrefixMatch("claude-sonnet-5"))
        XCTAssertTrue(SessionOverlay.shouldTryPrefixMatch("claude-sonnet-4-5"))
        // o 系 ≥1 段
        XCTAssertTrue(SessionOverlay.shouldTryPrefixMatch("o3-mini"))
        // 常见家族 ≥2 段
        XCTAssertTrue(SessionOverlay.shouldTryPrefixMatch("gemini-2.5-pro"))
        XCTAssertFalse(SessionOverlay.shouldTryPrefixMatch("gpt-5"))
        // 未知家族一律不前缀匹配
        XCTAssertFalse(SessionOverlay.shouldTryPrefixMatch("foo-bar-baz-qux"))
    }

    func testParseRFC3339() {
        let plain = SessionOverlay.parseRFC3339("2026-07-08T10:00:00Z")
        XCTAssertNotNil(plain)
        // 小数秒截断到同一秒
        XCTAssertEqual(SessionOverlay.parseRFC3339("2026-07-08T10:00:00.123456Z"), plain)
        // 带时区偏移
        let offset = SessionOverlay.parseRFC3339("2026-07-08T19:00:00+09:00")
        XCTAssertEqual(offset, plain)
        XCTAssertNil(SessionOverlay.parseRFC3339("not-a-date"))
    }
}
