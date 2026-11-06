import Foundation
import SQLite3

/// 两个叠加层共用的查库小工具（只读）。通用的 sqlite3 封装在 SQLiteSupport。
enum OverlayDB {
    /// IN 查询每批的绑定个数：SQLite 老版本的默认上限是 999，留足余量。
    static let bindBatchSize = 400

    struct Watermark: Equatable { var rows: Int64; var maxTs: Int64 }

    /// proxy_request_logs 的入库水位：行数 + 最新时间戳。两个 overlay 的预检共用。
    /// 补录会让两者都涨、清理旧日志会让行数掉——只要这对数不变，就说明库里没有
    /// 新行，pruneRowsAlreadyInDB 不可能产生新命中，那趟全量 IN 查询可以整个省掉。
    /// 本机实测 0.21ms（换掉的是 100ms 级的一整趟扫描）。
    static func watermark(_ db: OpaquePointer) -> Watermark? {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*), COALESCE(MAX(created_at), 0) FROM proxy_request_logs"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Watermark(rows: sqlite3_column_int64(stmt, 0), maxTs: sqlite3_column_int64(stmt, 1))
    }

    /// `<sql> (?, ?, …)` 分批查，第一列的值逐个交给 body。prepare 失败（缺表）的批次跳过。
    static func forEachMatch(_ db: OpaquePointer, _ sql: String, _ values: [String], _ body: (String) -> Void) {
        var start = 0
        while start < values.count {
            let chunk = values[start..<min(start + bindBatchSize, values.count)]
            start += bindBatchSize
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "\(sql) (\(placeholders))", -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (i, v) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), v, -1, SQLITE_TRANSIENT_DEST)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { body(String(cString: c)) }
            }
        }
    }

    /// 同 forEachMatch，收成集合。
    static func matching(_ db: OpaquePointer, _ sql: String, _ values: [String]) -> Set<String> {
        var out = Set<String>()
        forEachMatch(db, sql, values) { out.insert($0) }
        return out
    }
}
