import Foundation

/// 查询结果 → 前端吃的 JSON 字典。这份映射和 cc-switch 的 `src/types/usage.ts`（camelCase）是 Swift 与 TS 之间
/// 唯一的契约：字段缺了不会报错，前端拿到 undefined 才炸（ModelStats 缺 successRate 时模型页签整页白屏），
/// 所以键集合由 BridgePayloadTests 钉死。
enum BridgePayload {
    /// ISO8601DateFormatter 线程安全，静态复用（quota / trends 每 tick 都在调）。
    private static let iso = ISO8601DateFormatter()

    /// [QuotaTier] → 前端可消费、WKWebView 可序列化的 JSON：
    /// [{ name, utilization(0–100), resetsAt: ISO8601?, planLabel? }]。
    static func quota(_ tiers: [QuotaTier]) -> [[String: Any]] {
        return tiers.map { t in
            [
                "name": t.name,
                "utilization": t.utilization,
                "resetsAt": t.resetsAt.map { iso.string(from: $0) } ?? NSNull(),
                "planLabel": t.planLabel ?? NSNull(),
            ]
        }
    }

    // RequestLogPage → PaginatedLogs{ data, total, page, pageSize }
    static func requestLogs(_ p: RequestLogPage, page: Int, pageSize: Int) -> [String: Any] {
        return [
            "data": p.rows.map { requestLog($0) },
            "total": p.total,
            "page": page,
            "pageSize": pageSize,
        ]
    }

    // RequestLogRow → RequestLog。可空字段仅在有值时写入（对齐 serde skip_serializing_if）。
    static func requestLog(_ r: RequestLogRow) -> [String: Any] {
        var d: [String: Any] = [
            "requestId": r.requestId,
            "providerId": r.providerId,
            "providerName": r.providerName,
            "appType": r.appType,
            "model": r.model,
            "costMultiplier": r.costMultiplier,
            "inputTokens": r.inputTokens,
            "outputTokens": r.outputTokens,
            "cacheReadTokens": r.cacheReadTokens,
            "cacheCreationTokens": r.cacheCreationTokens,
            "inputCostUsd": r.inputCostUsd,
            "outputCostUsd": r.outputCostUsd,
            "cacheReadCostUsd": r.cacheReadCostUsd,
            "cacheCreationCostUsd": r.cacheCreationCostUsd,
            "totalCostUsd": r.totalCostUsd,
            "isStreaming": r.isStreaming,
            "latencyMs": r.latencyMs,
            "statusCode": r.statusCode,
            "createdAt": r.createdAt,
        ]
        if let v = r.requestModel, !v.isEmpty { d["requestModel"] = v }
        if let v = r.pricingModel, !v.isEmpty { d["pricingModel"] = v }
        if let v = r.firstTokenMs { d["firstTokenMs"] = v }
        if let v = r.durationMs { d["durationMs"] = v }
        if let v = r.errorMessage, !v.isEmpty { d["errorMessage"] = v }
        if let v = r.dataSource, !v.isEmpty { d["dataSource"] = v }
        return d
    }

    // ProviderStatRow → ProviderStats
    static func providerStat(_ s: ProviderStatRow) -> [String: Any] {
        return [
            "providerId": s.providerId,
            "appType": s.appType,
            "providerName": s.providerName,
            "requestCount": s.requestCount,
            "totalTokens": s.totalTokens,
            "totalCost": Fmt.usd6(s.totalCost),
            "successRate": s.successRate,
            "avgLatencyMs": s.avgLatencyMs,
        ].merging(performance(s.performance)) { current, _ in current }
    }

    // ModelStatRow → ModelStats（successRate 是 v4 前端的必填字段，缺了模型页签整页白屏）
    static func modelStat(_ s: ModelStatRow) -> [String: Any] {
        return [
            "model": s.model,
            "requestCount": s.requestCount,
            "totalTokens": s.totalTokens,
            "totalCost": Fmt.usd6(s.totalCost),
            "avgCostPerRequest": Fmt.usd6(s.avgCostPerRequest),
            "successRate": s.successRate,
        ].merging(performance(s.performance)) { current, _ in current }
    }

    // StatsPerformance → ProviderStats / ModelStats 的六个速度、首字字段（中位数缺失时为 null）
    private static func performance(_ p: StatsPerformance) -> [String: Any] {
        return [
            "speedOutputTokens": p.speedOutputTokens,
            "speedGenerationMs": p.speedGenerationMs,
            "estSpeedOutputTokens": p.estSpeedOutputTokens,
            "estSpeedDurationMs": p.estSpeedDurationMs,
            "firstTokenMedianMs": p.firstTokenMedianMs.map { $0 as Any } ?? NSNull(),
            "estFirstTokenMedianMs": p.estFirstTokenMedianMs.map { $0 as Any } ?? NSNull(),
        ]
    }

    // 单个 summary → camelCase dict（对齐 types/usage.ts UsageSummary）
    static func summary(_ s: UsageSummary) -> [String: Any] {
        return [
            "totalRequests": s.requests,
            "totalCost": Fmt.usd6(s.cost),
            "totalInputTokens": s.input,
            "totalOutputTokens": s.output,
            "totalCacheCreationTokens": s.creation,
            "totalCacheReadTokens": s.hit,
            "successRate": s.successRate,
            "realTotalTokens": s.tokensProcessed,
            "cacheHitRate": s.cacheHitRate,
        ]
    }

    // get_usage_summary_by_app → [{appType, summary}]（每个 app 一行）
    // 底层为 proxy_request_logs + usage_daily_rollups 两表合并的 GROUP BY app_type，
    // 故仅存在于历史聚合表的来源（如 codex）也会出现，且各 app 数字含历史。
    static func summaryByApp(_ list: [(appType: String, summary: UsageSummary)]) -> [[String: Any]] {
        return list.map { item in
            ["appType": item.appType, "summary": summary(item.summary)]
        }
    }

    // get_usage_trends → DailyStats[]（date rfc3339 + 各 token/cost 字段，camelCase）。
    static func trends(_ buckets: [TrendBucket]) -> [[String: Any]] {
        return buckets.map { b in
            return [
                "date": iso.string(from: Date(timeIntervalSince1970: TimeInterval(b.startTs))),
                "requestCount": b.requestCount,
                "totalCost": Fmt.usd6(b.cost),
                "totalTokens": b.input + b.output,
                "totalInputTokens": b.input,
                "totalOutputTokens": b.output,
                "totalCacheCreationTokens": b.creation,
                "totalCacheReadTokens": b.hit,
            ]
        }
    }

    // get_usage_data_sources → DataSourceSummary[]
    static func dataSources(_ stats: [DataSourceStat]) -> [[String: Any]] {
        return stats.map {
            [
                "dataSource": $0.dataSource,
                "requestCount": $0.requestCount,
                "totalCostUsd": Fmt.usd6($0.totalCost),
            ]
        }
    }
}
