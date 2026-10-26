import Foundation

// Claude Code 的 OAuth 凭据从哪儿取、怎么取舍（对齐 cc-switch `subscription.rs` 的
// read_claude_credentials / read_claude_credentials_from_keychain_with，含 #8764）。
//
// 只放规则：试哪几次、带什么参数、拿到的条目算不算数。真正起 `security` 进程的 runner
// 由 App 层注入（QuotaService），这样规则能在单测里逐条钉住，不碰真钥匙串。

/// 一份可用的 Claude 凭据。expiresAt 不解析：过没过期由官方接口的 401/403 裁决（与上游一致）。
struct ClaudeCredential: Sendable, Equatable {
    let accessToken: String
    let subscriptionType: String?
}

/// 凭据 JSON 的解析（钥匙串条目与 `~/.claude/.credentials.json` 同一格式）：
/// `{ "claudeAiOauth": { "accessToken": "...", "subscriptionType": "..." } }`，
/// 旧版的键名 `claude.ai_oauth` 同样认。
enum ClaudeCredentialParser {
    enum Failure: Error, Equatable {
        case invalidJSON
        case missingOAuthEntry
        case missingAccessToken
    }

    static func parse(_ json: String) -> Result<ClaudeCredential, Failure> {
        let text = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure(.invalidJSON) }
        guard let entry = (root["claudeAiOauth"] ?? root["claude.ai_oauth"]) as? [String: Any]
        else { return .failure(.missingOAuthEntry) }
        guard let token = entry["accessToken"] as? String, !token.isEmpty
        else { return .failure(.missingAccessToken) }
        return .success(ClaudeCredential(accessToken: token,
                                         subscriptionType: entry["subscriptionType"] as? String))
    }
}

/// `security find-generic-password … -w` 跑一次的结果：退出码 + 标准输出。
struct SecurityLookupOutput: Sendable {
    let status: Int32
    let stdout: Data
}

/// 从 macOS 钥匙串挑出 Claude Code 的登录。
///
/// 钥匙串里可能有好几条同名（`Claude Code-credentials`）条目，其中有的只存了 MCP 登录
/// （`mcpOAuth`）。只按服务名查时取到哪条不确定，取到那种旧条目就会误报「没有凭据」
/// （上游 #8762）。所以先按当前用户的账户查，查不到可用的登录再退回只按服务名查。
enum ClaudeKeychainLookup {
    static let service = "Claude Code-credentials"
    /// `security` 找不到条目时的退出码（errSecItemNotFound）。
    static let itemNotFound: Int32 = 44

    /// 依次要跑的参数：有用户名时先带 `-a <用户名>`，最后总有一次不带账户的旧查法。
    static func attempts(user: String?) -> [[String]] {
        let base = ["find-generic-password", "-s", service]
        var out: [[String]] = []
        if let user, !user.isEmpty { out.append(base + ["-a", user, "-w"]) }
        out.append(base + ["-w"])
        return out
    }

    /// 按顺序试，返回第一份带 Claude token 的凭据；钥匙串里没有可用的返回 nil（调用方再读凭据文件）。
    /// - 退出码 0 且解析出 token → 用它；
    /// - 退出码 44（没有这条）、输出不是 UTF-8、解析不出 token → 试下一个；
    /// - runner 返回 nil（进程起不来）或其它退出码 → 不再试钥匙串。
    static func select(user: String?,
                       run: (_ arguments: [String]) -> SecurityLookupOutput?) -> ClaudeCredential? {
        for arguments in attempts(user: user) {
            guard let output = run(arguments) else { return nil }
            if output.status == itemNotFound { continue }
            guard output.status == 0 else { return nil }
            guard let json = String(data: output.stdout, encoding: .utf8) else { continue }
            if case .success(let credential) = ClaudeCredentialParser.parse(json) { return credential }
        }
        return nil
    }
}
