import Foundation
import SQLite3

/// 库里 model_pricing 的内存快照 + 查价，两个叠加层和统计口径（同价推理档合并）共用。
///
/// 查价逐条对齐 usage_stats.rs::find_model_pricing_row / find_direct_model_pricing_row，查的是「内置表 ∪ 库」，
/// 同名时库里的行优先（用户在 cc-switch 改过的价不会被内置表覆盖）。上游的库里总带着它那一版的 seed；
/// 用户的 cc-switch 版本较老、库里缺新模型的 seed 行时，这里用内置表（= 上游最新 seed）补上，
/// 这样才和上游一样先命中精确价，而不是先撞上库里某条自定义行的前缀。
struct PricingTable {
    struct Price: Equatable {
        var input: Double
        var output: Double
        var cacheRead: Double
        var cacheCreation: Double

        /// 成本 = tokens × 每百万单价。先乘后除的次序不能换：与 cc-switch 算出的数要逐位一致。
        static func cost(_ tokens: Double, perMillion price: Double) -> Double {
            tokens * price / 1_000_000
        }

        /// 四项成本，倍率 1，缓存写入按定价表的 5 分钟价（Claude 的 1 小时档见 ClaudeCacheWriteBilling）。
        func cost(input: Int64, output: Int64, cacheRead: Int64, cacheCreation: Int64)
            -> (input: Double, output: Double, cacheRead: Double, cacheCreation: Double) {
            (Self.cost(Double(input), perMillion: self.input),
             Self.cost(Double(output), perMillion: self.output),
             Self.cost(Double(cacheRead), perMillion: self.cacheRead),
             Self.cost(Double(cacheCreation), perMillion: self.cacheCreation))
        }
    }

    /// 库里的行，键是小写 model_id（见 load）。
    private(set) var exact: [String: Price]
    /// 前缀匹配用：库 ∪ 内置表的全部 id，按长度、再按字典序升序（对齐 ORDER BY LENGTH ASC，同长时取值固定）。
    private(set) var idsByLength: [String]

    /// `exact` 为空 = 只有内置表（叠加层第一次读库之前、或库里没有这张表时）。
    init(exact: [String: Price] = [:]) {
        self.exact = exact
        self.idsByLength = Set(exact.keys).union(ModelPricing.table.keys)
            .sorted { ($0.count, $0) < ($1.count, $1) }
    }

    /// 读整张 model_pricing。prepare 失败（缺表等）返回 nil，调用方沿用旧快照、下轮再试。
    static func load(_ db: OpaquePointer) -> PricingTable? {
        var stmt: OpaquePointer?
        let sql = """
        SELECT model_id, input_cost_per_million, output_cost_per_million,
               cache_read_cost_per_million, cache_creation_cost_per_million FROM model_pricing
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        var exact: [String: Price] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let c = sqlite3_column_text(stmt, 0) else { continue }
            // 键一律转小写：查价候选（ModelId.pricingCandidates）全是小写，而自定义定价常按界面
            // 显示名原样入库（如 GLM-5.3-Flash-EXL3）。上游 #8414 起精确匹配是 `= ? COLLATE NOCASE`、
            // 前缀匹配是 LIKE，都不分大小写。只差大小写的两行撞车时先读到的留下：上游那条查询用不上
            // BINARY 主键索引、按表的自然顺序扫，同样先到先得。
            let id = String(cString: c).lowercased()
            guard exact[id] == nil else { continue }
            func col(_ i: Int32) -> Double {
                sqlite3_column_text(stmt, i).flatMap { Double(String(cString: $0)) } ?? 0
            }
            exact[id] = Price(input: col(1), output: col(2), cacheRead: col(3), cacheCreation: col(4))
        }
        return PricingTable(exact: exact)
    }

    /// 完整候选链：全部候选先精确匹配，都落空再对允许前缀的候选做前缀匹配（`model_id LIKE 'c-%'`，取最短）。
    func find(_ modelId: String) -> Price? {
        let candidates = ModelId.pricingCandidates(modelId)
        for c in candidates {
            if let p = price(of: c.id) { return p }
        }
        for c in candidates where c.allowsPrefixMatch && ModelId.shouldTryPrefixMatch(c.id) {
            if let hit = idsByLength.first(where: { $0.hasPrefix(c.id + "-") }) { return price(of: hit) }
        }
        return nil
    }

    /// 只做精确匹配（对齐 find_direct_model_pricing_row）：候选不剥推理档 / tiered / thinking，也不做前缀匹配。
    /// 同价推理档合并时用它取基础模型自己的价。
    func findDirect(_ modelId: String) -> Price? {
        for c in ModelId.directCandidates(modelId) {
            if let p = price(of: c) { return p }
        }
        return nil
    }

    /// 同名时库里的行优先，库里没有再用内置表的。
    private func price(of id: String) -> Price? {
        exact[id] ?? ModelPricing.table[id].map(Price.init)
    }
}

extension PricingTable.Price {
    init(_ row: ModelPricing.Row) {
        self.init(input: row.input, output: row.output, cacheRead: row.cacheRead, cacheCreation: row.cacheCreation)
    }
}
