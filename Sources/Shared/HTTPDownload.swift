import Foundation

/// 流式下载。默认的 URLSession 空闲 60 秒才报错、总时长上限 7 天，更新按钮卡在下载中就回不来了，所以两个上限都自己定。
enum HTTPDownload {
    struct Failed: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// 下载到临时文件，按 128KB 块写盘并回报百分比（-1 = 服务器没给 Content-Length）。失败时不留半截文件。
    /// - idleTimeout：多久没有新字节算卡住。
    /// - totalTimeout：整个下载的上限。
    static func toTemporaryFile(_ url: URL, idleTimeout: TimeInterval, totalTimeout: TimeInterval,
                                progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = totalTimeout
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (bytes, resp) = try await session.bytes(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failed(message: "download HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-update-\(UUID().uuidString).zip")
        do {
            try await write(bytes, expected: resp.expectedContentLength, to: file, progress: progress)
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    private static func write(_ bytes: URLSession.AsyncBytes, expected total: Int64, to file: URL,
                              progress: @Sendable (Int) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buf = Data(); buf.reserveCapacity(1 << 17)
        var written: Int64 = 0
        var lastPct = -2
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 17 {
                try handle.write(contentsOf: buf)
                written += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                let pct = total > 0 ? Int(written * 100 / total) : -1
                if pct != lastPct { lastPct = pct; progress(pct) }
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: buf) }
    }
}
