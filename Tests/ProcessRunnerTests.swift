import XCTest

/// 子进程的统一入口：起不来、超时都返回 nil，超时的进程要杀掉，调用方绝不无限等。
/// 时限留足余量：机器忙时这些用例也不能飘。被测进程睡 30 秒，只要明显早于它返回就算过。
final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")
    private let limit: TimeInterval = 15

    private func sh(_ script: String, timeout: TimeInterval = 10) -> ProcessRunner.Output? {
        ProcessRunner.run(shell, ["-c", script], timeout: timeout)
    }

    func testReturnsExitStatusAndStdout() throws {
        let out = try XCTUnwrap(sh("printf hello; exit 3"))
        XCTAssertEqual(out.status, 3)
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "hello")
    }

    /// 负责杀的变异体：等退出之后才读管道（输出超过管道缓冲时子进程卡在 write 上，互相等到超时）。
    func testOutputLargerThanThePipeBufferComesBackWhole() throws {
        let out = try XCTUnwrap(sh("head -c 300000 /dev/zero"))
        XCTAssertEqual(out.stdout.count, 300_000)
    }

    func testStderrIsDiscardedEvenWhenItIsLarge() throws {
        let out = try XCTUnwrap(sh("head -c 300000 /dev/zero >&2; printf ok"))
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "ok")
    }

    func testLaunchFailureReturnsNil() {
        XCTAssertNil(ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), [], timeout: 1))
    }

    /// 负责杀的变异体：没有上限地等（security 卡在钥匙串弹窗时所有 get_quota 搭车方一起等）。
    func testTimeoutKillsTheProcessAndReturnsNil() throws {
        let pidFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("ccusage-proc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let start = Date()
        XCTAssertNil(sh("echo $$ > \(pidFile); exec sleep 30", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), limit)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "进程要真的没了")
    }

    /// 负责杀的变异体：只发 SIGTERM。不理它的进程要 SIGKILL，也不能把调用方拖住。
    func testTimeoutEscalatesWhenTheProcessIgnoresTerminate() throws {
        let pidFile = (NSTemporaryDirectory() as NSString).appendingPathComponent("ccusage-proc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: pidFile) }
        let start = Date()
        XCTAssertNil(sh("trap '' TERM; echo $$ > \(pidFile); exec sleep 30", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), limit)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "不理 SIGTERM 的进程也要没了")
    }

    /// 子进程退了但孙进程还拿着管道：不能因为读不到 EOF 就一直等。
    func testBackgroundGrandchildHoldingThePipeDoesNotBlock() throws {
        let start = Date()
        let out = try XCTUnwrap(sh("sleep 30 & printf done", timeout: 20))
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), limit)
    }

    /// 给了环境就只用它（`claude -p /usage` 靠这个把宿主会话的变量挡在外面），给了工作目录就在那里跑。
    /// 负责杀的变异体：环境参数没生效（继承了本进程的整份环境）/ 工作目录参数没生效。
    func testGivenEnvironmentAndDirectoryAreUsed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccusage-cwd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = try XCTUnwrap(ProcessRunner.run(shell, ["-c", #"printf '%s|%s|%s' "$FOO" "${HOME-unset}" "$(basename "$(pwd)")""#],
                                                  environment: ["FOO": "bar"], currentDirectory: dir, timeout: 10))
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "bar|unset|\(dir.lastPathComponent)")
    }

    /// 不给就继承本进程的（钥匙串那条 `security` 一直这么跑）。负责杀的变异体：不给环境时子进程拿到空环境。
    func testEnvironmentIsInheritedByDefault() throws {
        let out = try XCTUnwrap(sh(#"printf '%s' "$HOME""#))
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), ProcessInfo.processInfo.environment["HOME"])
    }
}
