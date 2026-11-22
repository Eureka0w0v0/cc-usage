import Foundation

/// 令牌过期时请 Claude Code 自己刷新：在默认的 `~/.claude` 里跑一次 `claude -p /usage`。
/// 对齐 cc-switch `services/claude_account/usage.rs` 的 run_usage / usage_args（上游 v4.0.26 起）。CC Usage 自己从不刷新令牌。
///
/// 只放规则：参数、子进程环境、到哪儿找 claude。真正起进程的在 App 层（ClaudeUsageRunner），这样规则能在单测里逐条钉住。
enum ClaudeUsageCLI {
    /// 两次 `/usage` 至少隔这么久（失败也算）：令牌刷新以后就能直接查，用不着再跑。
    static let runInterval: TimeInterval = 10 * 60
    static let runTimeout: TimeInterval = 45
    /// 在登录 shell 里找 claude 最多等多久。
    static let locateTimeout: TimeInterval = 15

    /// 只要 Claude Code 自己回答的 /usage：不带工具、MCP、任何设置来源，不留会话。
    static let arguments = [
        "-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
        "--setting-sources", "", "--no-session-persistence",
    ]

    /// 依次找的位置：原生安装器、旧版本地安装、Homebrew（Apple 芯片 / Intel）。都没有再问登录 shell（locateInvocation）。
    static func candidates(home: String) -> [String] {
        [home + "/.local/bin/claude", home + "/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
    }

    /// 在登录 shell 里问 claude 在哪。认得的 shell 才用（同上游 is_valid_shell），否则 `/bin/sh`；bash、zsh 读交互式配置
    /// （同上游 default_flag_for_shell，nvm 之类多半写在那里）。zsh 用 `whence -p`、bash 用 `type -P`：用户给 claude
    /// 起的 alias 不算数（`command -v` 打出来的是 alias 的定义）。
    static func locateInvocation(shell: String?) -> (executable: String, arguments: [String]) {
        let fallback = ("/bin/sh", ["-c", "command -v claude"])
        guard let shell, shell.hasPrefix("/") else { return fallback }
        switch (shell as NSString).lastPathComponent {
        case "zsh": return (shell, ["-lic", "whence -p claude"])
        case "bash": return (shell, ["-lic", "type -P claude"])
        case "fish": return (shell, ["-lc", "command -v claude"])
        case "sh", "dash": return (shell, ["-c", "command -v claude"])
        default: return fallback
        }
    }

    /// 登录 shell 输出里的第一行绝对路径：交互式配置可能先打印欢迎语（同上游 first_abs_path_line）。
    static func locatedPath(fromShellOutput output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("/") }
    }

    /// 原样带给子进程的变量：身份、临时目录、语言区域、代理。其余一律不带。
    private static let passthrough: Set<String> = [
        "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG",
        "http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY",
    ]
    /// 上游给 /usage 加的开关：不在共享的 projects/ 里给工作目录建记忆目录、不上报、不自动升级。
    private static let switches = [
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_TELEMETRY": "1",
        "DISABLE_ERROR_REPORTING": "1", "DISABLE_AUTOUPDATER": "1",
    ]
    private static let systemPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// 子进程环境，从白名单起。上游是按名单删（`ANTHROPIC_*`、`CLAUDE_CODE_USE_*`、令牌类）；这里从白名单起，
    /// CC Usage 是从某个 Claude Code 会话里启动的时候，宿主的网关地址、会话令牌也一个都带不进去。
    /// - 不带 `CLAUDE_CONFIG_DIR`：用默认的 `~/.claude`，和钥匙串只查默认条目一致。
    /// - 不带 `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`：设了它 /usage 不联网，只打印一小时内别处留下的读数。
    /// - PATH：claude 所在目录在前（npm 装的是 `#!/usr/bin/env node` 脚本，node 一般和它在同一目录），再加 Homebrew 和
    ///   系统目录。上游还并上登录 shell 的 PATH；这里不起那个 shell，node 装在别处的 npm 安装会跑不起来（日志里有退出码）。
    /// - 从访达启动时没有 LANG，补 `en_US.UTF-8`。
    static func environment(inherited: [String: String], home: String, executableDir: String) -> [String: String] {
        var env = inherited.filter { passthrough.contains($0.key) || $0.key.hasPrefix("LC_") }
        env["HOME"] = home
        if env["LANG"]?.isEmpty ?? true { env["LANG"] = "en_US.UTF-8" }
        var seen = Set<String>()
        env["PATH"] = ([executableDir] + systemPath).filter { seen.insert($0).inserted }.joined(separator: ":")
        env.merge(switches) { _, fixed in fixed }
        return env
    }
}
