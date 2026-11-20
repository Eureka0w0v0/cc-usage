import Foundation

/// 用量行的计费倍率（`proxy_request_logs.cost_multiplier`，TEXT）怎么读。
///
/// 上游（cc-switch）用 rust_decimal 解析：解析失败按 1 倍；解析出 0 就是免费，这行的总价本来就是 0，
/// 补价时直接跳过（v4.0.36 `b044f4b0`）。v4.0.36 的「供应商费用倍率」表单允许填 0，这种行会真实出现。
///
/// 这里只认 cc-switch 实际写入的十进制写法——以数字开头、只含数字和至多一个小数点（`1`、`1.0`、`0.5`、`0`、`2.`），
/// 取它的值；其他（空串、带空格、正负号、`.5`、科学计数）一律按 1 倍。正负号和 `.5` 上游能解析，
/// 但 cc-switch 写入的都是 normalize 过的非负十进制，不会出现这两种写法。
///
/// Swift（请求日志逐行补价）和 SQL（汇总聚合）必须是同一条规则，否则同一行在 Hero 和明细表里会算出两个数。
/// 早先两处都把 0 当成 1 倍（SQL 是 `NULLIF(…, 0)`，Swift 是 `== 0 ? 1`），零倍率的行被按全价补上。
enum CostMultiplier {
    /// 列值 → 倍率。nil 和认不出的写法都是 1。
    static func value(_ raw: String?) -> Double {
        guard let raw, isPlainDecimal(raw), let v = Double(raw) else { return 1 }
        return v
    }

    /// 同一条规则的 SQLite 标量表达式（`column` 是列名或绑定参数）。NULL 落到 ELSE，按 1 倍。
    static func sql(_ column: String) -> String {
        "(CASE WHEN \(column) GLOB '[0-9]*' AND \(column) NOT GLOB '*[^0-9.]*'"
            + " AND \(column) NOT GLOB '*.*.*' THEN CAST(\(column) AS REAL) ELSE 1.0 END)"
    }

    /// 以 ASCII 数字开头，只含 ASCII 数字和至多一个 `.`。
    static func isPlainDecimal(_ s: String) -> Bool {
        guard let first = s.utf8.first, isDigit(first) else { return false }
        var dots = 0
        for b in s.utf8 {
            if b == UInt8(ascii: ".") {
                dots += 1
                if dots > 1 { return false }
            } else if !isDigit(b) {
                return false
            }
        }
        return true
    }

    private static func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
}
