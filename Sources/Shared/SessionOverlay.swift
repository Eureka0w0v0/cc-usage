import Foundation
import SQLite3
import os

// 「未入库增量」只读叠加层。
//
// cc-switch 不在运行时,没人往 ~/.cc-switch/cc-switch.db 写数——本层直接增量
// 解析 ~/.claude/projects 的会话 JSONL(只读 cc-switch 记在 session_log_sync
// 里的行偏移**之后**的部分),按库里的 model_pricing 现场定价,在内存里把这批
// 「cc-switch 还没消化的用量」叠加到展示数字上。
//
// 安全性:全程零写入,cc-switch 永远是唯一写库方。等它回来把这些行正式入库,
// 本层按 request_id 精确去重、自动缩为空——数字无缝交接,绝不双算。
//
// 解析口径逐条对齐 cc-switch session_usage.rs:
//   * 文件收集三层:项目/*.jsonl、项目/会话/subagents/*.jsonl、
//     项目/会话/subagents/workflows/wf_*/​*.jsonl
//   * mtime(ns) <= session_log_sync.last_modified 的文件视为已全部消化
//   * 只认 type=="assistant" 且带 message.id + message.usage 的行
//   * 同一 message.id 去重:有 stop_reason 优先,同级取 output_tokens 更大者
//   * 任一计费维度(token) > 0 才计入;request_id = "session:" + message.id
//   * created_at 取顶层 RFC3339 timestamp,解析失败回落当前时间
//   * 定价:model_pricing 精确匹配 → 前缀匹配(候选生成含命名空间/日期
//     后缀/推理档后缀剥离,dot→dash),tokens × 每百万单价,倍率 1
//   * 缓存写入里的 1 小时部分(usage.cache_creation.ephemeral_1h_input_tokens)
//     按 cache_creation 单价 × 1.6 计(v4.0.7 #7653)。是否拆分跟着本机 CC Switch
//     的版本走,与它将来补录的值保持一致(见 ClaudeCacheWriteBilling)
//   * 未匹配到定价 → 成本 0(与 cc-switch 相同),tokens 照计
//   * 耗时 / 首字按时间戳估(v4.0.12 a0dd3b39 / 7e9b99bc / b0b6559a,见 SessionTiming):从 db 游标起读时
//     先回看游标前 256KB 建对话链,之后续读接着往里加;每读一段,这一段出现过的回复各估一次,后面的块到了
//     耗时取大、首字先到先得
//
// 已知取舍:cc-switch 入库时还会做「session 行 vs 成功 proxy 行」的指纹去重
// (should_skip_session_insert)。本机没有 proxy 行,该规则恒为空操作,叠加层
// 不复刻;若用户开启代理模式,增量在 cc-switch 补录前可能与 proxy 行短暂并存。

public struct OverlayRow: Sendable {
    public var requestId: String
    public var model: String
    public var createdAt: Int64
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheCreation: Int64
    /// 真实消耗 Tokens，与 `UsageStore.realTotalTokens` 的 SQL 同口径。两个 overlay 的
    /// `input` 都是新增输入（JSONL 里缓存单列），所以四项直接相加，不做 cache 扣减。
    public var realTotalTokens: Int64 { input + output + cacheCreation + cacheRead }
    public var inputCost: Double
    public var outputCost: Double
    public var cacheReadCost: Double
    public var cacheCreationCost: Double
    public var totalCost: Double
    var hasStopReason: Bool
    var sourceFile: String
    /// 归属的 cc-switch app_type，决定这行进哪个分组。SessionOverlay 恒为 claude；
    /// OmpOverlay 一个日志里混着多家 provider，逐行分流（见 OmpOverlay.classify）。
    public var appType: String = "claude"
    /// Request Logs / Provider Stats 里的占位 provider 身份（库里没有对应 providers 行）。
    public var providerId: String = "_session"
    public var providerName: String = "Claude (Session)"
    /// 「按来源」分组键，对齐库里 proxy_request_logs.data_source 的取值空间。
    /// SessionOverlay 解析的就是 cc-switch 补录后会写成 'session_log' 的那批行，故同名；
    /// OmpOverlay 是 cc-switch 完全不导入的来源，单列 'omp_session' 不与上游取值冲突。
    public var dataSource: String = "session_log"
    /// 请求耗时（毫秒，含首字等待），0 = 没有计时——与库里 latency_ms 同一约定。会话日志没有请求
    /// 计时：SessionOverlay 按上游规则拿时间戳估（见 SessionTiming），OmpOverlay 取 OMP 自己记的 duration。
    public var latencyMs: Int64 = 0
    /// 首字时间（毫秒），推不出来为 nil——与库里 first_token_ms 同一约定。
    public var firstTokenMs: Int64? = nil
}

/// 两个 overlay 共用的逐行扫描原语。
enum JSONLScan {
    /// 计费行的必要标记。会话日志里 tool_call / thinking / custom 之类的行占七成以上，
    /// 它们不可能含 "usage"——先做一次字节子串命中再决定要不要 JSONSerialization。
    static let usageMarker = Data(#""usage""#.utf8)
    /// 对话链节点的必要标记：只有带顶层 uuid 的行才进对话链（估请求起点用，见 ClaudeTimingTracker）。
    /// api-request-blob 之类不带它的大行（本机实测约占日志两成字节）就不必解析。
    static let uuidMarker = Data(#""uuid""#.utf8)

    static func hasUsageMarker(_ p: UnsafeRawPointer, _ len: Int) -> Bool {
        contains(usageMarker, p, len)
    }

    static func hasUUIDMarker(_ p: UnsafeRawPointer, _ len: Int) -> Bool {
        contains(uuidMarker, p, len)
    }

    private static func contains(_ marker: Data, _ p: UnsafeRawPointer, _ len: Int) -> Bool {
        marker.withUnsafeBytes { m in
            memmem(p, len, m.baseAddress!, m.count) != nil
        }
    }

    /// 一行 JSON → 顶层对象。用 bytesNoCopy 包给 JSONSerialization，省掉每行一次的缓冲区拷贝（调用方保证
    /// p 在调用期间有效）。解析不了或不是对象的行返回 nil：半行、坏行跳过即可，与上游 `Err(_) => continue` 相同。
    static func object(_ p: UnsafeRawPointer, _ len: Int) -> NSDictionary? {
        let line = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: len, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: line)) as? NSDictionary
    }

    /// proxy_request_logs 的入库水位：行数 + 最新时间戳。两个 overlay 的预检共用。
    /// 补录会让两者都涨、清理旧日志会让行数掉——只要这对数不变，就说明库里没有
    /// 新行，pruneRowsAlreadyInDB 不可能产生新命中，那趟全量 IN 查询可以整个省掉。
    /// 本机实测 0.21ms（换掉的是 100ms 级的一整趟扫描）。
    static func dbWatermark(_ db: OpaquePointer) -> Watermark? {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*), COALESCE(MAX(created_at), 0) FROM proxy_request_logs"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Watermark(rows: sqlite3_column_int64(stmt, 0), maxTs: sqlite3_column_int64(stmt, 1))
    }

    struct Watermark: Equatable { var rows: Int64; var maxTs: Int64 }
}

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
        if primed, dirMtimes.allSatisfy({ Self.mtimeNs($0.path) == $0.mtime }) { return cached }
        let r = enumerate()
        cached = r.files
        // 目录不存在 → 记 0；将来被创建时 mtime 变为真值，缓存自然失效。
        dirMtimes = r.dirs.map { (path: $0, mtime: Self.mtimeNs($0) ?? 0) }
        primed = true
        return cached
    }

    private static func mtimeNs(_ path: String) -> Int64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
    }
}

public final class SessionOverlay {
    public static let shared = SessionOverlay()

    private static let log = Logger(subsystem: "com.ganxing.ccusage", category: "overlay")

    /// 两次真实扫描的最小间隔:一个刷新 tick 内 UsageStore 的多个查询共享同一次扫描。
    private let minRefreshInterval: TimeInterval
    /// 定价表缓存时长(cc-switch 更新价格后最迟 5 分钟被叠加层看到)。
    private let pricingTTL: TimeInterval
    private let ccSwitchVersion: () -> String?

    private let lock = NSLock()
    private var rows: [String: OverlayRow] = [:]   // requestId → 待入库行
    private var lastRefresh: Date?

    /// cc-switch 记在 session_log_sync 里的单文件消化进度。
    ///
    /// cc-switch v3.20.1（schema v18）把 Claude 路径改成字节游标，并且**把
    /// `last_line_offset` 固定写 0**（上游原话：「字节游标语义下行号不再维护，
    /// 置 0 明确表示行号游标不可用」）。于是这张表会长期三态并存：
    ///
    ///   A 旧库      —— 没有 last_byte_offset 列，行号真实
    ///   B 已升级未重扫 —— 有列但值为 NULL（mtime 门让未变化的文件不写游标），行号真实
    ///   C 新版写过   —— 字节位真实（**可能合法地等于 0**），行号恒 0
    ///
    /// 判定只能靠「列在不在 + 值是不是 NULL」。**绝不可用 COALESCE(byte,0)**：
    /// 0 是 C 态的合法字节位，那样会把 B 态误判成「从头读」——而从头读正是
    /// 双算的源头（30 天前的明细已被 rollup 删除，request_id 去重对其失明）。
    private struct SyncCursor {
        var lastModified: Int64
        var lineOffset: Int64    // 仅 byteOffset == nil 时有效
        var byteOffset: Int64?   // nil = 行号游标(A/B 态)；非 nil = 字节游标(C 态)

        static let empty = SyncCursor(lastModified: 0, lineOffset: 0, byteOffset: nil)

        /// 两个游标是否指向同一进度（判断 cc-switch 有没有推进过）。
        func samePosition(as other: SyncCursor) -> Bool {
            byteOffset == other.byteOffset && lineOffset == other.lineOffset
        }
    }

    /// 进程内续读进度(建立在 session_log_sync 游标之上)。
    private struct FileMark {
        var mtimeNs: Int64        // 上次读完时的文件 mtime(ns)
        var bytesRead: Int64      // 已消费到的字节位置(完整行边界)
        var linesRead: Int64      // 已消费的行数(含 db 游标内跳过的行)
        var dbCursor: SyncCursor  // 建立本进度时 session_log_sync 的游标
        /// 从 db 游标起读到现在的对话链与回复计时(见 scanFileLocked)。续读接着往里加,进度重建时一起
        /// 重建;内存随本文件未入库的行数增长,每行约百字节。
        var timing: ClaudeTimingTracker
    }
    private var marks: [String: FileMark] = [:]

    private struct Pricing { var input: Double; var output: Double; var cacheRead: Double; var cacheCreation: Double }
    private var pricingExact: [String: Pricing] = [:]
    private var pricingIds: [String] = []          // 前缀匹配用(短 id 优先)
    private var pricingLoadedAt: Date?
    /// 1 小时缓存写入是否按 1.6 倍计，随定价一起按 TTL 重判。nil = 还没判过；
    /// 每轮真扫都先经 loadPricingIfStale 判定，ingest 时不会是 nil。
    private var oneHourRate: Bool?

    /// 上一次真正扫完时的库水位，供预检短路比对（见 nothingChangedLocked）。
    private var lastWatermark: JSONLScan.Watermark?

    /// 文件列表缓存（只在目录树形状变了才重新枚举）。始终在 lock 内使用。
    private let dirCache = DirListCache()

    /// 读失败、已经记过日志的文件：读失败时进度不动、每个刷新 tick 都会重试，日志每个文件只记一次，
    /// 读成功一次就移出。
    private var unreadable: Set<String> = []

    private let projectsDir: String

    /// minRefreshInterval 可注入：测试传 0 即可免掉「睡过节流窗口」的等待。
    public init(projectsDir: String =
        (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects"),
        minRefreshInterval: TimeInterval = 2.0,
        pricingTTL: TimeInterval = 300,
        ccSwitchVersion: @escaping () -> String? = { ClaudeCacheWriteBilling.installedCCSwitchVersion() }) {
        self.projectsDir = projectsDir
        self.minRefreshInterval = minRefreshInterval
        self.pricingTTL = pricingTTL
        self.ccSwitchVersion = ccSwitchVersion
    }

    // MARK: - 对外入口

    /// 返回当前「cc-switch 尚未入库」的用量行。db 为调用方已打开的只读连接,
    /// 用于读 session_log_sync / model_pricing / 已存在的 request_id。
    public func pendingRows(db: OpaquePointer) -> [OverlayRow] {
        lock.lock()
        defer { lock.unlock() }
        if let last = lastRefresh, Date().timeIntervalSince(last) < minRefreshInterval {
            return Array(rows.values)
        }
        refreshLocked(db)
        lastRefresh = Date()
        return Array(rows.values)
    }

    // MARK: - 扫描

    private func refreshLocked(_ db: OpaquePointer) {
        let sync = loadSyncTable(db)
        let files = collectJSONLFiles()

        // 刷新 tick(默认 5s)比节流窗(2s)长，意味着每一轮都会穿透节流真跑一次
        // refresh——而绝大多数轮次里文件和库都纹丝没动。先用一次全量 stat 问清楚
        // 「这趟有没有事可做」，没有就整趟省掉(含 vanished 集合运算与全量 prune)。
        if nothingChangedLocked(files, sync, db) { return }

        loadPricingIfStale(db)
        var seenPaths = Set<String>()
        for path in files {
            seenPaths.insert(path)
            // 每个文件一个 autorelease 池（同 OmpOverlay）：JSONSerialization 的
            // Foundation 对象否则要堆到整趟扫描结束，实测本层峰值常驻 96MB。
            autoreleasepool { scanFileLocked(path, dbState: sync[path] ?? .empty) }
        }
        // 文件消失(会话被清理)→ 其待入库行一并移除
        let vanished = Set(marks.keys).subtracting(seenPaths)
        if !vanished.isEmpty {
            for p in vanished { marks.removeValue(forKey: p) }
            rows = rows.filter { !vanished.contains($0.value.sourceFile) }
        }
        pruneRowsAlreadyInDB(db)
        lastWatermark = JSONLScan.dbWatermark(db)
    }

    /// 本轮扫描会不会产生任何变化？代价只有一次全量 stat(本机 1095 文件 ~1.7ms)
    /// 加一次水位查询(0.21ms)，换掉的是逐文件 open/seek/read、vanished 集合运算与
    /// 对全部 rows 的分批 IN 查询。
    ///
    /// 判定逐条对齐 scanFileLocked 的「无事发生」分支，任一不成立就走完整流程：
    ///   * marks 里有记录的文件 —— 必须仍未被 cc-switch 消化(否则要清掉它的行)，
    ///     且 db 偏移、已读字节、mtime 三者都没动(否则要续读或重建)；
    ///   * marks 里没有的文件 —— 必须是「已被消化」那类(scanFileLocked 对它是
    ///     纯 no-op)，否则就是新出现的增量，要真扫；
    ///   * marks 的每个 key 都还在 files 里 —— 否则有文件消失，要走 vanished 清理；
    ///   * 库水位没动 —— 否则 cc-switch 补录过，prune 可能有新命中。
    private func nothingChangedLocked(_ files: [String],
                                      _ sync: [String: SyncCursor],
                                      _ db: OpaquePointer) -> Bool {
        guard let wm = lastWatermark else { return false }   // 首轮必须真扫
        var live = 0
        for path in files {
            guard let st = statNanos(path) else { return false }
            let dbState = sync[path] ?? .empty
            if let m = marks[path] {
                live += 1
                guard st.mtimeNs > dbState.lastModified,
                      m.dbCursor.samePosition(as: dbState),
                      m.bytesRead <= st.size,
                      m.mtimeNs == st.mtimeNs else { return false }
            } else if st.mtimeNs > dbState.lastModified {
                return false
            }
        }
        guard live == marks.count else { return false }
        return JSONLScan.dbWatermark(db) == wm
    }

    /// 按 db 游标的形态决定本文件的读取起点(见 SyncCursor 的三态说明)。
    private func startPoint(_ cursor: SyncCursor, fileSize: Int64)
        -> (startBytes: Int64, skipLines: Int64) {
        guard let b = cursor.byteOffset else {
            return (0, cursor.lineOffset)   // A/B 态：旧行号路径，逐行跳过前 N 行
        }
        // C 态：直接 seek 到字节位，行号(恒 0)一概不看。越界=外部截断/重写，
        // 钳到 EOF —— 对齐上游「游标钉至 EOF、不重放旧区间」。**绝不回退到 0
        // 重扫**：30 天前的明细已被 rollup 删除，request_id 去重对其失明，
        // 重扫会把那段历史再叠加一遍，与 usage_daily_rollups 双算。
        return (min(max(0, b), fileSize), 0)
    }

    /// 扫描单个文件的新增部分(对齐 sync_single_file)。
    private func scanFileLocked(_ path: String, dbState: SyncCursor) {
        guard let st = statNanos(path) else { return }

        // cc-switch 已消化整个文件 → 丢掉本文件全部待入库行
        if st.mtimeNs <= dbState.lastModified {
            if marks.removeValue(forKey: path) != nil {
                rows = rows.filter { $0.value.sourceFile != path }
            }
            return
        }

        guard var plan = readPlanLocked(path, st, dbState),
              let data = readTailLocked(path, from: plan.startBytes - plan.seedLen) else { return }
        // 放掉 marks 里那份对话链的引用:plan.tracker 成了唯一持有者,往里加行时才不会整份写时复制
        marks[path]?.timing = ClaudeTimingTracker()
        let consumedBytes = consumeLocked(data, &plan, path: path)
        marks[path] = FileMark(mtimeNs: st.mtimeNs, bytesRead: consumedBytes,
                               linesRead: plan.linesRead, dbCursor: dbState, timing: plan.tracker)
    }

    /// 本文件这一轮从哪读起。
    private struct ReadPlan {
        var startBytes: Int64
        /// 已消费的行数(含 db 游标内跳过的行)
        var linesRead: Int64
        /// 旧行号游标(A/B 态)要跳过的前 N 行
        var skipLines: Int64
        /// 读取起点前要回看的字节数
        var seedLen: Int64
        var tracker: ClaudeTimingTracker
    }

    /// 续读接着自己的进度和对话链;否则(首次见到、db 游标推进、文件被重写)从 db 游标起读,先回看游标前
    /// 256KB。内容没变返回 nil。
    ///
    /// 对话链跨轮保留:每个刷新 tick 都续读,起点行(常是带截图的大工具结果)上一轮读走、回复这一轮
    /// 才到是常态,每轮只靠 256KB 回看的话,窗口会落在大行中间、找不到起点。所以只在从 db 游标起读时
    /// 回看,之后这一份一直用到进度重建——等于「从游标一次读到现在」,与 cc-switch 隔一阵一次性导入时
    /// 看到的相同。
    private func readPlanLocked(_ path: String, _ st: (mtimeNs: Int64, size: Int64),
                                _ dbState: SyncCursor) -> ReadPlan? {
        if let m = marks[path], m.dbCursor.samePosition(as: dbState), m.bytesRead <= st.size {
            // 在自己的进度上续读(不必重数 db 游标内的行)
            if m.mtimeNs == st.mtimeNs { return nil }   // 内容未变
            return ReadPlan(startBytes: m.bytesRead, linesRead: m.linesRead, skipLines: 0, seedLen: 0,
                            tracker: m.timing)
        }
        // marks 无记录 = 首次见到该文件，rows 里必然没有它的行。冷启动时若每个
        // 文件都白跑一次全量 filter，等于把整个结果字典重建上千遍
        // （~/.claude/projects 本机 1092 个文件，比 OMP 那边语料更大）。
        if marks[path] != nil {
            // db 游标推进(cc-switch 刚跑过)或文件被重写 → 从头重建本文件的增量
            rows = rows.filter { $0.value.sourceFile != path }
        }
        let (startBytes, skipLines) = startPoint(dbState, fileSize: st.size)
        // 回看窗口:db 游标前最多 256KB,只建对话链和回复计时、不计用量(对齐 read_chain_seed)。
        // 旧行号游标(A/B 态)的首读从文件头开始,被跳过的行上游只数不解析,这里同样不回看。
        return ReadPlan(startBytes: startBytes, linesRead: 0, skipLines: skipLines,
                        seedLen: min(startBytes, SessionTiming.chainSeedBytes), tracker: ClaudeTimingTracker())
    }

    /// 从 offset 读到文件尾。打开、定位或读取失败返回 nil:进度不动,下个 tick 从同一位置重试——定位失败
    /// 绝不能接着从文件头读,那会把已消化的行再算一遍。日志每个文件只记一次。
    private func readTailLocked(_ path: String, from offset: Int64) -> Data? {
        do {
            guard let fh = FileHandle(forReadingAtPath: path) else { throw CocoaError(.fileReadUnknown) }
            defer { try? fh.close() }
            try fh.seek(toOffset: UInt64(offset))
            let data = try fh.readToEnd() ?? Data()
            unreadable.remove(path)
            return data
        } catch {
            if unreadable.insert(path).inserted {
                Self.log.error("会话日志读取失败，下一轮重试: \(path, privacy: .private) \(error.localizedDescription, privacy: .public)")
            }
            return nil
        }
    }

    /// 读到的这一段:先喂回看窗口,再逐行消费,读完按这一段出现过的回复估计时。返回消费到的字节位置。
    ///
    /// 只消费完整行(带 \n);写了一半的最后一行留到下个 tick,
    /// 避免把残缺 JSON 当作「已处理」而永久丢失(严于上游,口径不受影响)。
    ///
    /// 走裸指针 + 字节预筛:这里只需要找换行与子串,没有一处用得上 Data
    /// 的语义,而 Data 的下标/切片在大体量日志上开销压倒性(同一批文件实测逐行
    /// 切分 377ms vs memchr 88ms)。
    private func consumeLocked(_ data: Data, _ plan: inout ReadPlan, path: String) -> Int64 {
        var consumedBytes = plan.startBytes
        /// 这一段读到的计费回复 → 代表行带不带 stop_reason(同一回复里有一块带了就算:上游按
        /// message.id 去重时 stop_reason 优先)
        var seen: [String: Bool] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let total = raw.count
            let bodyStart = Int(plan.seedLen)
            if plan.seedLen > 0 {
                Self.feedLookBehind(base, count: bodyStart, startsMidFile: plan.startBytes > plan.seedLen,
                                    into: &plan.tracker)
            }
            var off = bodyStart
            while off < total {
                guard let nl = memchr(base + off, 0x0A, total - off) else { break }
                let lineBase = base + off
                let lineLen = UnsafeRawPointer(nl) - lineBase
                off += lineLen + 1
                consumedBytes = plan.startBytes + Int64(off - bodyStart)
                plan.linesRead += 1
                // db 偏移内的行 cc-switch 已消化:只数,不解析
                if plan.skipLines > 0 && plan.linesRead <= plan.skipLines { continue }
                guard lineLen > 0 else { continue }
                consumeLineLocked(lineBase, lineLen, path: path, tracker: &plan.tracker, seen: &seen)
            }
        }
        applyTimingLocked(plan.tracker, seen)
        return consumedBytes
    }

    /// 一行:带 "usage" 的(计费)整行解析、记进对话链、入账;只带 "uuid" 的(对话链)只记进对话链,
    /// 见 recordChainLine;两样都不带的不解析。
    private func consumeLineLocked(_ p: UnsafeRawPointer, _ len: Int, path: String,
                                   tracker: inout ClaudeTimingTracker, seen: inout [String: Bool]) {
        guard JSONLScan.hasUsageMarker(p, len) else {
            Self.recordChainLine(p, len, into: &tracker)
            return
        }
        guard let obj = JSONLScan.object(p, len) else { return }
        tracker.record(obj)
        if let reply = ingestLocked(obj, path: path) {
            seen[reply.messageId] = (seen[reply.messageId] ?? false) || reply.hasStop
        }
    }

    /// 回看窗口里的行只记对话链和回复计时（对齐 read_chain_seed）。窗口不是从文件头开始时第一段多半是半行，
    /// 丢掉；最后一段是读取起点前的那一行之后的部分（起点在行边界上时为空）。
    private static func feedLookBehind(_ base: UnsafeRawPointer, count: Int, startsMidFile: Bool,
                                       into tracker: inout ClaudeTimingTracker) {
        var off = 0
        if startsMidFile {
            guard let nl = memchr(base, 0x0A, count) else { return }
            off = UnsafeRawPointer(nl) - base + 1
        }
        while off < count {
            let lineBase = base + off
            let lineLen = memchr(lineBase, 0x0A, count - off).map { UnsafeRawPointer($0) - lineBase } ?? (count - off)
            off += lineLen + 1
            guard lineLen > 0 else { continue }
            guard JSONLScan.hasUsageMarker(lineBase, lineLen) else {
                recordChainLine(lineBase, lineLen, into: &tracker)
                continue
            }
            if let obj = JSONLScan.object(lineBase, lineLen) { tracker.record(obj) }
        }
    }

    /// 不带用量的行只为建对话链：带 uuid 的整行解析后记进对话链。
    private static func recordChainLine(_ p: UnsafeRawPointer, _ len: Int,
                                        into tracker: inout ClaudeTimingTracker) {
        guard JSONLScan.hasUUIDMarker(p, len), let obj = JSONLScan.object(p, len) else { return }
        tracker.record(obj)
    }

    /// 这一段读到的回复各按上游规则估一次计时，并进它们的行（refresh_session_log_entry_on_conn 的合并规则，
    /// 见 SessionTiming.merged）。行可能是这一段新建的，也可能是前几段留下、这一段又读到了它后面的块。
    private func applyTimingLocked(_ tracker: ClaudeTimingTracker, _ seen: [String: Bool]) {
        for (messageId, hasStop) in seen {
            let requestId = Self.requestId(messageId)
            guard var row = rows[requestId] else { continue }
            let merged = SessionTiming.merged(latencyMs: row.latencyMs, firstTokenMs: row.firstTokenMs,
                                              with: tracker.estimate(messageId: messageId, hasStopReason: hasStop))
            row.latencyMs = merged.latencyMs
            row.firstTokenMs = merged.firstTokenMs
            rows[requestId] = row
        }
    }

    /// 与 cc-switch 补录时写的 request_id 同一命名空间（SESSION_REQUEST_ID_PREFIX + message.id）。
    private static func requestId(_ messageId: String) -> String { "session:" + messageId }

    /// 单行 JSON → 一条待入库行。不命中计费条件时返回 nil；命中时返回这一行所属的回复（message.id、
    /// 这一行带不带 stop_reason），读完这一段后据此估计时。
    ///
    /// 走 NSDictionary 而非 `as? [String: Any]`:后者会把整棵子树递归桥接成 Swift
    /// 字典,而 message 里挂着整段回复正文——我们只要几个标量字段。
    private func ingestLocked(_ obj: NSDictionary, path: String) -> (messageId: String, hasStop: Bool)? {
        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? NSDictionary,
              let msgId = message["id"] as? String,
              let usage = message["usage"] as? NSDictionary
        else { return nil }

        let input = int64(usage["input_tokens"])
        let output = int64(usage["output_tokens"])
        let cacheRead = int64(usage["cache_read_input_tokens"])
        let cacheCreation = int64(usage["cache_creation_input_tokens"])
        // 缓存写入里 1 小时那部分（对齐上游 claude_cache_creation_1h_tokens）
        let cacheCreation1h = int64((usage["cache_creation"] as? NSDictionary)?["ephemeral_1h_input_tokens"])
        // 任一计费维度 > 0 才计入(对齐上游 has_billable_tokens)
        guard input > 0 || output > 0 || cacheRead > 0 || cacheCreation > 0 else { return nil }

        let model = (message["model"] as? String) ?? "unknown"
        let hasStop = (message["stop_reason"] as? String) != nil
        let ts = (obj["timestamp"] as? String).flatMap(ISO8601Lenient.epochSeconds)
            ?? Int64(Date().timeIntervalSince1970)
        let requestId = Self.requestId(msgId)
        let reply = (messageId: msgId, hasStop: hasStop)

        // message.id 去重:stop_reason 优先,同级取 output 更大者(对齐上游)。替换出来的新行带上
        // 先前估出的计时,这一段读完后再并上这一轮的(applyTimingLocked)
        var timing = (latencyMs: Int64(0), firstTokenMs: Int64?.none)
        if let old = rows[requestId] {
            let replace = (hasStop && !old.hasStopReason)
                || (hasStop == old.hasStopReason && output > old.output)
            if !replace { return reply }
            timing = (old.latencyMs, old.firstTokenMs)
        }

        let c = costs(model: model, input: input, output: output, cacheRead: cacheRead,
                      cacheCreation: cacheCreation, cacheCreation1h: cacheCreation1h)
        rows[requestId] = OverlayRow(
            requestId: requestId, model: model, createdAt: ts,
            input: input, output: output, cacheRead: cacheRead, cacheCreation: cacheCreation,
            inputCost: c.input, outputCost: c.output, cacheReadCost: c.cacheRead, cacheCreationCost: c.cacheCreation,
            totalCost: c.input + c.output + c.cacheRead + c.cacheCreation,
            hasStopReason: hasStop, sourceFile: path,
            latencyMs: timing.latencyMs, firstTokenMs: timing.firstTokenMs
        )
        return reply
    }

    /// 四项成本:tokens × 每百万单价,倍率 1;缓存写入里 1 小时那部分按 ClaudeCacheWriteBilling 计。
    /// 查不到定价全为 0(与 cc-switch 相同)。
    private func costs(model: String, input: Int64, output: Int64, cacheRead: Int64,
                       cacheCreation: Int64, cacheCreation1h: Int64)
        -> (input: Double, output: Double, cacheRead: Double, cacheCreation: Double) {
        guard let p = findPricing(model) else { return (0, 0, 0, 0) }
        return (Double(input) * p.input / 1_000_000,
                Double(output) * p.output / 1_000_000,
                Double(cacheRead) * p.cacheRead / 1_000_000,
                ClaudeCacheWriteBilling.cost(tokens: cacheCreation, oneHourTokens: cacheCreation1h,
                                             pricePerMillion: p.cacheCreation, oneHourRate: oneHourRate ?? true))
    }

    /// 已被 cc-switch 入库的行从叠加层剔除(request_id 精确去重的兜底)。
    private func pruneRowsAlreadyInDB(_ db: OpaquePointer) {
        let ids = Array(rows.keys)
        guard !ids.isEmpty else { return }
        for chunk in stride(from: 0, to: ids.count, by: 400).map({ Array(ids[$0..<min($0 + 400, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let sql = "SELECT request_id FROM proxy_request_logs WHERE request_id IN (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (i, id) in chunk.enumerated() {
                sqlite3_bind_text(stmt, Int32(i + 1), id, -1, SQLITE_TRANSIENT_DEST)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) {
                    rows.removeValue(forKey: String(cString: c))
                }
            }
        }
    }

    // MARK: - 文件收集(对齐 collect_jsonl_files:固定三层,不递归)

    private func collectJSONLFiles() -> [String] {
        dirCache.files {
            let fm = FileManager.default
            var files: [String] = []
            var dirs: [String] = [projectsDir]
            guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir) else { return (files, dirs) }
            for proj in projects {
                let projPath = (projectsDir as NSString).appendingPathComponent(proj)
                guard isDirectory(projPath) else { continue }
                dirs.append(projPath)
                guard let subs = try? fm.contentsOfDirectory(atPath: projPath) else { continue }
                for sub in subs {
                    let subPath = (projPath as NSString).appendingPathComponent(sub)
                    if sub.hasSuffix(".jsonl") {
                        files.append(subPath)                    // 主会话
                    } else if isDirectory(subPath) {
                        // 会话目录本身也要记：它下面「有没有长出 subagents/」这个判断
                        // 就依赖它的内容，漏记会让新开的子 agent 一直看不见。
                        dirs.append(subPath)
                        let subagents = (subPath as NSString).appendingPathComponent("subagents")
                        guard isDirectory(subagents) else { continue }
                        dirs.append(subagents)
                        appendJSONLChildren(subagents, &files)   // 子 agent
                        let workflows = (subagents as NSString).appendingPathComponent("workflows")
                        if isDirectory(workflows),
                           let wfs = try? fm.contentsOfDirectory(atPath: workflows) {
                            dirs.append(workflows)
                            for wf in wfs {                      // Workflow 子 agent
                                let wfPath = (workflows as NSString).appendingPathComponent(wf)
                                if isDirectory(wfPath) {
                                    dirs.append(wfPath)
                                    appendJSONLChildren(wfPath, &files)
                                }
                            }
                        }
                    }
                }
            }
            return (files, dirs)
        }
    }

    private func appendJSONLChildren(_ dir: String, _ files: inout [String]) {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for e in entries where e.hasSuffix(".jsonl") {
            files.append((dir as NSString).appendingPathComponent(e))
        }
    }

    private func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// mtime 纳秒 + 文件大小(与上游 metadata_modified_nanos 同精度,用 stat 拿真 ns)。
    private func statNanos(_ path: String) -> (mtimeNs: Int64, size: Int64)? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        let ns = Int64(st.st_mtimespec.tv_sec) &* 1_000_000_000 &+ Int64(st.st_mtimespec.tv_nsec)
        return (mtimeNs: ns, size: Int64(st.st_size))
    }

    // MARK: - session_log_sync / model_pricing

    /// 某表是否有某列。老库(schema<18)没有字节游标列，SQL 必须整支换掉——
    /// 直接 SELECT 不存在的列会让 prepare 失败，整张表读不出来。
    private func hasColumn(_ db: OpaquePointer, _ table: String, _ col: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM pragma_table_info('\(table)') WHERE name='\(col)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    private func loadSyncTable(_ db: OpaquePointer) -> [String: SyncCursor] {
        var out: [String: SyncCursor] = [:]
        var stmt: OpaquePointer?
        // schema v18 起才有 last_byte_offset；老库整支摘掉该列(见 SyncCursor 的三态说明)。
        let hasByteCol = hasColumn(db, "session_log_sync", "last_byte_offset")
        let sql = hasByteCol
            ? "SELECT file_path, last_modified, last_line_offset, last_byte_offset FROM session_log_sync"
            : "SELECT file_path, last_modified, last_line_offset FROM session_log_sync"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            // NULL 与 0 必须分开：0 是 C 态的合法字节位，NULL 才表示「没有字节游标」。
            let byteOffset: Int64? = (hasByteCol && sqlite3_column_type(stmt, 3) != SQLITE_NULL)
                ? sqlite3_column_int64(stmt, 3) : nil
            out[String(cString: c)] = SyncCursor(
                lastModified: sqlite3_column_int64(stmt, 1),
                lineOffset: sqlite3_column_int64(stmt, 2),
                byteOffset: byteOffset)
        }
        return out
    }

    private func loadPricingIfStale(_ db: OpaquePointer) {
        if let at = pricingLoadedAt, Date().timeIntervalSince(at) < pricingTTL { return }
        refreshBillingRuleLocked()
        var exact: [String: Pricing] = [:]
        var stmt: OpaquePointer?
        let sql = """
        SELECT model_id, input_cost_per_million, output_cost_per_million,
               cache_read_cost_per_million, cache_creation_cost_per_million FROM model_pricing
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: c)
            func col(_ i: Int32) -> Double {
                sqlite3_column_text(stmt, i).flatMap { Double(String(cString: $0)) } ?? 0
            }
            exact[id] = Pricing(input: col(1), output: col(2), cacheRead: col(3), cacheCreation: col(4))
        }
        pricingExact = exact
        pricingIds = exact.keys.sorted { $0.count < $1.count }   // 前缀匹配取最短命中,对齐 LENGTH ASC
        pricingLoadedAt = Date()
    }

    /// 重判 1 小时缓存写入的计价口径。口径变了（多半是 CC Switch 刚升到 v4.0.7+）就清空
    /// 已叠加的行和续读进度：那些行是按旧口径定的价，本轮从 cc-switch 游标处整体重扫。
    private func refreshBillingRuleLocked() {
        let rule = ClaudeCacheWriteBilling.usesOneHourRate(ccSwitchVersion: ccSwitchVersion())
        if let old = oneHourRate, old != rule {
            rows.removeAll()
            marks.removeAll()
        }
        oneHourRate = rule
    }

    // MARK: - 定价匹配(对齐 find_model_pricing_row:候选精确匹配 → 前缀匹配)

    private func findPricing(_ modelId: String) -> Pricing? {
        let candidates = ModelId.pricingCandidates(modelId)
        for c in candidates {
            if let p = pricingExact[c] { return p }
        }
        for c in candidates where ModelId.shouldTryPrefixMatch(c) {
            // model_id LIKE 'c-%' ORDER BY LENGTH LIMIT 1(pricingIds 已按长度升序)
            if let hit = pricingIds.first(where: { $0.hasPrefix(c + "-") }) {
                return pricingExact[hit]
            }
        }
        // db 没有该模型(上游 seed 尚未跟进新模型)→ 回落内置表。库里已有的定价
        // 永远优先，所以用户在 cc-switch 改过的价不会被这里覆盖。
        if let b = ModelPricing.lookup(modelId) {
            return Pricing(input: b.input, output: b.output,
                           cacheRead: b.cacheRead, cacheCreation: b.cacheCreation)
        }
        return nil
    }

    // MARK: - 小工具

    private func int64(_ v: Any?) -> Int64 {
        if let n = v as? NSNumber { return n.int64Value }
        return 0
    }

}
