import XCTest

/// OmpSessionFiles：Oh My Pi 会话文件的发现规则（对齐上游 v4.0.22 `pi::session_files_for(&omp::OMP)`）。
final class OmpSessionFilesTests: XCTestCase {
    private var base = ""
    private var root = ""

    override func setUpWithError() throws {
        base = (NSTemporaryDirectory() as NSString).appendingPathComponent("ccusage-ompfiles-\(UUID().uuidString)")
        root = (base as NSString).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: base)
    }

    @discardableResult
    private func touch(_ relative: String, _ content: String = "{}\n") throws -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try content.write(toFile: path, atomically: false, encoding: .utf8)
        return path
    }

    private func relative(_ files: [String]) -> [String] {
        files.map { String($0.dropFirst(root.count + 1)) }
    }

    private func roots(pi: String? = nil) -> OmpSessionFiles.Roots {
        OmpSessionFiles.Roots(omp: root, pi: pi ?? (base as NSString).appendingPathComponent("pi-sessions"))
    }

    /// 负责杀的变异体：顶层不限深度 2 / 子会话不递归 / 不跳过 subagent-artifacts / 扩展名判断放宽。
    func testCollectsDepthTwoSessionsAndTheirNestedChildren() throws {
        try touch("proj/a.jsonl")
        try touch("proj/a/child.jsonl")
        try touch("proj/a/deeper/grand.jsonl")
        try touch("proj/a/subagent-artifacts/transcript.jsonl")
        try touch("top.jsonl")                    // 深度 1：不是项目目录布局
        try touch("proj/other/stray.jsonl")       // 不在任何会话的同名目录下
        try touch("proj/.jsonl")                  // 没有扩展名
        try touch("proj/b.JSONL")                 // 扩展名区分大小写
        try touch("proj/c.jsonl.bak")
        let found = relative(OmpSessionFiles.discover(roots()).files)
        // 组件序：同一层里 "a" < "a.jsonl"，所以子会话排在父会话文件前面（同 Rust PathBuf）。
        XCTAssertEqual(found, ["proj/a/child.jsonl", "proj/a/deeper/grand.jsonl", "proj/a.jsonl"])
    }

    /// 负责杀的变异体：跟了符号链接（文件或项目目录）。
    func testSkipsSymlinkedFilesAndDirectories() throws {
        let real = try touch("proj/real.jsonl")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: (root as NSString).appendingPathComponent("proj/link.jsonl"),
                                  withDestinationPath: real)
        let outside = (base as NSString).appendingPathComponent("elsewhere")
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "{}\n".write(toFile: (outside as NSString).appendingPathComponent("x.jsonl"), atomically: false, encoding: .utf8)
        try fm.createSymbolicLink(atPath: (root as NSString).appendingPathComponent("linked-proj"),
                                  withDestinationPath: outside)
        XCTAssertEqual(relative(OmpSessionFiles.discover(roots()).files), ["proj/real.jsonl"])
    }

    /// 负责杀的变异体：按整串字节排序（'-' < '/'，会把 a-b.jsonl 排到 a/ 的子会话前面）。
    func testSortsByPathComponentsLikeRust() throws {
        try touch("p/a.jsonl")
        try touch("p/a-b.jsonl")
        try touch("p/a/x.jsonl")
        XCTAssertEqual(relative(OmpSessionFiles.discover(roots()).files),
                       ["p/a/x.jsonl", "p/a-b.jsonl", "p/a.jsonl"])
    }

    /// 负责杀的变异体：与 Pi 共用根时不过滤 / 不共用时也过滤。
    func testSharedPiRootKeepsOnlyTitleSlotFiles() throws {
        try touch("p/omp.jsonl", #"{"type":"title","v":1,"title":"","pad":""}"# + "\n" +
                  #"{"type":"session","version":3,"id":"s1"}"# + "\n")
        try touch("p/pi.jsonl", #"{"type":"session","version":3,"id":"s2"}"# + "\n")
        XCTAssertEqual(relative(OmpSessionFiles.discover(roots()).files), ["p/omp.jsonl", "p/pi.jsonl"])
        XCTAssertEqual(relative(OmpSessionFiles.discover(roots(pi: root)).files), ["p/omp.jsonl"])
    }

    /// 枚举时读过的目录都要交给 DirListCache，包括还不存在的子会话目录（被创建时缓存才会失效）。
    func testReportsEveryDirectoryItReadIncludingMissingChildDirs() throws {
        try touch("p/a.jsonl")
        let dirs = Set(OmpSessionFiles.discover(roots()).dirs)
        XCTAssertTrue(dirs.isSuperset(of: [root, (root as NSString).appendingPathComponent("p"),
                                           (root as NSString).appendingPathComponent("p/a")]))
    }

    /// 负责杀的变异体：`~` 展开规则与上游 resolve_override_path 不一致；空串当成覆盖。
    func testRootsFollowCcSwitchOverrides() throws {
        let home = "/Users/someone"
        XCTAssertEqual(OmpSessionFiles.resolveOverridePath("~", home: home), home)
        XCTAssertEqual(OmpSessionFiles.resolveOverridePath("~/a//b/", home: home), "/Users/someone/a/b")
        XCTAssertEqual(OmpSessionFiles.resolveOverridePath("~\\a\\b", home: home), "/Users/someone/a/b")
        XCTAssertEqual(OmpSessionFiles.resolveOverridePath("/abs/dir", home: home), "/abs/dir")

        let settings = (base as NSString).appendingPathComponent("settings.json")
        XCTAssertEqual(OmpSessionFiles.roots(home: home, settingsPath: settings),
                       .init(omp: "/Users/someone/.omp/agent/sessions", pi: "/Users/someone/.pi/agent/sessions"))
        try #"{"ompConfigDir":"~/omp-x","piConfigDir":"  "}"#.write(toFile: settings, atomically: false, encoding: .utf8)
        XCTAssertEqual(OmpSessionFiles.roots(home: home, settingsPath: settings),
                       .init(omp: "/Users/someone/omp-x/sessions", pi: "/Users/someone/.pi/agent/sessions"))
        try "not json".write(toFile: settings, atomically: false, encoding: .utf8)
        XCTAssertEqual(OmpSessionFiles.roots(home: home, settingsPath: settings).omp,
                       "/Users/someone/.omp/agent/sessions")
    }

    func testExtensionAndStemFollowRustPathRules() {
        XCTAssertTrue(OmpSessionFiles.hasJSONLExtension("a.jsonl"))
        XCTAssertTrue(OmpSessionFiles.hasJSONLExtension("..jsonl"))
        XCTAssertFalse(OmpSessionFiles.hasJSONLExtension(".jsonl"))
        XCTAssertFalse(OmpSessionFiles.hasJSONLExtension("a.json"))
        XCTAssertEqual(OmpSessionFiles.stem("/r/p/2026-01-01_x.jsonl"), "/r/p/2026-01-01_x")
        XCTAssertEqual(OmpSessionFiles.stem("/r/p/.hidden"), "/r/p/.hidden")
    }
}
