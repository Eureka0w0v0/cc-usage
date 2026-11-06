import Foundation

/// 「cc-switch 还没入库」的用量来源：UsageStore 的全部查询都把它们产出的行并进结果，加一种来源不用改 UsageStore。
public protocol PendingUsageSource: AnyObject {
    /// 当前全部待入库行。db 是调用方已打开的只读连接，用于查游标、定价和已入库的行。
    func pendingRows(db: OpaquePointer) -> [OverlayRow]
}

/// 待入库的一条用量，字段约定与 proxy_request_logs 相同。
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
    /// 归属的 cc-switch app_type，决定这行进哪个分组。SessionOverlay 恒为 claude；OmpOverlay 恒为 omp
    /// （与上游 v4.0.22 的 Oh My Pi 导入同一归属）。
    public var appType: String = "claude"
    /// Request Logs / Provider Stats 里的占位 provider 身份（库里没有对应 providers 行）。
    public var providerId: String = "_session"
    public var providerName: String = "Claude (Session)"
    /// 「按来源」分组键，对齐库里 proxy_request_logs.data_source 的取值空间。
    /// SessionOverlay 解析的就是 cc-switch 补录后会写成 'session_log' 的那批行，故同名；
    /// OmpOverlay 同理用上游 Oh My Pi 导入的 'omp_session'。
    public var dataSource: String = "session_log"
    /// 请求耗时（毫秒，含首字等待），0 = 没有计时——与库里 latency_ms 同一约定。会话日志没有请求
    /// 计时：SessionOverlay 按上游规则拿时间戳估（见 SessionTiming），OmpOverlay 取 OMP 自己记的 duration。
    public var latencyMs: Int64 = 0
    /// 首字时间（毫秒），推不出来为 nil——与库里 first_token_ms 同一约定。
    public var firstTokenMs: Int64? = nil
    /// 状态码，与库里 status_code 同一约定。SessionOverlay 的行恒为 200（JSONL 里只有拿到 usage 的
    /// 回复才成行）；OmpOverlay 照上游把中断 / 报错的请求记成 499 / 500，用量可以是 0。
    public var statusCode: Int64 = 200
    /// 成功 = 2xx，与 SQL 里 `status_code >= 200 AND status_code < 300` 同口径。
    public var isSuccess: Bool { (200..<300).contains(statusCode) }
    /// 失败请求的错误信息（上游截到 4096 字符），成功的行为 nil。
    public var errorMessage: String? = nil
    /// 请求时指定的模型（库里的 request_model）。nil = 与 model 相同。
    public var requestModel: String? = nil
}
