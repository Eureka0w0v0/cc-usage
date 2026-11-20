import Foundation
import SQLite3

extension UsageStore {
    // MARK: - 同价推理档合并的接线（上游 #8845）
    //
    // 判断能不能并要查价，价格表（库里的 model_pricing，查不到再用内置表）只在用得上时读：有模型筛选时读一次，
    // 统计行里出现带档位 / tiered 后缀的模型时读一次。读不到表（旧库缺表）时只用内置表。

    /// 模型筛选 → ModelMatch（模型名 + 会并到它名下的后缀）。没有模型筛选时为 nil。
    func modelMatch(_ db: OpaquePointer, _ model: String?) -> ModelMatch? {
        guard let model else { return nil }
        let pricing = PricingTable.load(db) ?? PricingTable()
        return ModelMatch(model: model, suffixes: ReasoningTiers.mergedSuffixes(
            for: model, price: pricing.find, directPrice: pricing.findDirect))
    }

    /// 原始模型名 → 统计口径的模型名。这批模型里没有一个带档位 / tiered 后缀时不读价格表、原样返回。
    func statisticsModelResolver(_ db: OpaquePointer, models: Set<String>) -> (String) -> String {
        guard models.contains(where: { !ReasoningTiers.mergeTargets($0).isEmpty }) else { return { $0 } }
        let pricing = PricingTable.load(db) ?? PricingTable()
        return { ReasoningTiers.statisticsModel($0, price: pricing.find, directPrice: pricing.findDirect) }
    }
}
