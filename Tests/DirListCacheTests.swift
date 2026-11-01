import XCTest

/// DirListCache：记下的目录 mtime 都没变就返回缓存；不存在的目录记 0，被创建时才失效。
final class DirListCacheTests: XCTestCase {
    /// 负责杀的变异体：缺失目录拿 nil 和记下的 0 比（缓存每轮失效）/ 目录被创建后仍返回旧缓存。
    func testMissingDirectoryKeepsCacheUntilItIsCreated() throws {
        let base = (NSTemporaryDirectory() as NSString).appendingPathComponent("ccusage-dircache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: base) }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        let missing = (base as NSString).appendingPathComponent("later")
        let cache = DirListCache()
        var calls = 0
        let enumerate = { () -> (files: [String], dirs: [String]) in
            calls += 1
            return (["f\(calls)"], [base, missing])
        }
        XCTAssertEqual(cache.files(enumerate), ["f1"])
        XCTAssertEqual(cache.files(enumerate), ["f1"], "什么都没变：用缓存")
        XCTAssertEqual(calls, 1)
        try FileManager.default.createDirectory(atPath: missing, withIntermediateDirectories: true)
        XCTAssertEqual(cache.files(enumerate), ["f2"], "缺失的目录被创建：重新枚举")
    }
}
