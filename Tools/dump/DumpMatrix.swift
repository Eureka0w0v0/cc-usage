import Foundation
import SQLite3

/// 一组冻结输入：库 + 两个叠加层的目录 + 固定的 cc-switch 版本。
struct DumpContext {
    static let defaultVersion = "4.0.12"

    let db: String
    let session: SessionOverlay
    let omp: OmpOverlay
    let store: UsageStore

    init(db: String, projects: String, omp ompDir: String, version: String) {
        self.db = db
        // minRefreshInterval 0：每次查询都走一遍预检和续读，和面板每个 tick 的路径相同。
        session = SessionOverlay(projectsDir: projects, minRefreshInterval: 0, ccSwitchVersion: { version })
        omp = OmpOverlay(sessionsDir: ompDir, minRefreshInterval: 0)
        store = UsageStore(path: db, overlay: session, ompOverlay: omp)
    }

    func dumpOverlays() {
        let handle = dumpOpen(db, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close(handle) }
        // 读两遍：第二遍走「什么都没变」的短路分支，结果必须和第一遍相同。
        for pass in 1...2 {
            print("== overlay pass \(pass)")
            for line in session.pendingRows(db: handle).map(DumpFormat.overlay).sorted() { print(line) }
            for line in omp.pendingRows(db: handle).map(DumpFormat.overlay).sorted() { print(line) }
        }
    }
}

/// 全部公开查询 × 时间窗 × 筛选。now 固定在冻结数据的尾部，覆盖「今天不足一天」「rollup 区」「整日边界」。
struct DumpMatrix {
    let ctx: DumpContext
    let now: Date
    let cal: Calendar

    private struct Window { let name: String; let start: Int64?; let end: Int64? }
    private struct Scope { let name: String; let app: String?; let provider: String?; let model: String? }

    init(_ ctx: DumpContext) {
        self.ctx = ctx
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        cal = c
        now = c.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12))!
    }

    private func attempt(_ label: String, _ body: () throws -> [String]) {
        do {
            let lines = try body()
            print("## \(label) (\(lines.count))")
            for line in lines { print(line) }
        } catch {
            print("## \(label) ERROR \(error)")
        }
    }

    private var windows: [Window] {
        let t = Int64(now.timeIntervalSince1970)
        let day: Int64 = 86_400
        let midnight = Int64(cal.startOfDay(for: now).timeIntervalSince1970)
        func lookback(_ days: Int) -> Int64 { UsageWindow.lookbackStart(days: days, now: now, calendar: cal) }
        return [
            Window(name: "today", start: midnight, end: t),
            Window(name: "last24h", start: t - day, end: t),
            Window(name: "last1h", start: t - 3600, end: t),
            Window(name: "lookback7", start: lookback(7), end: t),
            Window(name: "lookback30", start: lookback(30), end: t),
            Window(name: "lookback90", start: lookback(90), end: t),
            Window(name: "lookback365", start: lookback(365), end: t),
            Window(name: "wholeDays", start: midnight - 20 * day, end: midnight - 5 * day - 1),
            Window(name: "oddCross", start: t - 40 * day + 11_820, end: t - 2 * day - 18_000),
            Window(name: "rollupOnly", start: midnight - 150 * day, end: midnight - 70 * day),
            Window(name: "inverted", start: t, end: t - 3600),
            Window(name: "startOnly", start: t - 10 * day, end: nil),
            Window(name: "endOnly", start: nil, end: t - 10 * day),
            Window(name: "all", start: nil, end: nil),
        ]
    }

    /// 筛选取值从数据里来（全时段统计排前几名），省得把真实模型名写进仓库。
    private func scopes() throws -> [Scope] {
        let providers = try ctx.store.providerStats(LogQueryFilter(), calendar: cal)
        let models = try ctx.store.modelStats(LogQueryFilter(), calendar: cal)
        var out = [Scope(name: "all", app: nil, provider: nil, model: nil)]
        for app in ["claude", "codex", "omp", "gemini"] {
            out.append(Scope(name: "app:\(app)", app: app, provider: nil, model: nil))
        }
        for p in providers.prefix(3) {
            out.append(Scope(name: "provider:\(p.providerName)", app: nil, provider: p.providerName, model: nil))
        }
        for m in models.prefix(3) {
            out.append(Scope(name: "model:\(m.model)", app: nil, provider: nil, model: m.model))
        }
        if let p = providers.first, let m = models.first {
            out.append(Scope(name: "combo", app: p.appType, provider: p.providerName, model: m.model))
        }
        return out
    }

    func run() {
        ctx.dumpOverlays()
        do {
            let scopes = try scopes()
            for s in scopes {
                dumpFirstDate(s)
                for w in windows { dump(w, s) }
            }
            dumpLogFilters()
            dumpDetails()
            attempt("dataSourceBreakdown") {
                try ctx.store.dataSourceBreakdown().map {
                    "\($0.dataSource) n=\($0.requestCount) cost=\(DumpFormat.num($0.totalCost))"
                }
            }
            attempt("snapshot default") {
                let s = try ctx.store.snapshot(now: now, calendar: cal)
                return [DumpFormat.summary(s.today), DumpFormat.summary(s.cumulative),
                        DumpFormat.opt(s.lastEventAt?.timeIntervalSince1970)] + s.trend.map(DumpFormat.bucket)
            }
        } catch {
            print("## scopes ERROR \(error)")
        }
    }

    private func dumpFirstDate(_ s: Scope) {
        attempt("firstUsageDate \(s.name)") {
            let f = UsageFilter(appType: s.app, providerName: s.provider, model: s.model)
            return [DumpFormat.opt(try ctx.store.firstUsageDate(f, calendar: cal))]
        }
    }

    private func dump(_ w: Window, _ s: Scope) {
        let tag = "\(w.name) \(s.name)"
        let f = UsageFilter(start: w.start, end: w.end, appType: s.app, providerName: s.provider, model: s.model)
        let lf = LogQueryFilter(start: w.start, end: w.end, appType: s.app, providerName: s.provider, model: s.model)
        attempt("rangeSummary \(tag)") { [DumpFormat.summary(try ctx.store.rangeSummary(f, calendar: cal))] }
        attempt("rangeSummaryLogsOnly \(tag)") { [DumpFormat.summary(try ctx.store.rangeSummaryLogsOnly(f))] }
        attempt("summaryByApp \(tag)") {
            try ctx.store.summaryByApp(f).map { "\($0.appType): \(DumpFormat.summary($0.summary))" }
        }
        attempt("trendBuckets \(tag)") {
            try ctx.store.trendBuckets(filter: f, now: now, calendar: cal).map(DumpFormat.bucket)
        }
        for cumulative in [true, false] {
            attempt("snapshot cumulative=\(cumulative) \(tag)") {
                let snap = try ctx.store.snapshot(filter: f, now: now, calendar: cal, includeCumulative: cumulative)
                return [DumpFormat.summary(snap.today), DumpFormat.summary(snap.cumulative),
                        DumpFormat.opt(snap.lastEventAt?.timeIntervalSince1970)] + snap.trend.map(DumpFormat.bucket)
            }
        }
        attempt("providerStats \(tag)") { try ctx.store.providerStats(lf, calendar: cal).map(DumpFormat.provider) }
        attempt("modelStats \(tag)") { try ctx.store.modelStats(lf, calendar: cal).map(DumpFormat.model) }
        attempt("requestLogs p0 \(tag)") { try logs(lf, page: 0, size: 20) }
        attempt("requestLogs p3 \(tag)") { try logs(lf, page: 3, size: 7) }
    }

    private func logs(_ f: LogQueryFilter, page: Int, size: Int) throws -> [String] {
        let result = try ctx.store.requestLogs(f, page: page, pageSize: size)
        return ["total=\(result.total)"] + result.rows.map(DumpFormat.log)
    }

    /// 状态码筛选和分页的边角：负页码、0 与负的 pageSize 都来自桥接层，靠 requestLogs 消毒。
    private func dumpLogFilters() {
        let start = UsageWindow.lookbackStart(days: 30, now: now, calendar: cal)
        let end = Int64(now.timeIntervalSince1970)
        for status in [200, 499, 500, 404] {
            let f = LogQueryFilter(start: start, end: end, statusCode: status)
            attempt("requestLogs status=\(status)") { try logs(f, page: 0, size: 50) }
            attempt("requestLogs status=\(status) app=omp") {
                try logs(LogQueryFilter(start: start, end: end, appType: "omp", statusCode: status), page: 0, size: 50)
            }
        }
        for (page, size) in [(-1, 20), (0, 0), (0, -5), (2, 200), (100_000, 20)] {
            attempt("requestLogs page=\(page) size=\(size)") {
                try logs(LogQueryFilter(start: start, end: end), page: page, size: size)
            }
        }
    }

    private func dumpDetails() {
        do {
            let page = try ctx.store.requestLogs(LogQueryFilter(), page: 0, pageSize: 40)
            let handle = dumpOpen(ctx.db, flags: SQLITE_OPEN_READONLY)
            defer { sqlite3_close(handle) }
            let pending = ctx.session.pendingRows(db: handle) + ctx.omp.pendingRows(db: handle)
            let ids = page.rows.map(\.requestId) + pending.map(\.requestId).sorted().prefix(40) + ["no-such-request"]
            for id in ids {
                attempt("requestDetail \(id)") {
                    [try ctx.store.requestDetail(id).map(DumpFormat.log) ?? "nil"]
                }
            }
        } catch {
            print("## details ERROR \(error)")
        }
    }
}
