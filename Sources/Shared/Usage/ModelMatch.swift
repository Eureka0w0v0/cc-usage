import Foundation

/// 一次查询里解析好的模型筛选：选中的模型名，加上会并到它名下的推理档后缀（`ReasoningTiers.mergedSuffixes`，
/// 小写、带前导 `-`）。所有吃模型筛选的查询都经它出条件，库里的行（SQL）和叠加行（Swift）用的是同一个判断。
///
/// 条件对齐上游 UsageFilter::push_to（v4.0.36）：模型名精确相等；或者前 n 个字符等于模型名、剩下的部分转小写后在后缀表里。
/// SQLite 的 `SUBSTR` 按字符计、内置 `LOWER` 只转 ASCII、`=` 逐字节比——`matches` 按 UTF-8 字节比前缀、只转 ASCII，
/// 两边对任何字符串给出同一个结果。
struct ModelMatch: Equatable {
    let model: String
    let suffixes: [String]

    /// `expr` 是有效计价模型的 SQL 表达式；返回条件和按 `?` 出现顺序排好的参数。
    func sql(_ expr: String) -> (String, [SQLBind]) {
        guard !suffixes.isEmpty else { return ("\(expr) = ?", [.text(model)]) }
        let n = Int64(model.unicodeScalars.count)
        let placeholders = Array(repeating: "?", count: suffixes.count).joined(separator: ", ")
        let condition = "(\(expr) = ? OR (SUBSTR(\(expr), 1, ?) = ? AND LOWER(SUBSTR(\(expr), ?)) IN (\(placeholders))))"
        return (condition, [.text(model), .int(n), .text(model), .int(n + 1)] + suffixes.map { .text($0) })
    }

    /// Swift 侧的同一个判断（叠加行用）。模型名的 UTF-8 字节是值的前缀，等价于值的前 n 个字符等于模型名。
    func matches(_ value: String) -> Bool {
        if value.utf8.elementsEqual(model.utf8) { return true }
        guard !suffixes.isEmpty, value.utf8.count > model.utf8.count,
              value.utf8.starts(with: model.utf8) else { return false }
        let rest = String(decoding: value.utf8.dropFirst(model.utf8.count), as: UTF8.self)
        return suffixes.contains(ReasoningTiers.asciiLowercased(rest))
    }
}
