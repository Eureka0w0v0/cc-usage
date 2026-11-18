import XCTest

/// Claude Code 会话文件发现：固定三层、不递归；读过的目录都要交给 DirListCache，少记一个那一层的增删就看不见。
final class ClaudeSessionFilesTests: XCTestCase {
    private var root = ""

    override func setUpWithError() throws {
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ccusage-claude-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
    }

    private func path(_ relative: String) -> String { (root as NSString).appendingPathComponent(relative) }

    private func touch(_ relative: String) throws {
        let p = path(relative)
        try FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data())
    }

    func testFindsTheThreeLayersOnly() throws {
        try touch("p/main.jsonl")
        try touch("p/main.txt")
        try touch("p/s1/subagents/agent.jsonl")
        try touch("p/s1/subagents/workflows/wf_1/step.jsonl")
        try touch("p/s1/other.jsonl")                                    // 会话目录下直接放的不算
        try touch("p/s1/subagents/deep/agent.jsonl")                     // subagents 下再嵌一层不算
        try touch("p/s1/subagents/workflows/wf_1/deep/step.jsonl")       // 第三层再嵌一层不算
        try touch("loose.jsonl")                                         // 根目录下的文件不是项目
        let found = ClaudeSessionFiles.discover(root)
        XCTAssertEqual(Set(found.files), [path("p/main.jsonl"), path("p/s1/subagents/agent.jsonl"),
                                          path("p/s1/subagents/workflows/wf_1/step.jsonl")])
    }

    /// 负责杀的变异体：不记会话目录（之后新开的 subagents/ 永远看不见）。
    func testRecordsEveryDirectoryItDecidedOn() throws {
        try touch("p/s1/subagents/workflows/wf_1/step.jsonl")
        try touch("p/s2/note.txt")
        let found = ClaudeSessionFiles.discover(root)
        XCTAssertEqual(Set(found.dirs), [root, path("p"), path("p/s1"), path("p/s2"), path("p/s1/subagents"),
                                         path("p/s1/subagents/workflows"), path("p/s1/subagents/workflows/wf_1")])
    }

    /// 发现出来的路径要是原生（连续 UTF-8）字符串：它们是叠加层几个字典的键，每个刷新 tick 每个文件都要查好几次。
    /// `appendingPathComponent` 给的是桥接的 Cocoa 字符串，哈希和比较不走 UTF-8 快路径——全量数据下占一轮刷新
    /// 开销的一半。内容不能变：还得和 cc-switch 记在 session_log_sync 里的路径逐字相同。
    /// 负责杀的变异体：拼完路径不转成原生存储。
    func testDiscoveredFilesUseNativeStringStorage() throws {
        try touch("p/main.jsonl")
        try touch("p/s1/subagents/agent.jsonl")
        try touch("p/s1/subagents/workflows/wf_1/step.jsonl")
        let found = ClaudeSessionFiles.discover(root)
        XCTAssertEqual(found.files.count, 3)
        for file in found.files {
            XCTAssertTrue(file.isContiguousUTF8, file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file), file)
        }
        XCTAssertEqual(Set(found.files), [path("p/main.jsonl"), path("p/s1/subagents/agent.jsonl"),
                                          path("p/s1/subagents/workflows/wf_1/step.jsonl")])
    }

    func testMissingRootRecordsItSoItsCreationInvalidatesTheCache() {
        let missing = path("nope")
        let found = ClaudeSessionFiles.discover(missing)
        XCTAssertEqual(found.files, [])
        XCTAssertEqual(found.dirs, [missing])
    }
}
