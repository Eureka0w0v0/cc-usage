import Foundation

// 命令行验证：跑 UsageStore 对着真实 cc-switch.db，打印数字，人工比对面板。
// 编译: swiftc Sources/Shared/UsageStore.swift Sources/Shared/SessionOverlay.swift \
//         Sources/Shared/Formatting.swift Tools/verify/main.swift -o /tmp/ccverify -lsqlite3

func fmtTokens(_ n: Int64) -> String { Fmt.tokens(n) }

let store = UsageStore()
do {
    let snap = try store.snapshot()
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm"

    print("═══════════ CC Usage Widget · 数据层验证 ═══════════")
    print("db: \(UsageStore.defaultPath)")
    if let last = snap.lastEventAt { print("最新事件: \(df.string(from: last))") }
    print("")
    print("── 今日 (对照 cc-switch 面板顶部卡片) ──")
    let t = snap.today
    print("  Tokens Processed : \(fmtTokens(t.tokensProcessed))  (\(t.tokensProcessed))")
    print("  Fresh Input      : \(fmtTokens(t.input))")
    print("  Output           : \(fmtTokens(t.output))")
    print("  Creation         : \(fmtTokens(t.creation))")
    print("  Hit              : \(fmtTokens(t.hit))")
    print("  Cache Hit Rate   : \(String(format: "%.1f%%", t.cacheHitRate * 100))")
    print("  Total Requests   : \(t.requests)")
    print("  Total Cost       : $\(String(format: "%.4f", t.cost))")
    print("")
    print("── 累计 (整个明细表) ──")
    let c = snap.cumulative
    print("  Tokens: \(fmtTokens(c.tokensProcessed))   Cost: $\(String(format: "%.2f", c.cost))   Reqs: \(c.requests)")
    print("")
    print("── 今日小时走势 (非空桶) ──")
    let hf = DateFormatter(); hf.dateFormat = "HH:mm"
    for b in snap.trend where b.tokens > 0 || b.cost > 0 {
        let ts = Date(timeIntervalSince1970: TimeInterval(b.startTs))
        print("  \(hf.string(from: ts))  tokens=\(fmtTokens(b.tokens))  hit=\(fmtTokens(b.hit))  cost=$\(String(format: "%.3f", b.cost))")
    }
    print("  (共 \(snap.trend.count) 桶)")
    print("════════════════════════════════════════════════════")
} catch {
    FileHandle.standardError.write("验证失败: \(error)\n".data(using: .utf8)!)
    exit(1)
}
