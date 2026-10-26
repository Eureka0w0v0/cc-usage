import XCTest

// Claude Code 的 OAuth 凭据从钥匙串怎么取（对齐 cc-switch subscription.rs 的
// read_claude_credentials_from_keychain_with，含 #8764 按当前用户账户优先）。
// runner 注入：不碰真钥匙串，只核对「试几次、带什么参数、怎么取舍」。
final class ClaudeCredentialSourceTests: XCTestCase {
    private let withAccount = ["find-generic-password", "-s", "Claude Code-credentials", "-a", "alice", "-w"]
    private let legacy = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

    private func output(_ status: Int32, _ text: String) -> SecurityLookupOutput {
        SecurityLookupOutput(status: status, stdout: Data(text.utf8))
    }

    // 负责杀的变异体：第一次查询不带 -a（回到只按服务名查）。
    func testPrefersTheCurrentAccount() {
        var calls: [[String]] = []
        let cred = ClaudeKeychainLookup.select(user: "alice") { args in
            calls.append(args)
            return self.output(0, #"{"claudeAiOauth":{"accessToken":"current-user-token","subscriptionType":"max"}}"#)
        }
        XCTAssertEqual(calls, [withAccount])
        XCTAssertEqual(cred, ClaudeCredential(accessToken: "current-user-token", subscriptionType: "max"))
    }

    // 账户条目找不到（44）、只存了 mcpOAuth、不是合法 JSON、claudeAiOauth 里没有 token → 都再试一次不带账户的旧查法。
    // 负责杀的变异体：拿到没有 Claude token 的条目就收手 / 44 当成失败放弃钥匙串。
    func testTriesTheLegacyQueryWhenTheAccountEntryHasNoUsableToken() {
        let firstAnswers: [(Int32, String)] = [
            (ClaudeKeychainLookup.itemNotFound, ""),
            (0, #"{"mcpOAuth":{"server":{"accessToken":"mcp-only"}}}"#),
            (0, "invalid JSON"),
            (0, #"{"claudeAiOauth":{}}"#),
        ]
        for (status, text) in firstAnswers {
            var calls: [[String]] = []
            let cred = ClaudeKeychainLookup.select(user: "alice") { args in
                calls.append(args)
                if calls.count == 1 { return self.output(status, text) }
                return self.output(0, #"{"claude.ai_oauth":{"accessToken":"legacy-token"}}"#)
            }
            XCTAssertEqual(calls, [withAccount, legacy], "首个回答：\(status) \(text)")
            XCTAssertEqual(cred?.accessToken, "legacy-token", "首个回答：\(status) \(text)")
        }
    }

    // 其它退出码（如钥匙串锁着、拒绝访问）不再试第二次，直接交给凭据文件。
    // 负责杀的变异体：任何非零退出码都继续试下一个。
    func testOtherFailuresStopTryingTheKeychain() {
        var calls = 0
        let cred = ClaudeKeychainLookup.select(user: "alice") { _ in
            calls += 1
            return self.output(51, "")
        }
        XCTAssertNil(cred)
        XCTAssertEqual(calls, 1)
    }

    // 进程都起不来（runner 返回 nil）同样直接放弃钥匙串。
    func testSpawnFailureStopsTryingTheKeychain() {
        var calls = 0
        let cred = ClaudeKeychainLookup.select(user: "alice") { _ in
            calls += 1
            return nil
        }
        XCTAssertNil(cred)
        XCTAssertEqual(calls, 1)
    }

    // 拿不到用户名（nil 或空串）时只做一次不带账户的查询。
    func testWithoutAUserOnlyTheLegacyQueryRuns() {
        for user in [nil, ""] as [String?] {
            var calls: [[String]] = []
            let cred = ClaudeKeychainLookup.select(user: user) { args in
                calls.append(args)
                return self.output(0, #"{"claudeAiOauth":{"accessToken":"t"}}"#)
            }
            XCTAssertEqual(calls, [legacy])
            XCTAssertEqual(cred?.accessToken, "t")
        }
    }

    // 两次都没有可用凭据 → nil（调用方再去读 ~/.claude/.credentials.json）。
    func testNoUsableEntryReturnsNil() {
        var calls = 0
        let cred = ClaudeKeychainLookup.select(user: "alice") { _ in
            calls += 1
            return self.output(ClaudeKeychainLookup.itemNotFound, "")
        }
        XCTAssertNil(cred)
        XCTAssertEqual(calls, 2)
    }

    // stdout 不是 UTF-8 时跳过这一条、继续试下一个（上游 `String::from_utf8` 失败即 continue）。
    func testNonUTF8OutputMovesOnToTheNextQuery() {
        var calls = 0
        let cred = ClaudeKeychainLookup.select(user: "alice") { _ in
            calls += 1
            if calls == 1 { return SecurityLookupOutput(status: 0, stdout: Data([0xff, 0xfe, 0xfd])) }
            return self.output(0, #"{"claudeAiOauth":{"accessToken":"second"}}"#)
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cred?.accessToken, "second")
    }

    // MARK: - 凭据 JSON 解析（钥匙串与凭据文件共用）

    func testParseAcceptsBothKeyNamesAndTrimsWhitespace() {
        XCTAssertEqual(try ClaudeCredentialParser.parse("  {\"claudeAiOauth\":{\"accessToken\":\"a\"}}\n").get(),
                       ClaudeCredential(accessToken: "a", subscriptionType: nil))
        XCTAssertEqual(try ClaudeCredentialParser.parse(#"{"claude.ai_oauth":{"accessToken":"b","subscriptionType":"pro"}}"#).get(),
                       ClaudeCredential(accessToken: "b", subscriptionType: "pro"))
    }

    func testParseFailuresAreDistinguished() {
        XCTAssertEqual(failure(ClaudeCredentialParser.parse("nope")), .invalidJSON)
        XCTAssertEqual(failure(ClaudeCredentialParser.parse(#"{"mcpOAuth":{}}"#)), .missingOAuthEntry)
        XCTAssertEqual(failure(ClaudeCredentialParser.parse(#"{"claudeAiOauth":{"accessToken":""}}"#)), .missingAccessToken)
    }

    private func failure(_ r: Result<ClaudeCredential, ClaudeCredentialParser.Failure>) -> ClaudeCredentialParser.Failure? {
        if case .failure(let f) = r { return f }
        return nil
    }
}
