import XCTest

/// 请求日志的二路归并：不连库，直接喂两路行。
final class RequestLogMergeTests: XCTestCase {
    private func row(_ id: String, _ createdAt: Int64) -> RequestLogRow {
        RequestLogRow(requestId: id, providerId: "p", providerName: "p", appType: "claude", model: "m",
                      costMultiplier: "1", inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
                      inputCostUsd: "0", outputCostUsd: "0", cacheReadCostUsd: "0", cacheCreationCostUsd: "0",
                      totalCostUsd: "0", isStreaming: true, latencyMs: 0, statusCode: 200, createdAt: createdAt)
    }

    private func ids(_ rows: [RequestLogRow], _ overlay: [RequestLogRow], limit: Int) -> [String] {
        RequestLogMerge.merged(rows, overlay, limit: limit).map(\.requestId)
    }

    func testInterleavesByCreatedAtDescending() {
        XCTAssertEqual(ids([row("d9", 9), row("d5", 5)], [row("o7", 7), row("o3", 3)], limit: 10),
                       ["d9", "o7", "d5", "o3"])
    }

    /// 负责杀的变异体：比较写成 >，同一时刻叠加行排到库内行前面。
    func testDatabaseRowWinsATie() {
        XCTAssertEqual(ids([row("d", 5)], [row("o", 5)], limit: 10), ["d", "o"])
    }

    func testStopsAtLimit() {
        XCTAssertEqual(ids([row("d9", 9), row("d5", 5)], [row("o7", 7)], limit: 2), ["d9", "o7"])
        XCTAssertEqual(ids([row("d", 9)], [row("o", 7)], limit: 0), [])
    }

    func testOneSideEmpty() {
        XCTAssertEqual(ids([], [row("o7", 7), row("o3", 3)], limit: 10), ["o7", "o3"])
        XCTAssertEqual(ids([row("d9", 9)], [], limit: 10), ["d9"])
        XCTAssertEqual(ids([], [], limit: 10), [])
    }
}
