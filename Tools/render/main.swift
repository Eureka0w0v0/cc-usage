import AppKit
import SwiftUI

// 离屏渲染对拍：设置面板和菜单栏合成图是 App 层唯一没有单测的 UI，改它们之前先留一份输出，改完逐字节比。
// 不起 App、不开窗（窗口不 orderFront），HOME 指到临时目录，UserDefaults 用本工具自己的域，见 render.sh。
//
// 用法：ccrender <BrandIcons 目录> <输出目录>

let brandDir = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]

guard NSHomeDirectory().contains("ccrender-home") else {
    FileHandle.standardError.write(Data("必须经 render.sh 跑：UserDefaults 要隔离\n".utf8))
    exit(2)
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.prohibited)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: brandDir)) ?? [] where name.hasSuffix(".png") {
        let image = NSImage(contentsOfFile: (brandDir as NSString).appendingPathComponent(name))
        image?.setName((name as NSString).deletingPathExtension)
    }
    RenderScenarios(outDir: outDir).run()
}

@MainActor
struct RenderScenarios {
    let outDir: String
    private let defaults = UserDefaults.standard
    private let groupKeys = [MBKey.groupAll, MBKey.groupClaude, MBKey.groupCodex, MBKey.groupGemini, MBKey.groupOpencode,
                             MBKey.groupAntigravity, MBKey.groupGrok, MBKey.groupPi, MBKey.groupMcode, MBKey.groupKimi,
                             MBKey.groupOmp, MBKey.groupDsh]

    /// 额度开关只从 UserDefaults 设：mbQuota5H / mbQuotaWeek 的 didSet 会立刻拉官方额度，渲染绝不能走到网络和钥匙串。
    private func model(chips: [String] = [], quota5H: Bool = false, quotaWeek: Bool = false) -> PanelModel {
        defaults.set(chips, forKey: MBKey.appChips)
        defaults.set(quota5H, forKey: MBKey.quota5H)
        defaults.set(quotaWeek, forKey: MBKey.quotaWeek)
        return PanelModel(store: UsageStore(path: "/nonexistent/render.db", sources: []))
    }

    private func expand(_ keys: [String]) {
        for key in groupKeys { defaults.removeObject(forKey: key) }
        for key in keys { defaults.set(true, forKey: key) }
    }

    private func png(_ view: some View, name: String) {
        let host = NSHostingView(rootView: view.frame(width: 312).padding(14).background(Color.black)
            .environment(\.colorScheme, .dark))
        host.frame = CGRect(x: 0, y: 0, width: 340, height: 1600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { exit(3) }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = (outDir as NSString).appendingPathComponent("\(name).png")
        FileManager.default.createFile(atPath: path, contents: rep.representation(using: .png, properties: [:]))
    }

    private var claude: [QuotaTier] {
        [QuotaTier(name: "five_hour", utilization: 12, resetsAt: nil, planLabel: "Ultra"),
         QuotaTier(name: "seven_day", utilization: 91, resetsAt: nil, planLabel: "Ultra"),
         QuotaTier(name: "seven_day_opus", utilization: 3, resetsAt: nil, planLabel: "Ultra")]
    }
    private var codex: [(String, Double)] { [("5H", 8), ("7D", 55), ("30D", 99)] }
    private var agy: [AntigravityTier] {
        [AntigravityTier(bucketId: "gemini-weekly", label: "Gemini 7D", usedPercent: 10.4, resetAt: nil),
         AntigravityTier(bucketId: "3p-weekly", label: "Claude 7D", usedPercent: 85, resetAt: nil)]
    }

    func run() {
        settings()
        labels()
    }

    private func settings() {
        expand([])
        png(MenuBarSettingsView(model: model()), name: "settings-default")

        expand(groupKeys)
        png(MenuBarSettingsView(model: model()), name: "settings-all-open-empty")

        let chips = ["claude.tokens.today", "claude.cost.week", "codex.tokens.month", "codex.quota.7D", "gemini.cost.today",
                     "opencode.tokens.week", "agy.tokens.today", "agy.quota.3p-weekly", "grokbuild.cost.month",
                     "pi.tokens.today", "mcode.cost.week", "kimi.tokens.month", "omp.cost.today", "dsh.tokens.week"]
        let full = model(chips: chips, quota5H: true)
        setQuota(full, claude: claude, codex: codex, agy: agy)
        png(MenuBarSettingsView(model: full), name: "settings-all-open-full")

        expand([MBKey.groupClaude, MBKey.groupGrok, MBKey.groupAntigravity])
        png(MenuBarSettingsView(model: full), name: "settings-some-open")
    }

    private func labels() {
        var lines: [String] = []
        func record(_ name: String, _ m: PanelModel) {
            let image = MenuBarLabel(model: m).composite
            let bytes = image.tiffRepresentation ?? Data()
            lines.append([name, "\(image.size.width)x\(image.size.height)", "natural=\(MBLabelCache.currentNatural)",
                          "bytes=\(bytes.count)", "hash=\(bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 })",
                          image.accessibilityDescription ?? "nil"].joined(separator: " | "))
        }
        func summary(_ tokens: Int64, _ cost: Double) -> UsageSummary {
            var s = UsageSummary()
            s.input = tokens
            s.cost = cost
            return s
        }

        defaults.set(true, forKey: MBKey.tokToday)
        defaults.set(true, forKey: MBKey.costToday)
        let plain = model()
        record("default-no-data", plain)
        plain.mbToday = summary(2_345_678, 12.5)
        record("today-only", plain)
        plain.mbTokWeek = true
        plain.mbWeek = summary(9_000_000, 45)
        plain.mbCostMonth = true
        record("week-and-month-placeholder", plain)
        plain.mbShowIcon = false
        record("no-bolt", plain)

        let quota = model(chips: ["codex.quota.7D", "codex.quota.30D", "agy.quota.gemini-weekly", "agy.quota.3p-weekly"],
                          quota5H: true, quotaWeek: true)
        quota.mbTokToday = false
        quota.mbCostToday = false
        record("quota-no-data", quota)
        setQuota(quota, claude: claude, codex: codex, agy: agy)
        record("quota-bars", quota)
        quota.mbQuotaBar = false
        record("quota-numbers", quota)

        let perApp = model(chips: ["claude.tokens.today", "claude.cost.today", "claude.tokens.week", "codex.cost.month",
                                   "grokbuild.tokens.today", "pi.cost.week", "dsh.tokens.month", "omp.tokens.today"])
        perApp.mbTokToday = false
        perApp.mbCostToday = false
        record("apps-placeholder", perApp)
        perApp.mbAppSummaries = ["claude": .init(today: summary(1_000, 0.5), week: summary(5_000, 2), month: nil),
                                 "codex": .init(today: nil, week: nil, month: summary(9_000, 3)),
                                 "grokbuild": .init(today: summary(0, 0), week: nil, month: nil)]
        record("apps-partial", perApp)
        perApp.mbWidthCap = 120
        record("apps-capped", perApp)

        let empty = model()
        empty.mbTokToday = false
        empty.mbCostToday = false
        empty.mbShowIcon = false
        record("empty-falls-back-to-CC", empty)

        let path = (outDir as NSString).appendingPathComponent("labels.txt")
        FileManager.default.createFile(atPath: path, contents: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
