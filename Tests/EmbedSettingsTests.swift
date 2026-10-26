import XCTest

// 主窗口（embed）桥接 `get_settings` 的返回：上游 v4.0.20 用量页从 settings 里只读两样——
// usageDisplay（请求日志列显隐、趋势图样式）和 visibleApps（「应用」页显示哪些应用，决定应用码片）。
final class EmbedSettingsTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testComposesUsageDisplayAndCCSwitchVisibleApps() {
        let out = EmbedSettings.compose(
            usageDisplayJSON: #"{"requestLogColumns":{"cacheWrite":true,"status":false},"trendChartType":"area"}"#,
            ccSwitchSettings: data(#"{"visibleApps":{"claude":true,"mcode":false},"language":"en"}"#))
        let display = out["usageDisplay"] as? [String: Any]
        XCTAssertEqual(display?["trendChartType"] as? String, "area")
        XCTAssertEqual(display?["requestLogColumns"] as? [String: Bool], ["cacheWrite": true, "status": false])
        XCTAssertEqual(out["visibleApps"] as? [String: Bool], ["claude": true, "mcode": false])
        XCTAssertEqual(Set(out.keys), ["usageDisplay", "visibleApps"])
    }

    // cc-switch 的 settings.json 里还有别的设置（同步、代理……），只拿 visibleApps，别的一概不往网页里带。
    // 负责杀的变异体：把整个 settings.json 原样返回。
    func testOnlyVisibleAppsLeaveCCSwitchSettings() {
        let out = EmbedSettings.compose(
            usageDisplayJSON: nil,
            ccSwitchSettings: data(#"{"visibleApps":{"codex":true},"webdavSync":{"password":"secret"},"enableLocalProxy":true}"#))
        XCTAssertEqual(Set(out.keys), ["visibleApps"])
    }

    // 显示设置只放行上游认的两个键；值类型不对的丢掉；什么都不剩就整个不给（前端按默认）。
    // 负责杀的变异体：不过滤未知键 / 列显隐不校验布尔值。
    func testUsageDisplayIsWhitelisted() {
        let out = EmbedSettings.compose(
            usageDisplayJSON: #"{"currency":"CNY","exchangeRates":{"CNY":7.1},"requestLogColumns":{"model":true,"latency":"yes","ttft":1},"trendChartType":3}"#,
            ccSwitchSettings: nil)
        let display = out["usageDisplay"] as? [String: Any]
        XCTAssertEqual(display?["requestLogColumns"] as? [String: Bool], ["model": true])
        XCTAssertNil(display?["trendChartType"])
        XCTAssertNil(display?["currency"])
        XCTAssertNil(display?["exchangeRates"])

        let nothingLeft = EmbedSettings.compose(usageDisplayJSON: #"{"currency":"CNY"}"#, ccSwitchSettings: nil)
        XCTAssertNil(nothingLeft["usageDisplay"])
    }

    // 坏数据一律当没有：存的不是 JSON、不是对象；settings.json 读不到、坏了、visibleApps 形状不对。
    func testMalformedInputsAreIgnored() {
        XCTAssertTrue(EmbedSettings.compose(usageDisplayJSON: "not json", ccSwitchSettings: nil).isEmpty)
        XCTAssertTrue(EmbedSettings.compose(usageDisplayJSON: "[1,2]", ccSwitchSettings: data("{")).isEmpty)
        XCTAssertTrue(EmbedSettings.compose(usageDisplayJSON: nil,
                                            ccSwitchSettings: data(#"{"visibleApps":["claude"]}"#)).isEmpty)
        let partial = EmbedSettings.compose(usageDisplayJSON: nil,
                                            ccSwitchSettings: data(#"{"visibleApps":{"claude":true,"pi":"on"}}"#))
        XCTAssertEqual(partial["visibleApps"] as? [String: Bool], ["claude": true])
    }
}
