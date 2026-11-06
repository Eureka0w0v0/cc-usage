import XCTest

/// 单行解析与 message.id 保留规则：不用临时 JSONL，直接喂 JSON 对象。
final class ClaudeUsageParsingTests: XCTestCase {
    private func object(_ json: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary)
    }

    private func entry(_ json: String, now: Int64 = 0) throws -> ClaudeUsage.Entry? {
        ClaudeUsage.entry(try object(json), now: { now })
    }

    func testReadsEveryBillableFieldOfAnAssistantLine() throws {
        let e = try entry(#"""
        {"type":"assistant","timestamp":"2026-07-08T10:00:00.123456Z","message":{"id":"m1","model":"claude-x",
         "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2,"cache_read_input_tokens":3,
         "cache_creation_input_tokens":4,"cache_creation":{"ephemeral_1h_input_tokens":5}}}}
        """#)
        XCTAssertEqual(e, ClaudeUsage.Entry(messageId: "m1", model: "claude-x", createdAt: 1_783_504_800,
                                            input: 1, output: 2, cacheRead: 3, cacheCreation: 4,
                                            cacheCreation1h: 5, hasStop: true))
    }

    func testOnlyAssistantLinesWithIdAndUsageCount() throws {
        XCTAssertNil(try entry(#"{"type":"user","message":{"id":"m","usage":{"input_tokens":1}}}"#))
        XCTAssertNil(try entry(#"{"type":"assistant","message":{"usage":{"input_tokens":1}}}"#))
        XCTAssertNil(try entry(#"{"type":"assistant","message":{"id":"m"}}"#))
    }

    /// 上游 has_billable_tokens：四个维度全 0 不计；缓存写入的 1 小时明细不算维度。
    func testAllZeroUsageIsNotBillable() throws {
        XCTAssertNil(try entry(#"{"type":"assistant","message":{"id":"m","usage":{"input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":9}}}}"#))
        XCTAssertNotNil(try entry(#"{"type":"assistant","message":{"id":"m","usage":{"cache_read_input_tokens":1}}}"#))
    }

    func testDefaultsWhenOptionalFieldsAreMissing() throws {
        let e = try XCTUnwrap(try entry(#"{"type":"assistant","timestamp":"bad","message":{"id":"m","usage":{"output_tokens":1}}}"#,
                                        now: 42))
        XCTAssertEqual(e.model, "unknown")
        XCTAssertEqual(e.createdAt, 42, "时间戳解析失败回落当前时间")
        XCTAssertFalse(e.hasStop)
    }

    func testRequestIdIsInUpstreamNamespace() {
        XCTAssertEqual(ClaudeUsage.requestId("msg_1"), "session:msg_1")
    }

    /// 同一 message.id：带 stop_reason 的优先；同级取输出更大的；不带的永远顶不掉带的。
    func testReplacementPrefersStopReasonThenLargerOutput() {
        func replaces(_ stop: Bool, _ output: Int64, over oldStop: Bool, _ oldOutput: Int64) -> Bool {
            ClaudeUsage.replaces(hasStop: stop, output: output, oldHasStop: oldStop, oldOutput: oldOutput)
        }
        XCTAssertTrue(replaces(true, 1, over: false, 100))
        XCTAssertFalse(replaces(false, 100, over: true, 1))
        XCTAssertTrue(replaces(true, 2, over: true, 1))
        XCTAssertFalse(replaces(true, 1, over: true, 1), "相等不替换：先到的留下")
        XCTAssertTrue(replaces(false, 2, over: false, 1))
        XCTAssertFalse(replaces(false, 1, over: false, 2))
    }
}
