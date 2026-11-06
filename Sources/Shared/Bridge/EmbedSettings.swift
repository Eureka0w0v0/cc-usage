import Foundation

/// 主窗口（embed）桥接 `get_settings` 的返回值。
///
/// 上游 v4.0.20 用量页通过 `useSettingsQuery()`（→ `get_settings`）只读 settings 里的两样：
/// - `usageDisplay`：请求日志显示哪些列、趋势图画柱形还是面积。上游存在 cc-switch 的 settings.json，
///   本应用只读、不写别人的设置，所以存在自己的 UserDefaults（`embed.usageDisplay`，JSON 字符串，
///   由页面经 `set_setting` 写入）。
/// - `visibleApps`：「应用」页显示哪些应用，决定应用筛选码片（上游 711a4127）。这是 cc-switch 的
///   设置，只读镜像 `~/.cc-switch/settings.json` 里的同名字段。
///
/// 两样都按白名单取：settings.json 里还有同步、代理等别的设置，不往网页里带；值类型不对的丢掉，
/// 什么都不剩就不给这个键（前端按上游默认处理）。
enum EmbedSettings {
    static func compose(usageDisplayJSON: String?, ccSwitchSettings: Data?) -> [String: Any] {
        var out: [String: Any] = [:]
        if let display = usageDisplay(fromJSON: usageDisplayJSON) { out["usageDisplay"] = display }
        if let apps = visibleApps(from: ccSwitchSettings) { out["visibleApps"] = apps }
        return out
    }

    /// 只放行上游认的两个键：`requestLogColumns`（列 id → 布尔）和 `trendChartType`（字符串）。
    static func usageDisplay(fromJSON json: String?) -> [String: Any]? {
        guard let json, let root = object(Data(json.utf8)) else { return nil }
        var out: [String: Any] = [:]
        if let columns = boolMap(root["requestLogColumns"]) { out["requestLogColumns"] = columns }
        if let chart = root["trendChartType"] as? String { out["trendChartType"] = chart }
        return out.isEmpty ? nil : out
    }

    static func visibleApps(from settings: Data?) -> [String: Bool]? {
        guard let settings, let root = object(settings) else { return nil }
        return boolMap(root["visibleApps"])
    }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// JSON 对象里值为真布尔（true / false）的条目；数字 0 / 1、字符串一律不算。
    /// 不能用 `as? Bool`：JSONSerialization 给的 NSNumber(1) 也能桥成 true。
    private static func boolMap(_ value: Any?) -> [String: Bool]? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: Bool] = [:]
        for (key, raw) in dict {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { continue }
            out[key] = number.boolValue
        }
        return out.isEmpty ? nil : out
    }
}
