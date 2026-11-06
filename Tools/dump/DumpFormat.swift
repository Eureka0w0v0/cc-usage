import Foundation
import SQLite3

// 查询结果 → 一行文本。逐字段全打：搬家把哪个字段弄丢或算偏，diff 就落在那个字段上。
// 浮点打 17 位有效数字，差一个 ulp 也看得见。

enum DumpFormat {
    static func num(_ v: Double) -> String { String(format: "%.17g", v) }
    static func opt<T>(_ v: T?) -> String { v.map { "\($0)" } ?? "nil" }

    static func summary(_ s: UsageSummary) -> String {
        "req=\(s.requests) ok=\(s.successes) in=\(s.input) out=\(s.output) cc=\(s.creation) cr=\(s.hit)"
            + " cost=\(num(s.cost)) rate=\(num(s.successRate)) tok=\(s.tokensProcessed) hit=\(num(s.cacheHitRate))"
    }

    static func bucket(_ b: TrendBucket) -> String {
        "\(b.startTs) n=\(b.requestCount) in=\(b.input) out=\(b.output) cc=\(b.creation) cr=\(b.hit) cost=\(num(b.cost))"
    }

    static func performance(_ p: StatsPerformance) -> String {
        "so=\(p.speedOutputTokens) sg=\(p.speedGenerationMs) eo=\(p.estSpeedOutputTokens) ed=\(p.estSpeedDurationMs)"
            + " ft=\(opt(p.firstTokenMedianMs)) eft=\(opt(p.estFirstTokenMedianMs))"
    }

    static func provider(_ r: ProviderStatRow) -> String {
        "\(r.providerId)|\(r.appType)|\(r.providerName) n=\(r.requestCount) tok=\(r.totalTokens)"
            + " cost=\(num(r.totalCost)) rate=\(num(r.successRate)) lat=\(r.avgLatencyMs) \(performance(r.performance))"
    }

    static func model(_ r: ModelStatRow) -> String {
        "\(r.model) n=\(r.requestCount) tok=\(r.totalTokens) cost=\(num(r.totalCost))"
            + " avg=\(num(r.avgCostPerRequest)) rate=\(num(r.successRate)) \(performance(r.performance))"
    }

    static func log(_ r: RequestLogRow) -> String {
        [r.requestId, r.providerId, r.providerName, r.appType, r.model, opt(r.requestModel), opt(r.pricingModel),
         r.costMultiplier, "\(r.inputTokens)", "\(r.outputTokens)", "\(r.cacheReadTokens)", "\(r.cacheCreationTokens)",
         r.inputCostUsd, r.outputCostUsd, r.cacheReadCostUsd, r.cacheCreationCostUsd, r.totalCostUsd,
         "\(r.isStreaming)", "\(r.latencyMs)", opt(r.firstTokenMs), opt(r.durationMs), "\(r.statusCode)",
         opt(r.errorMessage), "\(r.createdAt)", opt(r.dataSource)].joined(separator: "|")
    }

    /// 叠加行全部字段。sourceFile 只取最后两级：回放的工作目录每次不同，文件身份靠相对路径就够。
    static func overlay(_ r: OverlayRow) -> String {
        let file = r.sourceFile.split(separator: "/").suffix(2).joined(separator: "/")
        return [r.requestId, r.model, "\(r.createdAt)", "\(r.input)", "\(r.output)", "\(r.cacheRead)",
                "\(r.cacheCreation)", "\(r.realTotalTokens)", num(r.inputCost), num(r.outputCost), num(r.cacheReadCost),
                num(r.cacheCreationCost), num(r.totalCost), "\(r.hasStopReason)", file, r.appType, r.providerId,
                r.providerName, r.dataSource, "\(r.latencyMs)", opt(r.firstTokenMs), "\(r.statusCode)",
                opt(r.errorMessage), opt(r.requestModel)].joined(separator: "|")
    }

    /// FNV-1a：逐 tick 回放每一拍打一个摘要，比整份行短得多，差异还是一眼能定位到哪一拍。
    static func digest(_ lines: [String]) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for line in lines {
            for b in line.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
            h = (h ^ 0x0A) &* 0x100000001b3
        }
        return String(h, radix: 16)
    }
}

/// 打开库，失败就退出：对拍工具里任何打不开的情况都不该被当成「结果一样」。
func dumpOpen(_ path: String, flags: Int32) -> OpaquePointer {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let handle = db else {
        FileHandle.standardError.write(Data("打不开 \(path)\n".utf8))
        exit(3)
    }
    return handle
}
