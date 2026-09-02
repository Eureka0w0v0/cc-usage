import Foundation

// 与 cc-switch usage_stats.rs / sql_helpers.rs 逐字对齐的 SQL 片段。别名约定：
// l = proxy_request_logs（明细）、r = usage_daily_rollups（历史日聚合）、p / p2 = providers。
extension UsageStore {
    /// 折叠 claude-desktop→claude（仅过滤/分组口径，行投影仍返回原始 app_type）。
    static let foldedAppL = "CASE WHEN l.app_type='claude-desktop' THEN 'claude' ELSE l.app_type END"
    /// 有效计价模型：pricing_model 非空优先，NULL/'' 回落 model。
    static let effectiveModelL = "COALESCE(NULLIF(l.pricing_model, ''), l.model)"
    /// cache 归一化 input（对齐 sql_helpers.rs::fresh_input_sql，v13 语义）：
    /// input_token_semantics 0=legacy（codex 系 input 含 cache_read）、
    /// 1=total（还含 cache_creation）、2=fresh（已归一，原样返回）。
    static func freshInputV13(_ a: String) -> String {
        """
        CASE WHEN \(a).input_token_semantics = 2 THEN \(a).input_tokens
             WHEN \(a).app_type IN \(cacheInclusiveApps) AND \(a).input_token_semantics = 1
                  AND \(a).input_tokens >= (\(a).cache_read_tokens + \(a).cache_creation_tokens)
                  THEN (\(a).input_tokens - \(a).cache_read_tokens - \(a).cache_creation_tokens)
             WHEN \(a).app_type IN \(cacheInclusiveApps) AND \(a).input_token_semantics = 0
                  AND \(a).input_tokens >= \(a).cache_read_tokens
                  THEN (\(a).input_tokens - \(a).cache_read_tokens)
             ELSE \(a).input_tokens END
        """
    }
    /// input_tokens 含 cache 的应用（v13 口径，对齐 sql_helpers.rs）。
    static let cacheInclusiveApps = "('codex','gemini','grokbuild')"
    /// cache 归一化 input（schema <13 旧库：无 input_token_semantics 列，行为与旧版完全一致）。
    static func freshInputLegacy(_ a: String) -> String {
        "CASE WHEN \(a).app_type IN ('codex','gemini') AND \(a).input_tokens >= \(a).cache_read_tokens THEN (\(a).input_tokens - \(a).cache_read_tokens) ELSE \(a).input_tokens END"
    }

    /// provider 展示名：providers.name 优先，会话占位 provider_id 映射为可读名
    /// （对齐 usage_stats.rs::provider_name_coalesce）。proxy_request_logs 与 usage_daily_rollups
    /// 的 (provider_id, app_type) 同形，两张表都能当 log 别名。
    static func providerNameSQL(log l: String, provider p: String) -> String {
        """
        COALESCE(\(p).name, CASE \(l).provider_id
            WHEN '_session' THEN 'Claude (Session)'
            WHEN '_codex_session' THEN 'Codex (Session)'
            WHEN '_gemini_session' THEN 'Gemini (Session)'
            WHEN '_opencode_session' THEN 'OpenCode (Session)'
            WHEN '_grok_session' THEN 'Grok Build (Session)'
            WHEN '_pi_session' THEN 'Pi (Session)'
            ELSE \(l).provider_id END)
        """
    }
    /// providers 表 LEFT JOIN（对齐 providers_join）：主键即 (id, app_type)，至多 1:1，不放大行数。
    static func providersJoin(log l: String, provider p: String) -> String {
        "LEFT JOIN providers \(p) ON \(l).provider_id = \(p).id AND \(l).app_type = \(p).app_type"
    }
    /// 只有传了 provider 筛选才 JOIN（对齐上游 detail_join / rollup_join 的条件拼接）；
    /// 不传时 SQL 与旧版逐字相同。
    static func providersJoinIf(_ providerName: String?, log l: String, provider p: String) -> String {
        providerName == nil ? "" : " " + providersJoin(log: l, provider: p)
    }
    /// 明细表侧（别名 l / p）的现成片段，Tabs 查询恒带 JOIN。
    static let providerNameCoalesce = providerNameSQL(log: "l", provider: "p")
    static let providersJoinL = providersJoin(log: "l", provider: "p")

    // ── usage_daily_rollups(别名 r) 侧的对应片段，供两表合并的 summary/trend/by-app 使用 ──
    /// 折叠 claude-desktop→claude（rollups 侧）。
    static let foldedAppR = "CASE WHEN r.app_type='claude-desktop' THEN 'claude' ELSE r.app_type END"
    /// 有效计价模型（rollups 侧）。
    static let effectiveModelR = "COALESCE(NULLIF(r.pricing_model, ''), r.model)"
    /// 跨源去重时的 app_type 匹配（对齐 usage_stats.rs::dedup_app_type_match_sql）：
    /// Claude Code 与 Claude Desktop 共用同一套 message id —— 走 Desktop 网关的请求以
    /// `claude-desktop` 落 proxy 行，而 session 导入器以 `claude` 落 session_log 行。
    /// 故 `claude` 的 session 行必须也能匹配 `claude-desktop` 的 proxy 行，否则同一笔
    /// 请求被双算。其余 app_type 保持精确比较，避免不同上游之间误撞。
    /// 注意：这是比展示口径折叠（foldedAppL）更窄的匹配 —— 只放宽 claude 一侧。
    static func dedupAppTypeMatch(_ left: String, _ right: String) -> String {
        "\(left) IN (\(right), CASE WHEN \(right)='claude' THEN 'claude-desktop' ELSE \(right) END)"
    }
    /// 跨源去重过滤（对齐 usage_stats.rs::effective_usage_log_filter，别名 l）：
    /// session 系日志若在 ±10min 窗口内存在指纹匹配的成功 proxy 行，则剔除该 session 行，
    /// 防止「同一次请求既落 session 又落 proxy」被双算（窗口见 dedupWindowSeconds）。
    /// 本机无 'proxy' 行 → EXISTS 恒 false → NOT(...) 恒 true → 全过（已验证），但忠实照搬。
    /// 跨源去重的时间窗（秒）：session 行与 proxy 行 created_at 相差 ±10 分钟内视为同一笔。
    static let dedupWindowSeconds: Int64 = 600
    static let effectiveUsageFilterL = """
        NOT (COALESCE(l.data_source,'proxy') IN ('session_log','codex_session','gemini_session','opencode_session')
             AND EXISTS (SELECT 1 FROM proxy_request_logs proxy_dedup
                         WHERE COALESCE(proxy_dedup.data_source,'proxy')='proxy'
                           AND \(dedupAppTypeMatch("proxy_dedup.app_type", "l.app_type"))
                           AND proxy_dedup.status_code>=200 AND proxy_dedup.status_code<300
                           AND proxy_dedup.input_tokens=l.input_tokens
                           AND proxy_dedup.output_tokens=l.output_tokens
                           AND proxy_dedup.cache_read_tokens=l.cache_read_tokens
                           AND (proxy_dedup.cache_creation_tokens=l.cache_creation_tokens
                                OR (l.cache_creation_tokens=0
                                    AND COALESCE(l.data_source,'proxy') IN ('codex_session','gemini_session','opencode_session')))
                           AND proxy_dedup.created_at BETWEEN l.created_at-\(dedupWindowSeconds) AND l.created_at+\(dedupWindowSeconds)
                           AND (LOWER(proxy_dedup.model)=LOWER(l.model)
                                OR LOWER(proxy_dedup.model)='unknown' OR LOWER(l.model)='unknown')))
        """
}
