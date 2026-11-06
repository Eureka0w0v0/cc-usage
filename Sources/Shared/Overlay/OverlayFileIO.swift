import Foundation

/// 叠加层看文件的唯一入口：两个 overlay 和目录缓存都靠 mtime 判断「变没变」，精度必须是同一份。
enum OverlayFileIO {
    /// mtime 纳秒 + 文件大小(与上游 metadata_modified_nanos 同精度,用 stat 拿真 ns)。
    static func fileStat(_ path: String) -> (mtimeNs: Int64, size: Int64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        return (mtimeNs: ns, size: Int64(st.st_size))
    }
}
