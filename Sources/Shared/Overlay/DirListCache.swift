import Foundation

/// 目录列表缓存：只在目录树形状变动时重新枚举。
///
/// 两个 overlay 的 collectJSONLFiles 都是每个刷新 tick 必跑的热路径，而它们要趟过的
/// 条目远多于真正关心的 .jsonl——~/.omp/agent/sessions 下 10928 个条目里 9704 个是
/// .log、463 个是 .md，只剩 566 个 .jsonl，枚举一趟实测 47.8ms。换遍历 API 治不了本
/// (FileManager.enumerator 与显式栈 + contentsOfDirectory 实测同样是 47.7ms)，因为
/// 成本就在「条目多」本身。
///
/// 目录 mtime 在其直接子项增删时变动，正是「文件列表可能变了」的信号：只 stat 枚举
/// 时走过的那几十个目录就能判定缓存是否还成立（83 个目录 0.118ms，比重新枚举快 400 倍）。
/// 文件内容追加不会改父目录 mtime——那由各 overlay 自己的逐文件 mtime 负责，与本缓存
/// 无关，故不会漏掉正在写入的会话。
///
/// 线程安全由调用方保证：两个 overlay 都只在各自的 lock 内调用。
final class DirListCache {
    private var dirMtimes: [(path: String, mtime: Int64)] = []
    private var cached: [String] = []
    private var primed = false

    /// enumerate 必须返回 (匹配到的文件, 枚举过程中据以做判断的全部目录)。
    /// 少记一个目录 = 那一层的增删会被漏看，故凡是 contentsOfDirectory 过、或
    /// 据其内容决定过分支的目录都要记进去。
    func files(_ enumerate: () -> (files: [String], dirs: [String])) -> [String] {
        // 不存在的目录记的是 0，比对时同样按 0 算（nil 直接和 0 比永远不等，缓存会每轮失效）。
        if primed, dirMtimes.allSatisfy({ (OverlayFileIO.fileStat($0.path)?.mtimeNs ?? 0) == $0.mtime }) { return cached }
        let r = enumerate()
        cached = r.files
        // 目录不存在 → 记 0；将来被创建时 mtime 变为真值，缓存自然失效。
        dirMtimes = r.dirs.map { (path: $0, mtime: OverlayFileIO.fileStat($0)?.mtimeNs ?? 0) }
        primed = true
        return cached
    }
}
