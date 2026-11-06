import XCTest

/// 叠加行自带状态码：上游把 OMP 中断 / 报错的请求记成 499 / 500（用量可以是 0），
/// 请求数照算、成功只认 2xx。SessionOverlay 的行恒为 200，行为不变。
final class OverlayStatusTests: XCTestCase {
    private func row(_ id: String, status: Int64 = 200, error: String? = nil) -> OverlayRow {
        OverlayRow(requestId: id, model: "m", createdAt: 1,
                   input: 1, output: 2, cacheRead: 0, cacheCreation: 0,
                   inputCost: 0, outputCost: 0, cacheReadCost: 0, cacheCreationCost: 0, totalCost: 0.5,
                   hasStopReason: true, sourceFile: "f",
                   appType: "omp", providerId: "p", providerName: "p", dataSource: "omp_session",
                   statusCode: status, errorMessage: error)
    }

    /// 负责杀的变异体：addOverlay 仍把叠加行全部计入成功。
    func testSummaryCountsFailedOverlayRowsAsRequestsButNotSuccesses() {
        let store = UsageStore(path: "/nonexistent")
        var s = UsageSummary()
        store.addOverlay(&s, [row("a"), row("b", status: 499), row("c", status: 500)])
        XCTAssertEqual(s.requests, 3)
        XCTAssertEqual(s.successes, 1)
    }

    /// 负责杀的变异体：OverlayStats.Group 不分状态码累计成功数（供应商 / 模型统计的成功率）。
    func testStatsGroupCountsSuccessesByStatus() {
        let groups = OverlayStats.group([row("a"), row("b", status: 499), row("c", status: 204)]) {
            $0.providerId
        }
        XCTAssertEqual(groups["p"]?.requests, 3)
        XCTAssertEqual(groups["p"]?.successes, 2)
    }

    /// 负责杀的变异体：请求日志 / 详情仍写死 200、丢掉错误信息或请求模型。
    func testRequestLogRowCarriesStatusErrorAndRequestModel() {
        var r = row("a", status: 499, error: "Request was aborted")
        r.requestModel = "requested"
        let log = UsageStore.overlayRequestLogRow(r)
        XCTAssertEqual(log.statusCode, 499)
        XCTAssertEqual(log.errorMessage, "Request was aborted")
        XCTAssertEqual(log.requestModel, "requested")
        // 没给请求模型时回落 model（SessionOverlay 的行就是这样）
        XCTAssertEqual(UsageStore.overlayRequestLogRow(row("b")).requestModel, "m")
        XCTAssertNil(UsageStore.overlayRequestLogRow(row("b")).errorMessage)
    }
}
