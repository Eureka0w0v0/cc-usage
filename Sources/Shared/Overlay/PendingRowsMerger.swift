import Foundation

/// 把各来源的待入库行并成一份，来源的行没变时复用上次的结果。
///
/// 一轮刷新里有好几条查询都要这份行（今日汇总、走势、最后活动时间、近 7 天、近 30 天、每个勾选的应用码片）。
/// cc-switch 长期不入库时待入库的行有上万条，每条查询都重新合并去重一遍是白花的：给前面来源的全部 request_id
/// 建集合、过滤后面的来源、再拼成新数组。
///
/// 合并规则（从 UsageStore.overlayRows 原样搬来）：按来源的先后拼接，同一个 request_id 先到先得。各来源的
/// request_id 命名空间不同（"session:<msg_id>" 与 "omp_session:<sha256>"），本来撞不上，去重只是兜底；累计结果
/// 还是空的时候直接用下一个来源，来源内部不去重（各叠加层按 request_id 存字典，自己就不会重复）。
///
/// 线程安全：各来源有自己的锁；这里的锁只护着记下的上一次结果。
final class PendingRowsMerger: @unchecked Sendable {
    private let sources: [PendingUsageSource]
    private let lock = NSLock()
    /// 上一次各来源交出的数组，和由它们合并出的结果。
    private var lastParts: [[OverlayRow]] = []
    private var lastMerged: [OverlayRow] = []

    init(_ sources: [PendingUsageSource]) {
        self.sources = sources
    }

    /// 当前全部待入库行。每个来源只问一遍；问来源时不持锁，来源扫描期间别的查询不用排队等这把锁。
    func rows(db: OpaquePointer) -> [OverlayRow] {
        let parts = sources.map { $0.pendingRows(db: db) }
        lock.lock()
        defer { lock.unlock() }
        if parts.count == lastParts.count, zip(parts, lastParts).allSatisfy(Self.sameStorage) {
            return lastMerged
        }
        let merged = Self.merge(parts)
        lastParts = parts
        lastMerged = merged
        return merged
    }

    static func merge(_ parts: [[OverlayRow]]) -> [OverlayRow] {
        var rows: [OverlayRow] = []
        for next in parts {
            if rows.isEmpty {
                rows = next                         // 常态：cc-switch 已消化完 Claude Code 日志
            } else if !next.isEmpty {
                let seen = Set(rows.map(\.requestId))
                rows.append(contentsOf: next.filter { !seen.contains($0.requestId) })
            }
        }
        return rows
    }

    /// 两个数组是不是同一块存储（基址和长度都相同）。
    ///
    /// 拿它判断「来源的行没变」是可靠的：`lastParts` 一直持有上一次的数组，那块存储不会被释放，所以同一基址
    /// 只可能是同一块存储；它有第二个引用，来源要改只能写时复制到新存储，不可能在原地改掉内容。反过来不成立
    /// ——内容相同但各自分配的两个数组算不同，那只是少复用一次，结果照样对。
    static func sameStorage(_ a: [OverlayRow], _ b: [OverlayRow]) -> Bool {
        a.count == b.count && a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in pa.baseAddress == pb.baseAddress }
        }
    }
}
