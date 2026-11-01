import Foundation

/// Oh My Pi 会话文件的发现规则，对齐上游 v4.0.22 `pi::session_files_for(&omp::OMP)`
/// 与 `session_usage_omp::own_files`：
/// - 根目录：cc-switch `settings.json` 的 `ompConfigDir`（`~` 展开规则同 `resolve_override_path`）下的
///   `sessions`，没设就是 `~/.omp/agent/sessions`；布局是项目目录（根 / 项目 / *.jsonl，深度 2）。
/// - 顶层只收普通文件（不跟符号链接）且扩展名是 `jsonl`；每个会话文件去掉扩展名的同名目录下递归收子会话
///   （subagent、fork），跳过 `subagent-artifacts`，同样不跟符号链接。
/// - 按路径组件排序（Rust `PathBuf` 的序）。
/// - Pi 与 Oh My Pi 共用同一个根时，只留首行是 `{"type":"title"}` 的文件（其余是 Pi 的）。
///
/// 不看环境变量（`PI_CODING_AGENT_SESSION_DIR`、`OMP_PROFILE`、`PI_CODING_AGENT_DIR`、`XDG_DATA_HOME` 等）：
/// cc-switch 和本应用都是 GUI 进程，拿不到 shell 里设的环境变量，两边看到的根相同。判断是否与 Pi 共用根时
/// 也不读 Pi 自己 settings 里的 `sessionDir`（只看 cc-switch 的 `piConfigDir` 覆盖和默认位置）。
enum OmpSessionFiles {
    /// 上游 `pi::MAX_SESSION_BYTES`：超过的文件整个不导入。
    static let maxSessionBytes: Int64 = 128 * 1024 * 1024
    /// `TITLE_SLOT_PROBE_BYTES`：判断首行是不是 title 时最多读这么多字节。
    static let titleProbeBytes = 4096

    struct Roots: Equatable {
        /// Oh My Pi 的会话根目录。
        var omp: String
        /// Pi 的会话根目录（只用来判断两者是否共用一个根）。
        var pi: String
    }

    static var defaultSettingsPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".cc-switch/settings.json")
    }

    /// 读 cc-switch settings.json 的 `ompConfigDir` / `piConfigDir`（文件缺失、坏掉、值不是非空字符串都当没设）。
    static func roots(home: String = NSHomeDirectory(), settingsPath: String = defaultSettingsPath) -> Roots {
        var settings: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: settingsPath),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = object
        }
        func agentDir(_ key: String, default fallback: String) -> String {
            guard let raw = settings[key] as? String,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return fallback }
            return resolveOverridePath(raw, home: home)
        }
        let omp = agentDir("ompConfigDir", default: (home as NSString).appendingPathComponent(".omp/agent"))
        let pi = agentDir("piConfigDir", default: (home as NSString).appendingPathComponent(".pi/agent"))
        return Roots(omp: (omp as NSString).appendingPathComponent("sessions"),
                     pi: (pi as NSString).appendingPathComponent("sessions"))
    }

    /// settings.rs::resolve_override_path：`~` 与 `~/…`、`~\…` 展开到 home（按 `/`、`\` 拆段、丢掉空段），
    /// 其余原样。
    static func resolveOverridePath(_ raw: String, home: String) -> String {
        if raw == "~" { return home }
        for prefix in ["~/", "~\\"] where raw.hasPrefix(prefix) {
            let parts = raw.dropFirst(2).split(whereSeparator: { $0 == "/" || $0 == "\\" }).map(String.init)
            return parts.reduce(home) { ($0 as NSString).appendingPathComponent($1) }
        }
        return raw
    }

    /// 本轮的会话文件（已排序、已按「是否与 Pi 共用根」过滤）+ 枚举时读过的全部目录（给 DirListCache 判失效）。
    static func discover(_ roots: Roots) -> (files: [String], dirs: [String]) {
        var dirs = [roots.omp]
        var files: [String] = []
        for project in entries(roots.omp) where project.kind == .directory {
            dirs.append(project.path)
            for entry in entries(project.path) where entry.kind == .file && hasJSONLExtension(entry.name) {
                files.append(entry.path)
            }
        }
        var children: [String] = []
        for session in files {
            collectChildren(stem(session), into: &children, dirs: &dirs)
        }
        files.append(contentsOf: children)
        files.sort(by: rustPathOrder)
        if sharesRoot(roots) {
            files = files.filter(opensWithTitleSlot)
        }
        return (files, dirs)
    }

    /// 子会话：递归、跳过 `subagent-artifacts`（里面是转录和审计日志，没有 session header）、不跟符号链接。
    private static func collectChildren(_ dir: String, into output: inout [String], dirs: inout [String]) {
        let list = entries(dir)
        guard !list.isEmpty || isDirectory(dir) else {
            dirs.append(dir)   // 还不存在：记下来，等它被创建时缓存失效
            return
        }
        dirs.append(dir)
        for entry in list {
            switch entry.kind {
            case .directory where entry.name != "subagent-artifacts":
                collectChildren(entry.path, into: &output, dirs: &dirs)
            case .file where hasJSONLExtension(entry.name):
                output.append(entry.path)
            default:
                break
            }
        }
    }

    // MARK: - 小工具

    enum Kind { case file, directory, other }
    struct Entry { var name: String; var path: String; var kind: Kind }

    /// 目录项，类型按 lstat 判断（不跟符号链接，同 `DirEntry::file_type`）。读不了返回空。
    static func entries(_ dir: String) -> [Entry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            var kind = Kind.other
            if lstat(path, &st) == 0 {
                switch st.st_mode & S_IFMT {
                case S_IFREG: kind = .file
                case S_IFDIR: kind = .directory
                default: kind = .other
                }
            }
            return Entry(name: name, path: path, kind: kind)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Rust `Path::extension() == Some("jsonl")`：最后一个点之后是 jsonl，且点前面不是空串（`.jsonl` 没有扩展名）。
    static func hasJSONLExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name[name.index(after: dot)...] == "jsonl"
    }

    /// `path.with_extension("")`：去掉文件名的扩展名（规则同 hasJSONLExtension）。
    static func stem(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return path }
        let dir = (path as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent(String(name[..<dot]))
    }

    /// Rust `PathBuf` 的排序：按路径组件逐个比（组件按字节比），而不是整串按字节比。
    static func rustPathOrder(_ a: String, _ b: String) -> Bool {
        let ca = a.split(separator: "/"), cb = b.split(separator: "/")
        for (x, y) in zip(ca, cb) where x != y {
            return x.utf8.lexicographicallyPrecedes(y.utf8)
        }
        return ca.count < cb.count
    }

    /// 两个根（各自 realpath，取不到就用原路径）是否相同。
    static func sharesRoot(_ roots: Roots) -> Bool {
        func canonical(_ p: String) -> String {
            guard let resolved = realpath(p, nil) else { return p }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return canonical(roots.omp) == canonical(roots.pi)
    }

    /// 首行（最多 4096 字节）是不是 `{"type":"title"}`。
    static func opensWithTitleSlot(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: titleProbeBytes), !head.isEmpty else { return false }
        let line = head.split(separator: 0x0A, maxSplits: 1, omittingEmptySubsequences: false).first ?? head[...]
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? NSDictionary else { return false }
        return object["type"] as? String == "title"
    }
}
