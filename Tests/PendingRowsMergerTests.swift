import XCTest
import SQLite3

/// PendingRowsMerger：把各来源的待入库行并成一份，来源没变时复用上次的结果。
/// 合并规则是从 UsageStore.overlayRows 原样搬出来的，这里逐条钉住；UsageStore 经它拿行的端到端行为见
/// PendingUsageSourceTests。
final class PendingRowsMergerTests: XCTestCase {
    /// 可以换行的来源：`rows` 不重新赋值时每次交出同一份数组，和两个叠加层的行为一样。
    private final class Source: PendingUsageSource {
        var rows: [OverlayRow]
        private(set) var calls = 0
        init(_ ids: [String]) { rows = Source.make(ids) }
        func pendingRows(db: OpaquePointer) -> [OverlayRow] {
            calls += 1
            return rows
        }
        static func make(_ ids: [String]) -> [OverlayRow] {
            ids.map {
                OverlayRow(requestId: $0, model: "m", createdAt: 100, input: 1, output: 1, cacheRead: 0, cacheCreation: 0,
                           inputCost: 0, outputCost: 0, cacheReadCost: 0, cacheCreationCost: 0, totalCost: 0,
                           hasStopReason: true, sourceFile: "f")
            }
        }
    }

    /// 每次都交出一份新数组的来源（测试替身常见的写法）。
    private final class FreshEachTime: PendingUsageSource {
        let ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        func pendingRows(db: OpaquePointer) -> [OverlayRow] { Source.make(ids) }
    }

    private var dbPath = ""
    private var db: OpaquePointer!

    override func setUpWithError() throws {
        dbPath = try Fixture.makeDB("merger")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &handle), SQLITE_OK)
        db = handle
    }

    override func tearDownWithError() throws {
        if db != nil { sqlite3_close(db) }
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    private func ids(_ sources: [PendingUsageSource]) -> [String] {
        PendingRowsMerger(sources).rows(db: db).map(\.requestId)
    }

    // MARK: - 合并规则（与搬出前逐条相同）

    /// 负责杀的变异体：只取第一个来源 / 顺序反了。
    func testRowsKeepSourceOrder() {
        XCTAssertEqual(ids([]), [])
        XCTAssertEqual(ids([Source(["a", "b"])]), ["a", "b"])
        XCTAssertEqual(ids([Source(["a"]), Source(["b"]), Source(["c", "d"])]), ["a", "b", "c", "d"])
    }

    /// 同一个 request_id 先到先得。负责杀的变异体：去掉去重 / 后来的覆盖先到的。
    func testDuplicateRequestIdAcrossSourcesKeepsTheFirst() {
        XCTAssertEqual(ids([Source(["a", "b"]), Source(["b", "c"])]), ["a", "b", "c"])
        XCTAssertEqual(ids([Source([]), Source(["a"]), Source(["a"])]), ["a"], "排在空来源后面也要去重")
        XCTAssertEqual(ids([Source(["a"]), Source(["a", "b"]), Source(["b", "c"])]), ["a", "b", "c"],
                       "第三个来源要和前两个的合并结果比")
    }

    /// 来源内部的重复不归合并管（各叠加层自己按 request_id 存字典，本来就不会有）；只有跨来源才去重。
    /// 负责杀的变异体：合并时顺手把单个来源内部也去重了（和搬出前不一样）。
    func testDuplicatesInsideOneSourceAreLeftAlone() {
        XCTAssertEqual(ids([Source(["a", "a"])]), ["a", "a"])
        XCTAssertEqual(ids([Source(["a"]), Source(["b", "b"])]), ["a", "b", "b"])
    }

    // MARK: - 复用

    /// 来源交出的还是同一份数组 → 不重新合并，结果也是同一份。
    /// 负责杀的变异体：每次都重新合并。
    func testUnchangedSourcesReuseTheMergedArray() {
        let merger = PendingRowsMerger([Source(["a", "b"]), Source(["c"])])
        let first = merger.rows(db: db)
        let second = merger.rows(db: db)
        XCTAssertEqual(first.map(\.requestId), ["a", "b", "c"])
        XCTAssertTrue(PendingRowsMerger.sameStorage(first, second))
    }

    /// 任一来源换了数组就重新合并——哪怕行数一样。
    /// 负责杀的变异体：只比行数 / 只看第一个来源 / 记住了结果却不更新记住的来源。
    func testAnySourceChangeTriggersARemerge() {
        let one = Source(["a", "b"]), two = Source(["c"])
        let merger = PendingRowsMerger([one, two])
        XCTAssertEqual(merger.rows(db: db).map(\.requestId), ["a", "b", "c"])

        two.rows = Source.make(["d"])
        XCTAssertEqual(merger.rows(db: db).map(\.requestId), ["a", "b", "d"], "第二个来源换了一条，行数没变")

        one.rows = Source.make(["x", "b"])
        XCTAssertEqual(merger.rows(db: db).map(\.requestId), ["x", "b", "d"], "第一个来源换了")

        let settled = merger.rows(db: db)
        XCTAssertTrue(PendingRowsMerger.sameStorage(settled, merger.rows(db: db)), "变化之后重新稳定下来")
    }

    /// 每次都交出新数组的来源永远不命中，退回每次重新合并，结果照样对。
    func testSourcesReturningFreshArraysStillMergeCorrectly() {
        let merger = PendingRowsMerger([FreshEachTime(["a", "b"]), FreshEachTime(["b", "c"])])
        XCTAssertEqual(merger.rows(db: db).map(\.requestId), ["a", "b", "c"])
        XCTAssertEqual(merger.rows(db: db).map(\.requestId), ["a", "b", "c"])
    }

    /// 每个来源每次只问一遍（来源自己有节流和锁，多问一遍就是多一次扫描判断）。
    func testEachSourceIsAskedExactlyOncePerCall() {
        let one = Source(["a"]), two = Source(["b"])
        let merger = PendingRowsMerger([one, two])
        _ = merger.rows(db: db)
        _ = merger.rows(db: db)
        XCTAssertEqual(one.calls, 2)
        XCTAssertEqual(two.calls, 2)
    }

    /// 判断「同一块存储」的依据：基址和长度都相同。空数组彼此相同；内容一样但各自分配的不算。
    func testSameStorage() {
        let a = Source.make(["a", "b"])
        let alias = a
        XCTAssertTrue(PendingRowsMerger.sameStorage(a, alias))
        XCTAssertFalse(PendingRowsMerger.sameStorage(a, Source.make(["a", "b"])))
        XCTAssertFalse(PendingRowsMerger.sameStorage(a, Array(a.prefix(1))))
        XCTAssertTrue(PendingRowsMerger.sameStorage([], []))
    }
}
