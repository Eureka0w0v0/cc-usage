import XCTest

/// ClaudePlan：套餐显示名。
/// - 优先用服务器下发的显示名：Claude Code 2.1.316 起从 `/api/oauth/profile` 取 `organization.plan_display_name`，
///   校验后存进 `~/.claude.json` 的 `oauthAccount.planDisplayName`，显示时先用它。
/// - 拿不到或不合法时按凭据里的 subscriptionType / rateLimitTier 推断；2026-10-30 官方改名后
///   Max 20x 叫 Ultra、Max 5x 叫 Max（凭据里的标识没变，仍是 `default_claude_max_20x` / `_5x`）。
final class ClaudePlanTests: XCTestCase {
    /// 没有服务器显示名时的回落文案。负责杀的变异体：20x / 5x 仍写旧名或对调、
    /// Team 高级席位认错档、认不出的类型不首字母大写、类型不去空白 / 不忽略大小写。
    func testFallbackLabelsUseRenamedPlans() {
        let cases: [(String?, String?, String?)] = [
            ("pro", nil, "Pro"),
            ("max", "default_claude_max_20x", "Ultra"),
            ("max", "default_claude_max_5x", "Max"),
            ("max", nil, "Max"),
            ("max", "something_else", "Max"),
            ("team", "default_claude_max_5x", "Team Premium"),
            ("team", "default_claude_max_20x", "Team"),
            ("team", nil, "Team"),
            ("enterprise", nil, "Enterprise"),
            ("free", nil, "Free"),
            (" MAX ", " default_claude_max_20x ", "Ultra"),
            ("Pro", nil, "Pro"),
        ]
        for (type, tier, expected) in cases {
            XCTAssertEqual(ClaudePlan.label(displayName: nil, subscriptionType: type, rateLimitTier: tier), expected,
                           "\(type ?? "nil") / \(tier ?? "nil")")
        }
    }

    /// 服务器给了合法的显示名就照它写（官方以后再改名也能跟上）。
    /// 负责杀的变异体：显示名被忽略、仍走写死映射。
    func testServerDisplayNameWins() {
        XCTAssertEqual(ClaudePlan.label(displayName: "Ultra", subscriptionType: "max",
                                        rateLimitTier: "default_claude_max_5x"), "Ultra")
        XCTAssertEqual(ClaudePlan.label(displayName: "Max 20x", subscriptionType: "max",
                                        rateLimitTier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(ClaudePlan.label(displayName: "Team+", subscriptionType: "team", rateLimitTier: nil), "Team+")
        XCTAssertEqual(ClaudePlan.label(displayName: "旗舰版", subscriptionType: "pro", rateLimitTier: nil), "旗舰版")
    }

    /// 显示名不合法时丢掉、回落到推断（用 pro 回落成 "Pro"，和这些显示名都不同，才看得出走了哪条路）。
    /// 负责杀的变异体：不校验、校验时先去空白、用 `$`（ICU 下会放过结尾换行）代替 `\z`。
    func testInvalidDisplayNameFallsBack() {
        let invalid = [
            "", " Ultra", "Ultra ", "Ultra\n", "<b>Ultra</b>", "-Ultra", "+Ultra", ".Ultra",
            "Ultra-", "Ultra.", "Ul\u{200B}tra", "Ultra_Plan", String(repeating: "U", count: 41),
        ]
        for name in invalid {
            XCTAssertEqual(ClaudePlan.label(displayName: name, subscriptionType: "pro", rateLimitTier: nil), "Pro",
                           "\(name.debugDescription) 应被拒")
        }
    }

    /// 校验规则与 Claude Code 2.1.316 的 `^[\p{L}\p{N}](?:[\p{L}\p{N} .+-]{0,38}[\p{L}\p{N}+])?$` 一致：
    /// 1–40 个字符，字母或数字开头，字母、数字或 + 结尾，中间允许空格、点、加号、连字符。
    /// 负责杀的变异体：长度上限差一、首尾字符集写宽或写窄。
    func testDisplayNameValidationBoundaries() {
        let valid = ["U", "U2", "A.B", "A B", "A-B", "A+", "Max 5x", "Pro 2.0", String(repeating: "U", count: 40)]
        for name in valid {
            XCTAssertTrue(ClaudePlan.isValidDisplayName(name), name)
        }
        let invalid = ["", "+", "A.", "A-", "A ", " A", String(repeating: "U", count: 41)]
        for name in invalid {
            XCTAssertFalse(ClaudePlan.isValidDisplayName(name), name.debugDescription)
        }
    }

    /// 读不到套餐类型（API key 登录、旧凭据）时不显示，哪怕配置文件里留着显示名——
    /// Claude Code 同样只在有 subscriptionType 时才用它。负责杀的变异体：先看显示名再看类型。
    func testNoSubscriptionTypeMeansNoLabel() {
        XCTAssertNil(ClaudePlan.label(displayName: "Ultra", subscriptionType: nil, rateLimitTier: "default_claude_max_20x"))
        XCTAssertNil(ClaudePlan.label(displayName: "Ultra", subscriptionType: "   ", rateLimitTier: nil))
        XCTAssertNil(ClaudePlan.label(displayName: nil, subscriptionType: "", rateLimitTier: nil))
    }

    /// 从 Claude Code 的全局配置里取 `oauthAccount.planDisplayName`：只认字符串，其余（缺键、null、数字、
    /// 坏 JSON、顶层不是对象）一律 nil。负责杀的变异体：键名写错、把非字符串强转成文字。
    func testDisplayNameFromClaudeConfig() {
        func parse(_ json: String) -> String? { ClaudePlan.displayName(fromClaudeConfig: Data(json.utf8)) }
        XCTAssertEqual(parse(#"{"oauthAccount":{"planDisplayName":"Ultra","emailAddress":"x"}}"#), "Ultra")
        XCTAssertNil(parse(#"{"oauthAccount":{"emailAddress":"x"}}"#))
        XCTAssertNil(parse(#"{"oauthAccount":{"planDisplayName":null}}"#))
        XCTAssertNil(parse(#"{"oauthAccount":{"planDisplayName":5}}"#))
        XCTAssertNil(parse(#"{"planDisplayName":"Ultra"}"#))
        XCTAssertNil(parse(#"[{"oauthAccount":{"planDisplayName":"Ultra"}}]"#))
        XCTAssertNil(parse("{not json"))
    }
}
