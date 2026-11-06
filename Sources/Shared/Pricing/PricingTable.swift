import Foundation
import SQLite3

/// 库里 model_pricing 的内存快照 + 查价，两个叠加层共用（原先只在 SessionOverlay 里，原样搬出）。
///
/// 查价逐条对齐 usage_stats.rs::find_model_pricing_row：候选精确匹配 → 前缀匹配
/// （`model_id LIKE 'c-%' ORDER BY LENGTH LIMIT 1`）；库里查不到再回落内置表（上游 seed
/// 还没跟进的新模型）。库里已有的定价永远优先，用户在 cc-switch 改过的价不会被内置表覆盖。
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

    /// 键是小写 model_id（见 load）。
    private(set) var exact: [String: Price] = [:]
    /// 前缀匹配用：小写、短 id 优先（对齐 ORDER BY LENGTH ASC）。
    private(set) var idsByLength: [String] = []

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
        var table = PricingTable()
        table.exact = exact
        table.idsByLength = exact.keys.sorted { $0.count < $1.count }   // 前缀匹配取最短命中,对齐 LENGTH ASC
        return table
    }

    func find(_ modelId: String) -> Price? {
        let candidates = ModelId.pricingCandidates(modelId)
        for c in candidates {
            if let p = exact[c] { return p }
        }
        for c in candidates where ModelId.shouldTryPrefixMatch(c) {
            // model_id LIKE 'c-%' ORDER BY LENGTH LIMIT 1(idsByLength 已按长度升序)
            if let hit = idsByLength.first(where: { $0.hasPrefix(c + "-") }) {
                return exact[hit]
            }
        }
        // db 没有该模型(上游 seed 尚未跟进新模型)→ 回落内置表。库里已有的定价
        // 永远优先，所以用户在 cc-switch 改过的价不会被这里覆盖。
        return ModelPricing.lookup(modelId).map(Price.init)
    }
}

extension PricingTable.Price {
    init(_ row: ModelPricing.Row) {
        self.init(input: row.input, output: row.output, cacheRead: row.cacheRead, cacheCreation: row.cacheCreation)
    }
}
