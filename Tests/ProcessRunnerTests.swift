import XCTest

/// 子进程的统一入口：起不来、超时都返回 nil，超时的进程要杀掉，调用方绝不无限等。
final class ProcessRunnerTests: XCTestCase {
    private let shell = URL(fileURLWithPath: "/bin/sh")

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
        XCTAssertNil(sh("echo $$ > \(pidFile); sleep 4", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "进程要真的没了")
    }

    /// 不理 SIGTERM 的进程也不能把调用方拖住。
    func testTimeoutEscalatesWhenTheProcessIgnoresTerminate() {
        let start = Date()
        XCTAssertNil(sh("trap '' TERM; sleep 4", timeout: 0.3))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// 子进程退了但孙进程还拿着管道：不能因为读不到 EOF 就一直等。
    func testBackgroundGrandchildHoldingThePipeDoesNotBlock() throws {
        let start = Date()
        let out = try XCTUnwrap(sh("sleep 4 & printf done", timeout: 10))
        XCTAssertEqual(out.status, 0)
        XCTAssertEqual(String(decoding: out.stdout, as: UTF8.self), "done")
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
}
