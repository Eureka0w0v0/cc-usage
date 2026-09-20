import Foundation

// MARK: - 数据模型

public struct UsageSummary: Sendable {
    public var requests: Int = 0
    public var successes: Int = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var creation: Int64 = 0
    public var hit: Int64 = 0
    public var cost: Double = 0

    /// 成功率（百分比）。对齐 usage_stats.rs：无请求时返回 **0** 而非 100。
    /// 早前桥接层给面板直接写死 100，属于潜伏的错值——只是当前 embed 不渲染
    /// summary 的这个字段（只有 ProviderStatsTable 渲染成功率，走的是另一条路）。
    public var successRate: Double {
        requests > 0 ? Double(successes) / Double(requests) * 100 : 0
    }
    public var tokensProcessed: Int64 { input + output + creation + hit }
    public var cacheHitRate: Double {
        let denom = Double(input + creation + hit)
        return denom > 0 ? Double(hit) / denom : 0
    }
}

public struct TrendBucket: Sendable {
    public var startTs: Int64
    public var requestCount: Int = 0
    public var input: Int64 = 0
    public var output: Int64 = 0
    public var creation: Int64 = 0
    public var hit: Int64 = 0
    public var cost: Double = 0
    public var tokens: Int64 { input + output + creation + hit }
}

public struct UsageSnapshot: Sendable {
    public var today: UsageSummary
    public var cumulative: UsageSummary
    public var trend: [TrendBucket]
    public var generatedAt: Date
    public var lastEventAt: Date?
}

public enum UsageStoreError: Error, CustomStringConvertible {
    case open(Int32)
    case prepare(String)
    public var description: String {
        switch self {
        case .open(let rc): return "cannot open database (sqlite rc=\(rc))"
        case .prepare(let sql): return "failed to prepare SQL: \(sql)"
        }
    }
}

// MARK: - 数据仓库

/// 查询过滤条件：时间窗 + 来源(app) + Provider + 模型（对齐上游 get_usage_summary /
/// get_usage_summary_by_app / get_daily_trends 的入参，四个接口都吃 provider_name）。
public struct UsageFilter: Sendable {
    public var start: Int64?
    public var end: Int64?
    public var appType: String?       // nil = 全部；已折叠值，如 "claude"
    public var providerName: String?  // nil = 全部；按展示名精确匹配（含 "Claude (Session)" 等占位名）
    public var model: String?         // nil = 全部
    public init(start: Int64? = nil, end: Int64? = nil, appType: String? = nil,
                providerName: String? = nil, model: String? = nil) {
        self.start = start; self.end = end; self.appType = appType
        self.providerName = providerName; self.model = model
    }
}

// MARK: - Tabs 数据模型（对齐 cc-switch types/usage.ts，字段名 = camelCase 的 snake→camel 源）

/// 请求日志 / Provider 统计 / 模型统计 三个 Tab 共用的查询过滤条件。
/// 口径对齐 usage_stats.rs：appType 折叠 claude-desktop→claude，providerName 按展示名
/// 精确匹配（含 "Claude (Session)" 等会话占位名），model 按「有效计价模型」匹配。
public struct LogQueryFilter: Sendable {
    public var start: Int64?
    public var end: Int64?
    public var appType: String?
    public var providerName: String?
    public var model: String?
    public var statusCode: Int?     // 仅 requestLogs 用
    public init(start: Int64? = nil, end: Int64? = nil, appType: String? = nil,
                providerName: String? = nil, model: String? = nil, statusCode: Int? = nil) {
        self.start = start; self.end = end; self.appType = appType
        self.providerName = providerName; self.model = model; self.statusCode = statusCode
    }
}

/// 对齐 RequestLogDetail（usage_stats.rs）→ RequestLog（types/usage.ts）。
public struct RequestLogRow: Sendable {
    public var requestId: String
    public var providerId: String
    public var providerName: String
    public var appType: String
    public var model: String
    public var requestModel: String?
    public var pricingModel: String?
    public var costMultiplier: String
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64
    public var cacheCreationTokens: Int64
    public var inputCostUsd: String
    public var outputCostUsd: String
    public var cacheReadCostUsd: String
    public var cacheCreationCostUsd: String
    public var totalCostUsd: String
    public var isStreaming: Bool
    public var latencyMs: Int64
    public var firstTokenMs: Int64?
    public var durationMs: Int64?
    public var statusCode: Int
    public var errorMessage: String?
    public var createdAt: Int64
    public var dataSource: String?
}

public struct RequestLogPage: Sendable {
    public var rows: [RequestLogRow]
    public var total: Int
}

/// 对齐 ProviderStats（types/usage.ts）。
public struct ProviderStatRow: Sendable {
    public var providerId: String
    public var providerName: String
    public var requestCount: Int64
    public var totalTokens: Int64
    public var totalCost: Double
    public var successRate: Double
    public var avgLatencyMs: Int64
}

/// 对齐 ModelStats（types/usage.ts）。
public struct ModelStatRow: Sendable {
    public var model: String
    public var requestCount: Int64
    public var totalTokens: Int64
    public var totalCost: Double
    public var avgCostPerRequest: Double
}

/// 「按来源」一行。dataSource 取值空间同 proxy_request_logs.data_source
/// （session_log / codex_session / gemini_session / opencode_session / grok_session /
/// mcode_session / pi_session / proxy），外加本 app 独有的 omp_session
/// （cc-switch 不导入 OMP）。
public struct DataSourceStat: Sendable {
    public var dataSource: String
    public var requestCount: Int64
    public var totalCost: Double
}
