import XCTest

// 令牌过期时请 Claude Code 自己刷新用的 `claude -p /usage`：参数、子进程环境、到哪儿找 claude。
// 只测规则，不起真的 claude（ClaudeUsageRunner 虽然编进了测试 target，但没有用例调它）。
final class ClaudeUsageCLITests: XCTestCase {
    // 与上游 usage_args 逐项一致：不问模型、不带工具 / MCP / 任何设置来源、不留会话。
    // 负责杀的变异体：漏了 --no-session-persistence（每跑一次在 projects/ 里留一个会话）/ 空串参数被丢掉。
    func testArgumentsAskNoModelAndKeepNoSession() {
        XCTAssertEqual(ClaudeUsageCLI.arguments, [
            "-p", "/usage", "--output-format", "json", "--tools", "", "--strict-mcp-config",
            "--setting-sources", "", "--no-session-persistence",
        ])
        XCTAssertEqual(ClaudeUsageCLI.runInterval, 600)
        XCTAssertEqual(ClaudeUsageCLI.runTimeout, 45)
        XCTAssertEqual(ClaudeUsageCLI.locateTimeout, 15)
    }

    // 环境从白名单起：宿主会话的网关地址、令牌、配置目录一个也带不进去；上游的四个开关都在。
    // 负责杀的变异体：继承了整份环境 / 漏了某个开关 / 带上了 CLAUDE_CONFIG_DIR（跑到别的配置目录、刷新别的号）/
    // 带上了 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC（/usage 不联网，令牌也不刷新）。
    func testEnvironmentStartsFromAWhitelist() {
        let inherited = [
            "HOME": "/elsewhere", "USER": "u", "LOGNAME": "u", "SHELL": "/bin/zsh", "TMPDIR": "/var/tmp/x/",
            "LC_ALL": "ja_JP.UTF-8", "https_proxy": "http://127.0.0.1:7890", "NO_PROXY": "localhost",
            "PATH": "/Users/u/bin:/usr/bin",
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:1", "ANTHROPIC_API_KEY": "k",
            "CLAUDE_CODE_OAUTH_TOKEN": "t", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop", "CLAUDE_CONFIG_DIR": "/tmp/other",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "NODE_OPTIONS": "--require /tmp/x.js",
        ]
        let env = ClaudeUsageCLI.environment(inherited: inherited, home: "/Users/u", executableDir: "/Users/u/.local/bin")
        XCTAssertEqual(env, [
            "HOME": "/Users/u", "USER": "u", "LOGNAME": "u", "SHELL": "/bin/zsh", "TMPDIR": "/var/tmp/x/",
            "LANG": "en_US.UTF-8", "LC_ALL": "ja_JP.UTF-8", "https_proxy": "http://127.0.0.1:7890", "NO_PROXY": "localhost",
            "PATH": "/Users/u/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "DISABLE_TELEMETRY": "1",
            "DISABLE_ERROR_REPORTING": "1", "DISABLE_AUTOUPDATER": "1",
        ])
    }

    // 继承来的 LANG 照用；claude 就在系统目录里时 PATH 不重复。
    // 负责杀的变异体：LANG 一律写死 / PATH 不去重。
    func testInheritedLangWinsAndPathHasNoDuplicates() {
        let env = ClaudeUsageCLI.environment(inherited: ["LANG": "zh_CN.UTF-8"], home: "/Users/u",
                                             executableDir: "/opt/homebrew/bin")
        XCTAssertEqual(env["LANG"], "zh_CN.UTF-8")
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    // 负责杀的变异体：顺序变了（原生安装器要排第一）/ 漏了位置。
    func testCandidatesInOrder() {
        XCTAssertEqual(ClaudeUsageCLI.candidates(home: "/Users/u"), [
            "/Users/u/.local/bin/claude", "/Users/u/.claude/local/claude",
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
        ])
    }

    // 登录 shell 里问 claude 在哪：zsh / bash 读交互式配置（nvm 之类多半写在那里），用 whence -p / type -P 跳过 alias；
    // 认不得的 shell、相对路径一律退回 /bin/sh。
    // 负责杀的变异体：zsh 用 command -v（用户给 claude 起了 alias 时打出的是 alias 定义）/ 不认得的 shell 照样拿来跑。
    func testLocateInvocationPerShell() {
        func call(_ shell: String?) -> [String] {
            let invocation = ClaudeUsageCLI.locateInvocation(shell: shell)
            return [invocation.executable] + invocation.arguments
        }
        XCTAssertEqual(call("/bin/zsh"), ["/bin/zsh", "-lic", "whence -p claude"])
        XCTAssertEqual(call("/opt/homebrew/bin/bash"), ["/opt/homebrew/bin/bash", "-lic", "type -P claude"])
        XCTAssertEqual(call("/opt/homebrew/bin/fish"), ["/opt/homebrew/bin/fish", "-lc", "command -v claude"])
        XCTAssertEqual(call("/bin/dash"), ["/bin/dash", "-c", "command -v claude"])
        for other in ["/usr/local/bin/nu", "zsh", "", nil] as [String?] {
            XCTAssertEqual(call(other), ["/bin/sh", "-c", "command -v claude"], String(describing: other))
        }
    }

    // 取第一行绝对路径：交互式配置可能先打印欢迎语（同上游 first_abs_path_line）；alias 定义、找不到都不算。
    // 负责杀的变异体：死取第一行 / 不去空白。
    func testLocatedPathSkipsShellNoise() {
        XCTAssertEqual(ClaudeUsageCLI.locatedPath(fromShellOutput: "Welcome back\n  /Users/u/.nvm/bin/claude \n"),
                       "/Users/u/.nvm/bin/claude")
        XCTAssertNil(ClaudeUsageCLI.locatedPath(fromShellOutput: "alias claude='claude --effort max'\n"))
        XCTAssertNil(ClaudeUsageCLI.locatedPath(fromShellOutput: ""))
    }
}
