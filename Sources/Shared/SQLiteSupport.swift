import Foundation
import SQLite3

// SQLite 绑定文本时用（拷贝字符串，安全）
let SQLITE_TRANSIENT_DEST = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// 位置参数绑定值（UsageStore 全部查询共用）。
enum SQLBind { case int(Int64); case text(String) }

/// sqlite3 C API 小工具：绑定、取列、元数据探测。UsageStore / overlay / ModelPricing 共用。
enum SQLite {
    static func bindAll(_ stmt: OpaquePointer?, _ binds: [SQLBind]) {
        for (i, b) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch b {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DEST)
            }
        }
    }

    static func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
        return ""
    }
    static func textOpt(_ stmt: OpaquePointer?, _ i: Int32) -> String? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        if let c = sqlite3_column_text(stmt, i) { return String(cString: c) }
        return nil
    }
    static func intOpt(_ stmt: OpaquePointer?, _ i: Int32) -> Int64? {
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return sqlite3_column_int64(stmt, i)
    }

    /// 元数据探测：每次用打开的连接现探，不做实例级缓存，避免 cc-switch 升级迁移后口径滞后。
    /// 读的是元数据表，微秒级。
    static func exists(_ db: OpaquePointer, _ sql: String) -> Bool {
        var stmt: OpaquePointer?
        var found = false
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        return found
    }
    /// 某表是否有某列（老库缺列时相关分支必须整支摘掉，否则 prepare 直接失败）。
    static func hasColumn(_ db: OpaquePointer, _ table: String, _ col: String) -> Bool {
        exists(db, "SELECT 1 FROM pragma_table_info('\(table)') WHERE name='\(col)'")
    }
}

extension UsageStore {
    /// prepare + 绑定；失败抛 .prepare(sql)。调用方负责 sqlite3_finalize（通常 defer）。
    func prepare(_ db: OpaquePointer, _ sql: String, _ binds: [SQLBind] = []) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw UsageStoreError.prepare(sql)
        }
        SQLite.bindAll(stmt, binds)
        return stmt
    }
}
