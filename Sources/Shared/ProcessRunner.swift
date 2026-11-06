import Foundation

/// 起子进程、等它结束。要等结果的子进程都走这里：没有上限的 waitUntilExit 一旦卡住（钥匙串弹窗没人点、子进程挂起），
/// 调用方和排在它后面的所有人都永远等下去。
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
    }

    /// 发 SIGTERM 之后多久还不退就 SIGKILL。
    private static let terminateGrace: TimeInterval = 1
    /// 子进程退出后最多再等多久读完管道：它留下的后台进程可能还拿着写端，等不到 EOF。
    private static let drainGrace: TimeInterval = 0.5

    /// 跑到退出，返回退出码和标准输出；起不来或超时（进程已杀掉）返回 nil。stdin 是空设备，stderr 丢弃。
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> Output? {
        let proc = Process()
        proc.executableURL = executable
        proc.arguments = arguments
        let out = Pipe()
        proc.standardOutput = out
        // stderr 接空设备：不读的管道一旦写满，子进程会卡在 write 上
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }
        do { try proc.run() } catch { return nil }

        // 边跑边读：输出超过管道缓冲时，等退出再读就互相卡死
        let reader = PipeReader(out.fileHandleForReading)
        guard exited.wait(timeout: .now() + timeout) == .success else {
            stop(proc, exited)
            return nil
        }
        return Output(status: proc.terminationStatus, stdout: reader.collected(waiting: drainGrace))
    }

    private static func stop(_ proc: Process, _ exited: DispatchSemaphore) {
        proc.terminate()
        guard exited.wait(timeout: .now() + terminateGrace) == .timedOut else { return }
        kill(proc.processIdentifier, SIGKILL)
        _ = exited.wait(timeout: .now() + terminateGrace)
    }

    /// 后台读管道。读到 EOF 就结束，文件句柄随之释放。
    private final class PipeReader: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let finished = DispatchSemaphore(value: 0)

        init(_ handle: FileHandle) {
            DispatchQueue.global(qos: .utility).async { [self] in
                withExtendedLifetime(handle) { drain(handle.fileDescriptor) }
                finished.signal()
            }
        }

        /// 用 read(2)：FileHandle.read(upToCount:) 要凑够字节数或等到 EOF 才返回，后台进程拿着写端时一个字节也拿不到。
        private func drain(_ fd: Int32) {
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    lock.withLock { data.append(contentsOf: buffer[..<count]) }
                } else if count == 0 || errno != EINTR {
                    return
                }
            }
        }

        func collected(waiting: TimeInterval) -> Data {
            _ = finished.wait(timeout: .now() + waiting)
            return lock.withLock { data }
        }
    }
}
