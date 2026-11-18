import Foundation

/// Claude Code 会话文件发现，对齐 session_usage.rs::collect_jsonl_files：固定三层，不递归。
///   * 项目/*.jsonl（主会话）
///   * 项目/会话/subagents/*.jsonl（子 agent）
///   * 项目/会话/subagents/workflows/wf_*/*.jsonl（Workflow 子 agent）
enum ClaudeSessionFiles {
    /// 本轮的会话文件 + 枚举时读过的全部目录（给 DirListCache 判失效）。文件顺序就是目录枚举的顺序：同一个
    /// message.id 出现在两个文件里时谁先读到决定保留规则的比较次序，这里不排序。
    static func discover(_ projectsDir: String) -> (files: [String], dirs: [String]) {
        var scan = Scan(dirs: [projectsDir])
        for proj in children(projectsDir) ?? [] { scan.addProject(join(projectsDir, proj)) }
        return (scan.files, scan.dirs)
    }

    private struct Scan {
        var files: [String] = []
        var dirs: [String]

        init(dirs: [String]) { self.dirs = dirs }

        mutating func addProject(_ path: String) {
            guard isDirectory(path) else { return }
            dirs.append(path)
            guard let subs = children(path) else { return }
            for sub in subs {
                let subPath = join(path, sub)
                if sub.hasSuffix(".jsonl") {
                    files.append(subPath)                    // 主会话
                } else if isDirectory(subPath) {
                    addSession(subPath)
                }
            }
        }

        /// 会话目录本身也要记：它下面「有没有长出 subagents/」这个判断就依赖它的内容，
        /// 漏记会让新开的子 agent 一直看不见。
        private mutating func addSession(_ path: String) {
            dirs.append(path)
            let subagents = join(path, "subagents")
            guard isDirectory(subagents) else { return }
            dirs.append(subagents)
            appendJSONLChildren(subagents)                   // 子 agent
            addWorkflows(join(subagents, "workflows"))
        }

        private mutating func addWorkflows(_ path: String) {
            guard isDirectory(path), let workflows = children(path) else { return }
            dirs.append(path)
            for workflow in workflows {                      // Workflow 子 agent
                let workflowPath = join(path, workflow)
                guard isDirectory(workflowPath) else { continue }
                dirs.append(workflowPath)
                appendJSONLChildren(workflowPath)
            }
        }

        private mutating func appendJSONLChildren(_ dir: String) {
            for entry in children(dir) ?? [] where entry.hasSuffix(".jsonl") {
                files.append(join(dir, entry))
            }
        }
    }

    private static func children(_ dir: String) -> [String]? {
        try? FileManager.default.contentsOfDirectory(atPath: dir)
    }

    /// 拼路径照旧用 `appendingPathComponent`（处理目录末尾的 `/`，结果和 cc-switch 记在 session_log_sync 里的
    /// 路径逐字相同），再转成原生的连续 UTF-8 存储。不转的话拿到的是桥接的 Cocoa 字符串（NSPathStore2）：这些
    /// 路径是叠加层几个字典的键，每个刷新 tick 每个文件要查好几次，桥接字符串的哈希和比较都走慢路径——全量
    /// 数据下占一轮刷新开销的一半。
    private static func join(_ dir: String, _ name: String) -> String {
        var path = (dir as NSString).appendingPathComponent(name)
        path.makeContiguousUTF8()
        return path
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }
}
