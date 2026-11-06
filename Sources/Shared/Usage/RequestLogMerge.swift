import Foundation

/// 请求日志的二路归并：库内行与增量行各自按 created_at DESC 有序，这里归并成一路。纯函数，分页的取数在 requestLogs。
enum RequestLogMerge {
    /// 归并出前 limit 条。同 created_at 时库内行优先(>=)：cc-switch 补录后同一条响应会先由库内行
    /// 顶替、overlay 侧再被 request_id 去重剔除，翻页时不会先后跳位。
    static func merged(_ rows: [RequestLogRow], _ overlay: [RequestLogRow], limit: Int) -> [RequestLogRow] {
        var merged: [RequestLogRow] = []
        merged.reserveCapacity(min(limit, rows.count + overlay.count))
        var i = 0, j = 0
        while merged.count < limit, i < rows.count || j < overlay.count {
            if j >= overlay.count || (i < rows.count && rows[i].createdAt >= overlay[j].createdAt) {
                merged.append(rows[i]); i += 1
            } else {
                merged.append(overlay[j]); j += 1
            }
        }
        return merged
    }
}
