import XCTest

/// ClaudePlan.label：照搬上游 `src/lib/claudePlan.ts` 的 claudePlanLabel（英文默认文案）。
/// subscriptionType 去空白、不分大小写；rateLimitTier 区分 Max 5x / 20x 与 Team 高级席位。
final class ClaudePlanTests: XCTestCase {
    /// 负责杀的变异体：任一分支的文案或判定条件写错（5x / 20x 对调、Team 高级席位认错档、默认不首字母大写）。
    func testLabelsFollowUpstreamClaudePlanLabel() {
        let cases: [(String?, String?, String?)] = [
            ("pro", nil, "Pro"),
            ("max", "default_claude_max_20x", "Max 20x"),
            ("max", "default_claude_max_5x", "Max 5x"),
            ("max", nil, "Max"),
            ("max", "something_else", "Max"),
            ("team", "default_claude_max_5x", "Team Premium"),
            ("team", "default_claude_max_20x", "Team"),
            ("team", nil, "Team"),
            ("enterprise", nil, "Enterprise"),
            ("free", nil, "Free"),
            (" MAX ", " default_claude_max_20x ", "Max 20x"),
            ("Pro", nil, "Pro"),
        ]
        for (type, tier, expected) in cases {
            XCTAssertEqual(ClaudePlan.label(subscriptionType: type, rateLimitTier: tier), expected,
                           "\(type ?? "nil") / \(tier ?? "nil")")
        }
    }

    /// 读不到套餐（API key 登录、旧凭据）时不显示。负责杀的变异体：空串 / 纯空白也给出标签。
    func testMissingOrBlankTypeHasNoLabel() {
        XCTAssertNil(ClaudePlan.label(subscriptionType: nil, rateLimitTier: "default_claude_max_20x"))
        XCTAssertNil(ClaudePlan.label(subscriptionType: "", rateLimitTier: nil))
        XCTAssertNil(ClaudePlan.label(subscriptionType: "   ", rateLimitTier: nil))
    }
}
