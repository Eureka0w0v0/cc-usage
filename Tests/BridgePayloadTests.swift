import XCTest

/// 桥接 JSON 的键集合，对照 cc-switch v4.0.22 的 `src/types/usage.ts`。缺字段不会报错，前端拿到 undefined 才炸
/// （ModelStats 缺 successRate 时模型页签整页白屏），所以这里按键逐个钉死；上游改类型时跟着改。
final class BridgePayloadTests: XCTestCase {
    private func keys(_ d: [String: Any]) -> Set<String> { Set(d.keys) }

    private func logRow(requestModel: String? = nil, pricingModel: String? = nil, firstTokenMs: Int64? = nil,
                        durationMs: Int64? = nil, errorMessage: String? = nil, dataSource: String? = nil) -> RequestLogRow {
        RequestLogRow(requestId: "r", providerId: "p", providerName: "P", appType: "claude", model: "m",
                      requestModel: requestModel, pricingModel: pricingModel, costMultiplier: "1",
                      inputTokens: 1, outputTokens: 2, cacheReadTokens: 3, cacheCreationTokens: 4,
                      inputCostUsd: "0.1", outputCostUsd: "0.2", cacheReadCostUsd: "0.3", cacheCreationCostUsd: "0.4",
                      totalCostUsd: "1.0", isStreaming: true, latencyMs: 5, firstTokenMs: firstTokenMs,
                      durationMs: durationMs, statusCode: 200, errorMessage: errorMessage, createdAt: 6,
                      dataSource: dataSource)
    }

    private static let requestLogRequired: Set<String> = [
        "requestId", "providerId", "providerName", "appType", "model", "costMultiplier",
        "inputTokens", "outputTokens", "cacheReadTokens", "cacheCreationTokens",
        "inputCostUsd", "outputCostUsd", "cacheReadCostUsd", "cacheCreationCostUsd", "totalCostUsd",
        "isStreaming", "latencyMs", "statusCode", "createdAt",
    ]
    private static let performanceKeys: Set<String> = [
        "speedOutputTokens", "speedGenerationMs", "estSpeedOutputTokens", "estSpeedDurationMs",
        "firstTokenMedianMs", "estFirstTokenMedianMs",
    ]

    func testRequestLogKeysWithoutOptionalFields() {
        XCTAssertEqual(keys(BridgePayload.requestLog(logRow())), Self.requestLogRequired)
    }

    /// 可空字段只在有值时写（对齐 serde skip_serializing_if）；空串等于没有。
    func testRequestLogOptionalFieldsOnlyWhenPresent() {
        let full = BridgePayload.requestLog(logRow(requestModel: "rm", pricingModel: "pm", firstTokenMs: 7, durationMs: 8,
                                                   errorMessage: "e", dataSource: "session_log"))
        XCTAssertEqual(keys(full), Self.requestLogRequired.union(["requestModel", "pricingModel", "firstTokenMs",
                                                                  "durationMs", "errorMessage", "dataSource"]))
        let blanks = BridgePayload.requestLog(logRow(requestModel: "", pricingModel: "", errorMessage: "", dataSource: ""))
        XCTAssertEqual(keys(blanks), Self.requestLogRequired)
    }

    func testRequestLogPageShape() {
        let page = RequestLogPage(rows: [logRow()], total: 9)
        let d = BridgePayload.requestLogs(page, page: 2, pageSize: 20)
        XCTAssertEqual(keys(d), ["data", "total", "page", "pageSize"])
        XCTAssertEqual(d["total"] as? Int, 9)
        XCTAssertEqual(d["page"] as? Int, 2)
        XCTAssertEqual(d["pageSize"] as? Int, 20)
        XCTAssertEqual((d["data"] as? [[String: Any]])?.count, 1)
    }

    func testProviderStatKeys() {
        var row = ProviderStatRow(providerId: "p", appType: "claude", providerName: "P", requestCount: 1, totalTokens: 2,
                                  totalCost: 1.5, successRate: 99.5, avgLatencyMs: 3)
        row.performance.firstTokenMedianMs = 4
        let d = BridgePayload.providerStat(row)
        XCTAssertEqual(keys(d), Self.performanceKeys.union(["providerId", "appType", "providerName", "requestCount",
                                                            "totalTokens", "totalCost", "successRate", "avgLatencyMs"]))
        XCTAssertEqual(d["totalCost"] as? String, "1.500000", "金额是 6 位小数的字符串")
        XCTAssertEqual(d["firstTokenMedianMs"] as? Int64, 4)
        XCTAssertTrue(d["estFirstTokenMedianMs"] is NSNull, "中位数缺失时是 null，不是没有这个键")
    }

    /// 负责杀的变异体：ModelStats 漏 successRate（模型页签整页白屏，代码注释记过）。
    func testModelStatKeysIncludeSuccessRate() {
        let row = ModelStatRow(model: "m", requestCount: 1, totalTokens: 2, totalCost: 1.5, avgCostPerRequest: 0.25,
                               successRate: 98)
        let d = BridgePayload.modelStat(row)
        XCTAssertEqual(keys(d), Self.performanceKeys.union(["model", "requestCount", "totalTokens", "totalCost",
                                                            "avgCostPerRequest", "successRate"]))
        XCTAssertEqual(d["successRate"] as? Double, 98)
        XCTAssertEqual(d["avgCostPerRequest"] as? String, "0.250000")
    }

    func testSummaryKeys() {
        var s = UsageSummary()
        s.requests = 4; s.successes = 3; s.input = 1; s.output = 2; s.creation = 3; s.hit = 4; s.cost = 0.5
        let d = BridgePayload.summary(s)
        XCTAssertEqual(keys(d), ["totalRequests", "totalCost", "totalInputTokens", "totalOutputTokens",
                                 "totalCacheCreationTokens", "totalCacheReadTokens", "successRate", "realTotalTokens",
                                 "cacheHitRate"])
        XCTAssertEqual(d["realTotalTokens"] as? Int64, 10)
        XCTAssertEqual(d["successRate"] as? Double, 75)
        let byApp = BridgePayload.summaryByApp([(appType: "claude", summary: s)])
        XCTAssertEqual(byApp.map(keys), [["appType", "summary"]])
    }

    func testTrendKeys() {
        let b = TrendBucket(startTs: 0, requestCount: 1, input: 2, output: 3, creation: 4, hit: 5, cost: 6)
        let d = BridgePayload.trends([b])[0]
        XCTAssertEqual(keys(d), ["date", "requestCount", "totalCost", "totalTokens", "totalInputTokens",
                                 "totalOutputTokens", "totalCacheCreationTokens", "totalCacheReadTokens"])
        XCTAssertEqual(d["date"] as? String, "1970-01-01T00:00:00Z", "ISO8601，前端按 rfc3339 解析")
        XCTAssertEqual(d["totalTokens"] as? Int64, 5, "上游 DailyStats 的 totalTokens 只含输入 + 输出")
    }

    func testDataSourceKeys() {
        let d = BridgePayload.dataSources([DataSourceStat(dataSource: "session_log", requestCount: 1, totalCost: 2)])[0]
        XCTAssertEqual(keys(d), ["dataSource", "requestCount", "totalCostUsd"])
        XCTAssertEqual(d["totalCostUsd"] as? String, "2.000000")
    }

    func testQuotaKeysKeepNullsForMissingValues() {
        let tier = QuotaTier(name: "five_hour", utilization: 12.5, resetsAt: nil)
        let d = BridgePayload.quota([tier])[0]
        XCTAssertEqual(keys(d), ["name", "utilization", "resetsAt", "planLabel"])
        XCTAssertTrue(d["resetsAt"] is NSNull)
        XCTAssertTrue(d["planLabel"] is NSNull)
    }

    /// WKWebView 的 reply 要能序列化：NSNull 可以，Optional 包着的 nil 不行。
    func testEveryPayloadIsSerializable() {
        let s = UsageSummary()
        let payloads: [Any] = [
            BridgePayload.requestLogs(RequestLogPage(rows: [logRow(firstTokenMs: 1)], total: 1), page: 0, pageSize: 20),
            BridgePayload.providerStat(ProviderStatRow(providerId: "p", appType: "a", providerName: "P", requestCount: 0,
                                                       totalTokens: 0, totalCost: 0, successRate: 0, avgLatencyMs: 0)),
            BridgePayload.modelStat(ModelStatRow(model: "m", requestCount: 0, totalTokens: 0, totalCost: 0,
                                                 avgCostPerRequest: 0)),
            BridgePayload.summary(s),
            BridgePayload.summaryByApp([(appType: "a", summary: s)]),
            BridgePayload.trends([TrendBucket(startTs: 0)]),
            BridgePayload.dataSources([]),
            BridgePayload.quota([QuotaTier(name: "n", utilization: 1, resetsAt: Date(timeIntervalSince1970: 0))]),
        ]
        for p in payloads { XCTAssertTrue(JSONSerialization.isValidJSONObject(p), "\(p)") }
    }
}
