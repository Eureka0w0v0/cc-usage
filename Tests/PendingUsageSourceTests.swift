import XCTest

/// UsageStore 只认 PendingUsageSource：来源的个数和种类都由注入决定，同一个 request_id 只算一次。
final class PendingUsageSourceTests: XCTestCase {
    private final class Fake: PendingUsageSource {
        let rows: [OverlayRow]
        init(_ ids: [String]) {
            rows = ids.map {
                OverlayRow(requestId: $0, model: "m", createdAt: 100, input: 1, output: 1, cacheRead: 0, cacheCreation: 0,
                           inputCost: 0, outputCost: 0, cacheReadCost: 0, cacheCreationCost: 0, totalCost: 0,
                           hasStopReason: true, sourceFile: "f")
            }
        }
        func pendingRows(db: OpaquePointer) -> [OverlayRow] { rows }
    }

    private func requests(_ sources: [PendingUsageSource]) throws -> Int {
        let path = try Fixture.makeDB("pending-sources")
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try UsageStore(path: path, sources: sources).rangeSummary(UsageFilter()).requests
    }

    func testAnyNumberOfSourcesAreMerged() throws {
        XCTAssertEqual(try requests([]), 0)
        XCTAssertEqual(try requests([Fake(["a"])]), 1)
        XCTAssertEqual(try requests([Fake(["a"]), Fake(["b"]), Fake(["c", "d"])]), 4)
    }

    func testSameRequestIdFromTwoSourcesCountsOnce() throws {
        XCTAssertEqual(try requests([Fake(["a", "b"]), Fake(["b", "c"])]), 3)
        XCTAssertEqual(try requests([Fake([]), Fake(["a"]), Fake(["a"])]), 1, "排在空来源后面也要去重")
    }
}
