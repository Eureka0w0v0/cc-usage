import Foundation
import SQLite3

extension UsageStore {
    /// 最早有用量记录的本地日（`YYYY-MM-DD`），没有记录时为 nil。热力图据此决定要铺几段 53 周。
    ///
    /// 对齐 cc-switch v4.0.5 `get_first_usage_date`：明细表 MIN(created_at) 转本地日、rollups 表
    /// MIN(date)，两者取早；吃 app / provider / 模型筛选，**不吃时间窗、也不套跨源去重**（上游如此：
    /// 去重只会把同一笔请求换成 ±10 分钟内的另一行，跨午夜时反而把最早日推后一天）。
    /// 本 app 另把未入库的 overlay 行算进来，与其余查询同口径。
    public func firstUsageDate(_ f: UsageFilter, calendar: Calendar = .current) throws -> String? {
        let db = try openRO()
        defer { sqlite3_close(db) }
        let scope = UsageFilter(appType: f.appType, providerName: f.providerName, model: f.model)
        var days: [String] = []

        let (lc, lb) = scopeCondsL(scope)
        let detailSQL = "SELECT MIN(l.created_at) FROM proxy_request_logs l"
            + Self.providersJoinIf(scope.providerName, log: "l", provider: "p")
            + (lc.isEmpty ? "" : " WHERE " + lc.joined(separator: " AND "))
        let ls = try prepare(db, detailSQL, lb)
        if sqlite3_step(ls) == SQLITE_ROW, sqlite3_column_type(ls, 0) != SQLITE_NULL {
            days.append(Self.localDay(sqlite3_column_int64(ls, 0), calendar))
        }
        sqlite3_finalize(ls)

        let (rc, rb) = scopeCondsR(scope)
        let rollupSQL = "SELECT MIN(r.date) FROM usage_daily_rollups r"
            + Self.providersJoinIf(scope.providerName, log: "r", provider: "p2")
            + (rc.isEmpty ? "" : " WHERE " + rc.joined(separator: " AND "))
        let rs = try prepare(db, rollupSQL, rb)
        if sqlite3_step(rs) == SQLITE_ROW, sqlite3_column_type(rs, 0) != SQLITE_NULL {
            days.append(SQLite.text(rs, 0))
        }
        sqlite3_finalize(rs)

        if let earliest = overlayRows(db, scope).map(\.createdAt).min() {
            days.append(Self.localDay(earliest, calendar))
        }
        // 都是零填充的 YYYY-MM-DD，字符串序即日期序
        return days.min()
    }

    static func localDay(_ ts: Int64, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day],
                                        from: Date(timeIntervalSince1970: TimeInterval(ts)))
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
