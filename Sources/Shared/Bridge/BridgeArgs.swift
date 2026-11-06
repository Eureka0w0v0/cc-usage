import Foundation

/// 面板 invoke 的入参（JS 对象桥过来的字典）→ 查询过滤条件。外部输入只在这里解析一次，handle 拿到的都是类型化的值。
struct BridgeArgs {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    /// JS 的数字或数字字符串都收。
    static func int64(_ v: Any?) -> Int64? {
        if let n = v as? NSNumber { return n.int64Value }
        if let s = v as? String { return Int64(s) }
        return nil
    }

    /// 筛选参数：空串和 "all" 都是「不筛」。设置键 / 值不能走这里，它们要原样透传。
    static func filter(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty, s != "all" { return s }
        return nil
    }

    private var start: Int64? { Self.int64(raw["startDate"]) }
    private var end: Int64? { Self.int64(raw["endDate"]) }
    private var appType: String? { Self.filter(raw["appType"]) }
    private var providerName: String? { Self.filter(raw["providerName"]) }
    private var model: String? { Self.filter(raw["model"]) }

    /// 时间窗 + app + provider + 模型（get_usage_summary / get_usage_trends）。
    var usageFilter: UsageFilter {
        UsageFilter(start: start, end: end, appType: appType, providerName: providerName, model: model)
    }

    /// 同上，不筛 app：get_usage_summary_by_app 本来就按 app 分组。
    var usageFilterAllApps: UsageFilter {
        UsageFilter(start: start, end: end, providerName: providerName, model: model)
    }

    /// 不吃时间窗（get_usage_first_date）。
    var scopeFilter: UsageFilter {
        UsageFilter(appType: appType, providerName: providerName, model: model)
    }

    /// get_provider_stats / get_model_stats。
    var statsFilter: LogQueryFilter {
        LogQueryFilter(start: start, end: end, appType: appType, providerName: providerName, model: model)
    }

    /// 入参形状：invoke("get_request_logs", { filters, page, pageSize })，
    /// 时间窗被 useRequestLogs 合并进 filters（filters.startDate/endDate）。
    var requestLogs: (filter: LogQueryFilter, page: Int, pageSize: Int) {
        let filters = raw["filters"] as? [String: Any] ?? [:]
        let f = LogQueryFilter(
            start: Self.int64(filters["startDate"]),
            end: Self.int64(filters["endDate"]),
            appType: Self.filter(filters["appType"]),
            providerName: Self.filter(filters["providerName"]),
            model: Self.filter(filters["model"]),
            statusCode: Self.int64(filters["statusCode"]).map { Int($0) }
        )
        return (f, Int(Self.int64(raw["page"]) ?? 0), Int(Self.int64(raw["pageSize"]) ?? 20))
    }

    /// 非空的字符串参数（requestId、设置键）。
    func nonEmptyString(_ key: String) -> String? {
        guard let s = raw[key] as? String, !s.isEmpty else { return nil }
        return s
    }
}
