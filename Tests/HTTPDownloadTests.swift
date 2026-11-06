import XCTest

/// 下载的上限：卡住（没有新字节）和拖死（一直有字节但总也下不完）都要失败，更新按钮才能回到可重试的状态。
final class HTTPDownloadTests: XCTestCase {
    /// 只会按脚本吐字节的本地 HTTP 服务。
    private final class Server: @unchecked Sendable {
        let port: UInt16
        private let listener: Int32
        private let lock = NSLock()
        private var stopped = false

        init(_ respond: @escaping @Sendable (_ write: (String) -> Bool) -> Void) throws {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            let size = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, size) }
            }
            XCTAssertEqual(bound, 0)
            XCTAssertEqual(Darwin.listen(fd, 4), 0)
            var actual = sockaddr_in()
            var length = size
            _ = withUnsafeMutablePointer(to: &actual) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
            }
            listener = fd
            port = UInt16(bigEndian: actual.sin_port)
            DispatchQueue.global().async { [self] in
                while true {
                    let client = Darwin.accept(fd, nil, nil)
                    guard client >= 0 else { return }
                    var noSigPipe: Int32 = 1
                    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                    DispatchQueue.global().async {
                        var request = [UInt8](repeating: 0, count: 4096)
                        _ = Darwin.read(client, &request, request.count)
                        respond { text in
                            !self.isStopped && text.utf8CString.withUnsafeBufferPointer {
                                Darwin.write(client, $0.baseAddress, $0.count - 1) >= 0
                            }
                        }
                        Darwin.close(client)
                    }
                }
            }
        }

        private var isStopped: Bool { lock.withLock { stopped } }

        func stop() {
            lock.withLock { stopped = true }
            Darwin.close(listener)
        }

        var url: URL { URL(string: "http://127.0.0.1:\(port)/app.zip")! }
    }

    private func download(_ server: Server, idle: TimeInterval, total: TimeInterval) async throws -> URL {
        try await HTTPDownload.toTemporaryFile(server.url, idleTimeout: idle, totalTimeout: total) { _ in }
    }

    /// 等 limit 秒拿结果，超过就算它还卡着。limit 留足余量，机器忙时也不能飘；没超时控制时要等 60 秒以上。
    private func outcome(within limit: TimeInterval,
                         _ body: @escaping @Sendable () async throws -> URL) async -> Result<URL, Error>? {
        await withTaskGroup(of: Result<URL, Error>?.self) { group in
            group.addTask {
                do { return .success(try await body()) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func testDownloadsTheBodyToAFile() async throws {
        let server = try Server { write in
            _ = write("HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello")
        }
        defer { server.stop() }
        let file = try await download(server, idle: 5, total: 5)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }

    func testNon200Fails() async throws {
        let server = try Server { write in
            _ = write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }
        defer { server.stop() }
        do {
            let file = try await download(server, idle: 5, total: 5)
            try? FileManager.default.removeItem(at: file)
            XCTFail("404 不能算下载成功")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("404"))
        }
    }

    private func leftovers() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: NSTemporaryDirectory())
            .filter { $0.hasPrefix("ccusage-update-") })
    }

    /// 失败的下载不留半截文件在临时目录。
    func testFailedDownloadLeavesNoPartialFile() async throws {
        let before = try leftovers()
        let server = try Server { write in
            _ = write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial")
        }
        defer { server.stop() }
        let result = await outcome(within: 15) { [self] in try await download(server, idle: 5, total: 5) }
        guard case .failure? = result else { return XCTFail("半截包不能算成功") }
        XCTAssertEqual(try leftovers(), before)
    }

    /// 负责杀的变异体：连接断在半路还当下载成功（Content-Length 对不上的半截包）。
    func testConnectionDroppedMidwayFails() async throws {
        let server = try Server { write in
            _ = write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial")
        }
        defer { server.stop() }
        let result = await outcome(within: 15) { [self] in try await download(server, idle: 5, total: 5) }
        guard case .failure? = result else { return XCTFail("半截包不能算成功：\(String(describing: result))") }
    }

    /// 负责杀的变异体：用 URLSession.shared 的默认超时（60 秒没字节才报错），服务器不吐数据时一直转圈。
    func testStallFailsAfterIdleTimeout() async throws {
        let server = try Server { write in
            _ = write("HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\npartial")
            while write("") { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer { server.stop() }
        let result = await outcome(within: 15) { [self] in try await download(server, idle: 0.5, total: 60) }
        guard case .failure? = result else { return XCTFail("应该很快超时失败：\(String(describing: result))") }
    }

    /// 负责杀的变异体：只有空闲超时。一直有字节进来但总也下不完时没有上限（默认总上限 7 天）。
    func testTricklingDownloadFailsAfterTotalTimeout() async throws {
        let server = try Server { write in
            _ = write("HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\n\r\n")
            while write("x") { Thread.sleep(forTimeInterval: 0.05) }
        }
        defer { server.stop() }
        let result = await outcome(within: 15) { [self] in try await download(server, idle: 60, total: 1) }
        guard case .failure? = result else { return XCTFail("应该很快超时失败：\(String(describing: result))") }
    }
}
