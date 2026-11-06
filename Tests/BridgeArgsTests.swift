import XCTest

/// invoke 入参解析：JS 过来的值类型不固定（数字 / 字符串 / 缺失），「不筛」有空串和 all 两种写法。
final class BridgeArgsTests: XCTestCase {
    func testInt64AcceptsNumbersAndNumericStrings() {
        XCTAssertEqual(BridgeArgs.int64(NSNumber(value: 42)), 42)
        XCTAssertEqual(BridgeArgs.int64("42"), 42)
        XCTAssertNil(BridgeArgs.int64("abc"))
        XCTAssertNil(BridgeArgs.int64(nil))
        XCTAssertNil(BridgeArgs.int64(NSNull()))
    }

    func testFilterTreatsBlankAndAllAsNoFilter() {
        XCTAssertEqual(BridgeArgs.filter("claude"), "claude")
        XCTAssertNil(BridgeArgs.filter("all"))
        XCTAssertNil(BridgeArgs.filter(""))
        XCTAssertNil(BridgeArgs.filter(nil))
        XCTAssertNil(BridgeArgs.filter(NSNumber(value: 1)))
    }

    private let full = BridgeArgs(["startDate": 10, "endDate": "20", "appType": "claude",
                                   "providerName": "P", "model": "m"])

    func testUsageFilterCarriesEverything() {
        let f = full.usageFilter
        XCTAssertEqual(f.start, 10)
        XCTAssertEqual(f.end, 20)
        XCTAssertEqual(f.appType, "claude")
        XCTAssertEqual(f.providerName, "P")
        XCTAssertEqual(f.model, "m")
    }

    /// 负责杀的变异体：summary_by_app 也按 app 筛（Hero 的按应用拆分只剩一行）。
    func testByAppFilterDropsApp() {
        let f = full.usageFilterAllApps
        XCTAssertNil(f.appType)
        XCTAssertEqual(f.start, 10)
        XCTAssertEqual(f.providerName, "P")
    }

    /// 负责杀的变异体：最早日期吃时间窗（热力图铺的段数跟着时间范围变）。
    func testScopeFilterDropsTheTimeWindow() {
        let f = full.scopeFilter
        XCTAssertNil(f.start)
        XCTAssertNil(f.end)
        XCTAssertEqual(f.appType, "claude")
        XCTAssertEqual(f.model, "m")
    }

    func testStatsFilterHasNoStatusCode() {
        let f = full.statsFilter
        XCTAssertEqual(f.start, 10)
        XCTAssertEqual(f.providerName, "P")
        XCTAssertNil(f.statusCode)
    }

    /// 请求日志的筛选嵌在 filters 里，顶层同名字段不算。
    func testRequestLogsReadsNestedFilters() {
        let q = BridgeArgs(["startDate": 1, "appType": "codex", "page": 3, "pageSize": "50",
                            "filters": ["startDate": 10, "endDate": 20, "appType": "claude", "providerName": "all",
                                        "model": "m", "statusCode": "499"] as [String: Any]]).requestLogs
        XCTAssertEqual(q.filter.start, 10)
        XCTAssertEqual(q.filter.end, 20)
        XCTAssertEqual(q.filter.appType, "claude")
        XCTAssertNil(q.filter.providerName)
        XCTAssertEqual(q.filter.model, "m")
        XCTAssertEqual(q.filter.statusCode, 499)
        XCTAssertEqual(q.page, 3)
        XCTAssertEqual(q.pageSize, 50)
    }

    func testRequestLogsDefaults() {
        let q = BridgeArgs([:]).requestLogs
        XCTAssertEqual(q.page, 0)
        XCTAssertEqual(q.pageSize, 20)
        XCTAssertNil(q.filter.start)
    }

    /// 设置键不走 filter：名叫 "all" 的键要原样透传。
    func testNonEmptyStringKeepsAll() {
        XCTAssertEqual(BridgeArgs(["key": "all"]).nonEmptyString("key"), "all")
        XCTAssertNil(BridgeArgs(["key": ""]).nonEmptyString("key"))
        XCTAssertNil(BridgeArgs(["key": 1]).nonEmptyString("key"))
        XCTAssertNil(BridgeArgs([:]).nonEmptyString("key"))
    }
}
