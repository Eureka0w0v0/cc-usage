import Foundation
import SQLite3

// cc-switch 用量数据层：只读 ~/.cc-switch/cc-switch.db，聚合出「区间摘要 / 走势 / 累计」。
// 口径逐字对齐 cc-switch 的 usage_stats.rs（get_usage_summary / get_usage_summary_by_app /
// get_daily_trends）——「近期明细」proxy_request_logs 与「历史日聚合」usage_daily_rollups
// 两表合并：
//   Tokens Processed = fresh_input + output + cache_creation + cache_read
//   fresh_input      = 按行 input_token_semantics 归一（sql_helpers.rs v13）：legacy 行
//                      codex 系减 cache_read，total 行再减 cache_creation，fresh 行原样；
//                      旧库（schema <13，无该列）沿用旧口径：codex/gemini 减 cache_read
//   Cache Hit Rate   = cache_read / (fresh_input + cache_creation + cache_read)
//   summary(区间)    = logs 部分(created_at∈区间) + rollups 部分(r.date∈边界对齐后的整日区间)
//   trend ≤24h       = 小时桶，仅 proxy_request_logs（近期都在明细表）
//   trend >24h       = 天桶，本地日；proxy_request_logs(明细) 按 localtime 日 + usage_daily_rollups(历史) 合并，空桶补 0
//   防重叠           = rollups 只取「完全落在区间内的整本地日」(compute_rollup_date_bounds)，
//                      边界不足整日的那天交给 logs（按精确 created_at）——同一天不双算。
//   跨源去重         = effective_usage_log_filter：session 行若已有匹配 proxy 行则剔除。
//                      本机无 'proxy' 行，此过滤恒为 no-op（已验证），但忠实照搬。
//
// 文件划分（同一个 UsageStore 类型，按职责拆 extension）：
//   UsageStore.swift          连接 / overlay 合并 / rollup 边界 / schema 探测 / 公开入口
//   UsageStore+Summary.swift  区间汇总（logs + rollups 两表合并、按 app 分组）
//   UsageStore+Trend.swift    小时桶 / 天桶走势、最后活动时间
//   UsageStore+Tabs.swift     Request Logs / Provider Stats / Model Stats / 按来源
//   UsageSQL.swift            与 usage_stats.rs 逐字对齐的 SQL 片段
//   UsageModels.swift         对外数据模型；SQLiteSupport.swift  sqlite3 小工具

/// 线程安全：自身状态只有三个不可变引用（path / overlay / ompOverlay），每次查询独立开
/// 只读连接，两个 overlay 内部各自有锁——可安全从任意线程调用（后台 reload / 桥接队列
/// 都依赖这点）。
public final class UsageStore: @unchecked Sendable {
    public static let defaultPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".cc-switch/cc-switch.db")

    private let path: String
    private let overlay: SessionOverlay
    private let ompOverlay: OmpOverlay
    /// 两个 overlay 均可注入：测试用独立实例（空目录）隔离真实会话日志，生产默认共享单例。
    public init(path: String = UsageStore.defaultPath,
                overlay: SessionOverlay = .shared,
                ompOverlay: OmpOverlay = .shared) {
        self.path = path
        self.overlay = overlay
        self.ompOverlay = ompOverlay
    }

    // 只读打开（mode=ro，尊重 WAL，绝不写库）
    func openRO() throws -> OpaquePointer {
        var db: OpaquePointer?
        let uri = "file:\(path)?mode=ro"
        let rc = sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        guard rc == SQLITE_OK, let handle = db else {
            if let db { sqlite3_close(db) }
            throw UsageStoreError.open(rc)
        }
        sqlite3_busy_timeout(handle, 2000)
        // 装内置定价兜底表(TEMP;只读库照样可建,temp 库独立于主库)。用于给
        // cc-switch 尚未收录定价、成本被写成 0 的行现场补算。建表失败不致命：
        // costL/costR 的子查询取不到行会回落 0,即旧行为。
        ModelPricing.installFallbackTable(handle)
        return handle
    }

    // MARK: - 增量叠加（SessionOverlay + OmpOverlay）
    //
    // 两个来源性质不同：
    //   * SessionOverlay —— cc-switch 迟早会入库的 Claude Code 增量。它不在运行时新用量
    //     只存在于 ~/.claude/projects 的 JSONL 里，补录后 overlay 自动清空、数字无缝交接；
    //   * OmpOverlay —— cc-switch 压根不扫 ~/.omp/agent/sessions，永远不会收录，所以这
    //     一层是 OMP 用量在本应用里的唯一来源，不存在「等它补录」。
    //
    // 两者产出同一种 OverlayRow，各自带 appType/providerName，这里按行过滤后合并：于是
    // OMP 走 anthropic 的 Claude 请求落进 claude 分组（与 5H/Week 徽标同一笔账），走
    // custom-gateway 的 grok 落进 grokbuild 分组，不会被笼统算成一坨。
    // 两层共用 "session:<msg_id>" 命名空间，同一条响应即便都看见也只算一次。

    /// 取符合过滤条件的增量行。overlay 行 pricing_model 为空 → 有效计价模型回落 model,
    /// 与库内 session 行口径一致。
    func overlayRows(_ db: OpaquePointer, _ f: UsageFilter) -> [OverlayRow] {
        var rows = overlay.pendingRows(db: db)
        let ompRows = ompOverlay.pendingRows(db: db)
        if !ompRows.isEmpty {
            if rows.isEmpty {
                rows = ompRows                      // 常态：cc-switch 已消化完 Claude Code 日志
            } else {
                let seen = Set(rows.map(\.requestId))
                rows.append(contentsOf: ompRows.filter { !seen.contains($0.requestId) })
            }
        }
        if let at = f.appType { rows = rows.filter { $0.appType == at } }
        if let s = f.start { rows = rows.filter { $0.createdAt >= s } }
        if let e = f.end { rows = rows.filter { $0.createdAt <= e } }
        if let pn = f.providerName { rows = rows.filter { $0.providerName == pn } }
        if let m = f.model { rows = rows.filter { $0.model == m } }
        return rows
    }

    /// LogQueryFilter 版(Tabs 用):多两个维度——provider 名与状态码。
    /// overlay 行状态码恒 200;provider 展示名由行自带("Claude (Session)" / "OMP (…)")。
    func overlayLogRows(_ db: OpaquePointer, _ f: LogQueryFilter) -> [OverlayRow] {
        if let sc = f.statusCode, sc != 200 { return [] }
        return overlayRows(db, UsageFilter(start: f.start, end: f.end, appType: f.appType,
                                           providerName: f.providerName, model: f.model))
    }

    /// 把增量行累加进汇总(claude 的 fresh_input = input,无 cache 扣减)。
    func addOverlay(_ s: inout UsageSummary, _ rows: [OverlayRow]) {
        guard !rows.isEmpty else { return }
        s.requests += rows.count
        // 增量行来自已完成的响应（JSONL 里只有拿到 usage 的 assistant 消息才成行），
        // 没有失败态可言，全部计入成功。
        s.successes += rows.count
        for r in rows {
            s.input += r.input
            s.output += r.output
            s.creation += r.cacheCreation
            s.hit += r.cacheRead
            s.cost += r.totalCost
        }
    }

    // MARK: - rollup 日期边界（对齐 usage_stats.rs::compute_rollup_date_bounds）
    //
    // rollups 只纳入「完全落在区间内的整本地日」：区间起点非本地零点 → 从次日起；
    // 区间终点非本地 23:59 → 到前一日止。边界不足整日的那天由 logs(精确 created_at)覆盖，
    // 避免与 rollups 双算。isEmpty=true 时（start>end）用 "1=0" 让 rollups 部分为空。
    struct RollupBounds { var start: String?; var end: String?; var isEmpty: Bool }

    // internal（而非 private）：整日边界对齐是防双算的关键逻辑，单测直接驱动。
    func rollupDateBounds(_ startTs: Int64?, _ endTs: Int64?, _ cal: Calendar) -> RollupBounds {
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = cal.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        var startStr: String? = nil
        if let s = startTs {
            let d = Date(timeIntervalSince1970: TimeInterval(s))
            let c = cal.dateComponents([.hour, .minute, .second], from: d)
            let day0 = cal.startOfDay(for: d)
            if (c.hour ?? 0) == 0 && (c.minute ?? 0) == 0 && (c.second ?? 0) == 0 {
                startStr = fmt.string(from: day0)
            } else if let next = cal.date(byAdding: .day, value: 1, to: day0) {
                startStr = fmt.string(from: next)
            }
        }
        var endStr: String? = nil
        if let e = endTs {
            let d = Date(timeIntervalSince1970: TimeInterval(e))
            let c = cal.dateComponents([.hour, .minute], from: d)
            let day0 = cal.startOfDay(for: d)
            if (c.hour ?? 0) == 23 && (c.minute ?? 0) == 59 {
                endStr = fmt.string(from: day0)
            } else if let prev = cal.date(byAdding: .day, value: -1, to: day0) {
                endStr = fmt.string(from: prev)
            }
        }
        var empty = false
        if let a = startStr, let b = endStr, a > b { empty = true }
        return RollupBounds(start: startStr, end: endStr, isEmpty: empty)
    }

    // MARK: - schema 探测与按库选片段

    /// 本库是否有 v13 的 input_token_semantics 列。
    func hasSemantics(_ db: OpaquePointer) -> Bool {
        SQLite.hasColumn(db, "proxy_request_logs", "input_token_semantics")
    }
    /// TEMP 兜底定价表是否建成（openRO 里装的）。建不成时 costSQL 必须退化，
    /// 否则相关子查询在 prepare 阶段解析不到表名，会让每一条查询直接抛错。
    func hasFallbackPricing(_ db: OpaquePointer) -> Bool {
        SQLite.exists(db, "SELECT 1 FROM sqlite_temp_master WHERE type='table' AND name='\(ModelPricing.fallbackTable)'")
    }
    /// 按当前库 schema 选 fresh_input 表达式。
    func freshInput(_ db: OpaquePointer, _ alias: String) -> String {
        hasSemantics(db) ? Self.freshInputV13(alias) : Self.freshInputLegacy(alias)
    }
    /// 成本（明细表侧）：库里已有正成本优先，未定价行按内置表现场补算(见 ModelPricing)。
    /// 用户在 cc-switch 里改过的价永远优先，绝不被内置表覆盖。
    func costL(_ db: OpaquePointer) -> String {
        ModelPricing.costSQL(
            alias: "l",
            multiplier: "COALESCE(NULLIF(CAST(l.cost_multiplier AS REAL), 0), 1.0)",
            hasSemantics: hasSemantics(db), hasFallbackTable: hasFallbackPricing(db),
            hasRequestModel: SQLite.hasColumn(db, "proxy_request_logs", "request_model"))
    }
    /// 成本（rollups 侧）。该表没有 cost_multiplier 列，倍率恒 1。
    func costR(_ db: OpaquePointer) -> String {
        ModelPricing.costSQL(
            alias: "r", multiplier: "1.0",
            hasSemantics: hasSemantics(db), hasFallbackTable: hasFallbackPricing(db),
            hasRequestModel: SQLite.hasColumn(db, "usage_daily_rollups", "request_model"))
    }

    /// 缺省时间窗填充：start 缺省 = 本地今日零点，end 缺省 = now（snapshot / trendBuckets 共用）。
    private func resolvedFilter(_ filter: UsageFilter, now: Date, _ cal: Calendar) -> UsageFilter {
        var f = filter
        f.start = filter.start ?? Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        f.end = filter.end ?? Int64(now.timeIntervalSince1970)
        return f
    }

    // MARK: - 公开入口

    /// 按过滤条件生成快照（区间汇总 + 累计 + 走势）。
    ///
    /// includeCumulative=false 时跳过那次无时间窗的全库聚合：它要带着跨源去重的相关
    /// 子查询逐行扫完 proxy_request_logs + rollups（本机实测 ~27ms），而菜单栏路径
    /// 只读 today/trend/lastEventAt，累计值拿了就扔——默认 5 秒一刷即每秒白燃 CPU。
    /// Widget 要显示累计，保持传 true。
    public func snapshot(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current,
                         includeCumulative: Bool = true) throws -> UsageSnapshot {
        let db = try openRO()
        defer { sqlite3_close(db) }

        let f = resolvedFilter(filter, now: now, calendar)
        let range = try summary(db, f, calendar)
        let cumulative = includeCumulative
            ? try summary(db, UsageFilter(appType: filter.appType, model: filter.model), calendar)
            : UsageSummary()
        let tr = try trend(db, f, calendar)
        let lastTs = lastEventTs(db)

        return UsageSnapshot(
            today: range,
            cumulative: cumulative,
            trend: tr,
            generatedAt: now,
            lastEventAt: lastTs.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// 只算走势（get_usage_trends 桥接用）：面板每个刷新 tick 都会调，snapshot 里顺带的
    /// 「区间 + 累计」共 4 次聚合在那条路径全是白算——这里跳过。缺省窗口/粒度与 snapshot 一致。
    public func trendBuckets(filter: UsageFilter, now: Date = Date(), calendar: Calendar = .current) throws -> [TrendBucket] {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try trend(db, resolvedFilter(filter, now: now, calendar), calendar)
    }

    /// 便捷：默认「今日」快照（widget 用）。
    public func snapshot(now: Date = Date(), calendar: Calendar = .current) throws -> UsageSnapshot {
        let dayStart = Int64(calendar.startOfDay(for: now).timeIntervalSince1970)
        return try snapshot(filter: UsageFilter(start: dayStart, end: Int64(now.timeIntervalSince1970)),
                            now: now, calendar: calendar)
    }

    /// 只算某个时间窗的汇总（不含 trend），用于「近5小时 / 本周」这类常驻指标。两表合并。
    public func rangeSummary(_ filter: UsageFilter, calendar: Calendar = .current) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summary(db, filter, calendar)
    }

    /// 仅 logs 部分的区间汇总（不含 rollups）。用于 get_usage_data_sources——
    /// rollups 无 data_source 列，不该被算进「按来源」的 session_log 计数。
    public func rangeSummaryLogsOnly(_ filter: UsageFilter) throws -> UsageSummary {
        let db = try openRO()
        defer { sqlite3_close(db) }
        return try summaryLogsOnly(db, filter)
    }
}
