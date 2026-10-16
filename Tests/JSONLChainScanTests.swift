import XCTest

// 对话链行的快扫（JSONLScan.chainFields）：只读顶层的 uuid / parentUuid / timestamp / type，其余值整段跳过；
// 有把握时给结果，否则交回整行解析。核心不变式：只要给了结果，就和 JSONSerialization 整行解析取到的完全相同。
// 每个用例的注释写明它负责杀哪些变异体。
final class JSONLChainScanTests: XCTestCase {
    private typealias Fields = JSONLScan.ChainFields

    private func scan(_ line: String) -> JSONLScan.ChainScan {
        // 多垫一个字节：空串也有合法指针，长度照原样传
        let bytes = Array(line.utf8) + [0]
        return bytes.withUnsafeBytes { JSONLScan.chainFields($0.baseAddress!, bytes.count - 1) }
    }

    private func fields(_ uuid: String? = nil, parent: String? = nil, timestamp: String? = nil,
                        type: String? = nil) -> JSONLScan.ChainScan {
        .fields(Fields(uuid: uuid, parentUuid: parent, timestamp: timestamp, type: type))
    }

    /// 真实形状的工具结果行：嵌套对象、数组、字符串里到处是同名键、花括号、方括号和转义引号，只取顶层的。
    /// 杀变异体：嵌套对象里的同名键被当成顶层的；字符串里的括号算进深度；转义引号当成字符串结束。
    func testReadsOnlyTopLevelFieldsOfARealisticLine() {
        let line = #"{"parentUuid":"p-1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"{\"uuid\":\"fake\",\"timestamp\":\"x\"} ]}","is_error":false}],"uuid":"nested-key"},"uuid":"u-1","timestamp":"2026-06-07T13:00:00.000Z","toolUseResult":{"stdout":"a \\\" b","items":[1,2.5,-3e4,true,false,null,{"uuid":"deep"}]},"sessionId":"s"}"#
        XCTAssertEqual(scan(line), fields("u-1", parent: "p-1", timestamp: "2026-06-07T13:00:00.000Z", type: "user"))
    }

    /// 引号前面连续的反斜杠：奇数个是转义，偶数个（转义的是反斜杠本身）时这个引号就是收尾。
    /// 杀变异体：只要前面有反斜杠就当转义（第二、三条找不到收尾）。
    func testBackslashParityDecidesWhetherAQuoteEndsTheString() {
        XCTAssertEqual(scan(#"{"a":"x\"y","uuid":"u"}"#), fields("u"))
        XCTAssertEqual(scan(#"{"a":"ends with a backslash \\","uuid":"u"}"#), fields("u"))
        XCTAssertEqual(scan(#"{"a":"\\\"","uuid":"u"}"#), fields("u"))
    }

    /// 要取的键值不是字符串：等于没有这个字段（上游 as_str 取不到）。
    /// 杀变异体：非字符串值没清掉先前的同名值；数字、布尔、null、数组、对象跳不过去。
    func testNonStringValuesOfWantedKeysAreNil() {
        XCTAssertEqual(scan(#"{"uuid":123,"parentUuid":null,"timestamp":true,"type":["user"]}"#), fields())
        XCTAssertEqual(scan(#"{"uuid":{"a":"b"},"type":false}"#), fields())
        XCTAssertEqual(scan(#"{"uuid":"a","uuid":7}"#), fields())
    }

    /// 同名键后出现的覆盖先出现的（与整行解析成字典时一样）。
    /// 杀变异体：只取第一次出现的。
    func testLaterDuplicateKeyWins() {
        XCTAssertEqual(scan(#"{"uuid":"a","uuid":"b"}"#), fields("b"))
        XCTAssertEqual(scan(#"{"type":"user","type":"attachment"}"#), fields(type: "attachment"))
    }

    /// 键或要取的值里有转义：得先解码才知道是什么，交回整行解析；不相干的值里的转义不影响。
    /// 杀变异体：不检查键里的转义（"uuid" 其实就是 uuid）；不检查值里的转义（时间戳会原样带着 Z）。
    func testEscapesInKeysOrWantedValuesNeedAFullParse() {
        XCTAssertEqual(scan(#"{"uu\u0069d":"x"}"#), .needsFullParse)
        XCTAssertEqual(scan(#"{"timestamp":"2026-06-07T13:00:00.000\u005A"}"#), .needsFullParse)
        XCTAssertEqual(scan(#"{"message":"line\nbreak \u00e9 \"q\"","uuid":"u"}"#), fields("u"))
    }

    /// assistant 行还要记回复计时，一律整行解析，不管 type 在前在后。
    /// 杀变异体：assistant 行也走快扫（回复计时就没了）。
    func testAssistantLinesNeedAFullParse() {
        XCTAssertEqual(scan(#"{"type":"assistant","uuid":"u"}"#), .needsFullParse)
        XCTAssertEqual(scan(#"{"uuid":"u","type":"assistant"}"#), .needsFullParse)
    }

    /// 结构不完整或不是对象：交回整行解析（整行解析同样会认出它是坏行）。
    /// 杀变异体：对象后面多出的字符不检查（含空对象）；缺逗号、缺冒号、尾逗号、半截字符串、半截对象没拦住。
    func testMalformedLinesNeedAFullParse() {
        for line in [#"{"uuid":"u","message":{"a":"b""#, #"{"uuid":"u"#, #"{"uuid":"u"} trailing"#,
                     #"["uuid","u"]"#, "", "   ", #"{"uuid" "u"}"#, #"{"uuid":"u",}"#,
                     #"{"uuid":"u" "type":"user"}"#, #"{"a":tru"e"}"#, #"{"a":}"#, #"{"a":1"#, #"{"#,
                     #"{"a":[1,2}"#, "{} x"] {
            XCTAssertEqual(scan(line), .needsFullParse, line)
        }
    }

    /// 空白可以出现在任何记号之间；空对象没有字段。
    func testWhitespaceAndEmptyObject() {
        XCTAssertEqual(scan("  { \"uuid\" : \"u\" ,\t\"type\" :\"user\" }  "), fields("u", type: "user"))
        XCTAssertEqual(scan("{}"), fields())
        XCTAssertEqual(scan(" { } "), fields())
    }

    /// 随机生成的合法 JSON 行（JSONSerialization 编码，含各种转义、嵌套、同名键藏在深处）：快扫只要给了结果，
    /// 就必须与整行解析取到的四个字段完全相同；而且大多数行确实能快扫（不是靠全都推给整行解析混过去）。
    /// 杀变异体：上面各条的任何一种，在随机形状上被放大。
    func testAgreesWithJSONSerializationOnGeneratedLines() throws {
        var seed: UInt64 = 0xC0FFEE_2026
        func next(_ n: Int) -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((seed >> 33) % UInt64(n))
        }
        let pieces = ["a", "\"", "\\", "{", "}", "[", "]", ":", ",", " ", "é", "😀", "\n", "/", "uuid", "\"uuid\":\"x\""]
        func randomString() -> String { (0..<next(6)).map { _ in pieces[next(pieces.count)] }.joined() }
        func randomValue(_ depth: Int) -> Any {
            switch next(depth > 2 ? 4 : 6) {
            case 0: return randomString()
            case 1: return next(2) == 0 ? NSNumber(value: next(1000)) : NSNumber(value: Double(next(1000)) / 7)
            case 2: return next(2) == 0
            case 3: return NSNull()
            case 4: return (0..<next(4)).map { _ in randomValue(depth + 1) }
            default:
                var d: [String: Any] = [:]
                for _ in 0..<next(4) { d[["uuid", "type", "timestamp", "x", randomString()][next(5)]] = randomValue(depth + 1) }
                return d
            }
        }
        var fast = 0
        for _ in 0..<3000 {
            var d: [String: Any] = [:]
            for key in ["uuid", "parentUuid", "timestamp", "type", "message", "toolUseResult"] where next(3) > 0 {
                switch next(4) {
                case 0, 1: d[key] = ["u-\(next(99))", "user", "attachment", "2026-06-07T13:00:00.000Z"][next(4)]
                default: d[key] = randomValue(0)
                }
            }
            let data = try JSONSerialization.data(withJSONObject: d)
            let line = String(decoding: data, as: UTF8.self)
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? NSDictionary)
            let expected = Fields(uuid: obj["uuid"] as? String, parentUuid: obj["parentUuid"] as? String,
                                  timestamp: obj["timestamp"] as? String, type: obj["type"] as? String)
            if case .fields(let got) = scan(line) {
                fast += 1
                XCTAssertEqual(got, expected, line)
            }
        }
        XCTAssertGreaterThan(fast, 1500, "大多数合法行应该能快扫")
    }
}
