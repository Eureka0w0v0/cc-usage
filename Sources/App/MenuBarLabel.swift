import SwiftUI
import AppKit

// MARK: - 菜单栏常驻

/// 菜单栏图标缓存：⚡ 每次 composite 走 `withSymbolConfiguration` 都会新建一张 NSImage，
/// 品牌图标也没必要每帧再查一次命名表。两者进程内恒定，取一次留着。
@MainActor
private enum MBIcons {
    static let bolt: NSImage? = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold))

    private static var brands: [String: NSImage] = [:]
    static func brand(_ name: String) -> NSImage? {
        if let hit = brands[name] { return hit }
        guard let img = NSImage(named: name) else { return nil }
        brands[name] = img
        return img
    }
}

/// 菜单栏合成图缓存。MenuBarLabel 以 @ObservedObject 订阅 PanelModel，任何 @Published 变动
/// （含 label 根本不读的 snap/error/quotaTiers）都会重求 body，而内容绝大多数轮次没变。
/// 按「内容 + ⚡ 开关 + 宽度上限」做 key：命中就复用同一个 NSImage 实例——省掉 TextKit 测量
/// 与光栅化，也避免 SwiftUI 每轮拿到新实例去重设状态项、白白重排。只在主线程访问。
@MainActor
enum MBLabelCache {
    private static var key = ""
    private static var image: NSImage?
    private static var natural: CGFloat = 0

    /// 当前内容未截断的自然宽度，供 PanelModel 的宽度 governor 判断。
    static var currentNatural: CGFloat { natural }

    static func hit(_ k: String) -> (image: NSImage, natural: CGFloat)? {
        guard k == key, let image else { return nil }
        return (image, natural)
    }

    static func store(_ k: String, image: NSImage, natural: CGFloat) {
        key = k
        self.image = image
        self.natural = natural
    }
}

struct MenuBarLabel: View {
    @ObservedObject var model: PanelModel

    /// 一个「按周期分组」的文本码片：同周期的 Tokens/花费 合成一段，如「D:1M·$0.1」。
    private struct Seg: Identifiable { let id: String; let text: String }

    private var segments: [Seg] {
        var segs: [Seg] = []
        // 每个开启的周期一段，前缀 D/W/M（Day/Week/Month）；同周期的 Tokens/花费 合并为 "D:1M·$0.1"。
        // 多选各自独立出现，如 D 用量 + W 用量 → "D:1M W:1M"。
        func add(_ letter: String, _ sum: UsageSummary?, _ tok: Bool, _ cost: Bool) {
            guard tok || cost else { return }
            // 数据未到（冷启动、或刚勾上还没补到这一轮）时占位，别整段消失——
            // 否则 label 会先短后长跳一下，还会白白惊动宽度 governor。
            guard let s = sum else { segs.append(Seg(id: letter, text: "\(letter):—")); return }
            var parts: [String] = []
            if tok  { parts.append(Fmt.tokensCompact(s.tokensProcessed)) }
            if cost { parts.append(Fmt.costCompact(s.cost)) }
            segs.append(Seg(id: letter, text: "\(letter):\(parts.joined(separator: "·"))"))
        }
        add("D", model.mbToday, model.mbTokToday, model.mbCostToday)
        add("W", model.mbWeek,  model.mbTokWeek,  model.mbCostWeek)
        add("M", model.mbMonth, model.mbTokMonth, model.mbCostMonth)
        return segs
    }

    private func tier(_ name: String) -> QuotaTier? { model.quotaTiers.first { $0.name == name } }

    /// 默认全宽；只有 PanelModel 的宽度 governor（MenuBarWidthGovernor.swift）判定状态项
    /// 真被 macOS 挤出菜单栏时才给出 mbWidthCap，由 composite 尾部截断。
    var body: some View {
        // 整条 label 合成为单张模板 NSImage（其自身宽度即上限，收缩由 composite 内截断实现）。
        // MenuBarExtra label 实测只有「单 Image」可靠——多段 Text 会被截断、SF Symbol 塞 Text
        // 渲染空白；品牌图标要与文本交错，只能整体合成单图，isTemplate 让明暗/失焦自动着色。
        Image(nsImage: composite)
            .onAppear { model.start() }
    }

    /// 一段菜单栏内容：品牌图标 + 该 AI 的文本。All 段无图标（⚡ 就是本应用标识）。
    /// 一个额度码片。pct = nil 表示勾了但没数据（没装 / 未登录 / 扫不到快照）。
    /// 额度不再混进文本段——它要自绘（进度条 / 危险胶囊），跟用量文本分开建模。
    private struct QuotaChip {
        let label: String        // 窗口时长（5H/7D/30D）或模型家族名
        let pct: Double?
        var speech: String {
            guard let pct else { return label == "—" ? "quota unavailable" : "\(label) unavailable" }
            return "\(label) \(Int(pct.rounded()))% used"
        }
    }

    /// 一段菜单栏内容：品牌图标 + 用量文本 + 额度码片。All 段无图标（⚡ 就是本应用标识）。
    /// title = 该段的可读名（VoiceOver 用——图标念不出来）。All 段无图标也无名字。
    private struct Piece {
        let icon: String?
        let title: String?
        let text: String          // 用量段 D/W/M，可能为空
        let quotas: [QuotaChip]
    }

    private var pieces: [Piece] {
        var out: [Piece] = []
        let all = segments.map(\.text).joined(separator: "  ")
        if !all.isEmpty { out.append(Piece(icon: nil, title: nil, text: all, quotas: [])) }
        for app in MBApp.allCases {
            let a = app.rawValue
            let sums = model.mbAppSummaries[a]
            var segs: [String] = []
            var quotas: [QuotaChip] = []
            func add(_ letter: String, _ s: UsageSummary?, _ tokKey: String, _ costKey: String) {
                let tok = model.chipOn(tokKey), cost = model.chipOn(costKey)
                guard tok || cost else { return }
                guard let s else { segs.append("\(letter):—"); return }   // 同上：占位撑住宽度
                var p: [String] = []
                if tok  { p.append(Fmt.tokensCompact(s.tokensProcessed)) }
                if cost { p.append(Fmt.costCompact(s.cost)) }
                segs.append("\(letter):\(p.joined(separator: "·"))")
            }
            add("D", sums?.today, "\(a).tokens.today", "\(a).cost.today")
            add("W", sums?.week,  "\(a).tokens.week",  "\(a).cost.week")
            add("M", sums?.month, "\(a).tokens.month", "\(a).cost.month")
            // 额度段跟在所属 AI 段内：Claude 走官方接口两档，Codex 走本地快照（窗口自适应）
            if app == .claude {
                // 窗口标签一律用时长。原来七日额度叫 "W"，而 All 组的 "W" 是「本周用量」——
                // 两个 W 同屏含义不同，没法读，这里改 7D 彻底分开。
                if model.mbQuota5H   { quotas.append(QuotaChip(label: "5H", pct: tier("five_hour")?.utilization)) }
                if model.mbQuotaWeek { quotas.append(QuotaChip(label: "7D", pct: tier("seven_day")?.utilization)) }
            }
            if app == .codex {
                let anyOn = model.mbAppChips.contains { $0.hasPrefix("codex.quota.") }
                let sel = model.mbCodexQuota.filter { model.chipOn("codex.quota.\($0.label)") }
                if anyOn && model.mbCodexQuota.isEmpty {
                    quotas.append(QuotaChip(label: "—", pct: nil))   // 勾了但没扫到快照（没装 Codex / 会话被清）
                } else {
                    quotas.append(contentsOf: sel.map { QuotaChip(label: $0.label, pct: $0.usedPercent) })
                }
            }
            if app == .antigravity {
                // 按家族折叠：同家族共用配额，避免菜单栏 "Flash 10% Flash 10%…" 重复
                let pools = AntigravityQuota.pools(model.mbAntigravityQuota)
                let anyOn = model.mbAppChips.contains { $0.hasPrefix("antigravity.quota.") }
                let sel = pools.filter { model.chipOn("antigravity.quota.\($0.family)") }
                if anyOn && pools.isEmpty {
                    quotas.append(QuotaChip(label: "—", pct: nil))   // 勾了但没查到（没装 / 未登录 / 网络失败）
                } else {
                    quotas.append(contentsOf: sel.map { QuotaChip(label: $0.family, pct: $0.usedPercent) })
                }
            }
            if !segs.isEmpty || !quotas.isEmpty {
                out.append(Piece(icon: app.iconAsset, title: app.title,
                                 text: segs.joined(separator: " "), quotas: quotas))
            }
        }
        return out
    }

    /// pieces → 单张黑色模板图：⚡（可关）+ [All 文本] + [品牌图标 文本]…，空段兜底 "CC"。
    /// 默认不限宽；仅当 PanelModel 检测到状态项被挤掉、给出动态上限时才尾部截断 "…"。
    private var composite: NSImage {
        let ps = pieces
        // 动态上限（窗口宽 → 图像宽留 ~12pt 状态项内边距余量）
        let cap = model.mbWidthCap.map { max(60, $0 - 12) } ?? .greatestFiniteMagnitude
        // 成图只由这几样决定：内容（含额度值）、⚡ 与进度条开关、宽度上限。
        // 都没变就没必要重新测量+光栅化。\u{1} 系控制字符作分隔，正常内容里不会出现。
        let key = ps.reduce("\(model.mbShowIcon)|\(model.mbQuotaBar)|\(cap)|\(Self.imageHeight)") { acc, p in
            let qs = p.quotas
                .map { "\($0.label)\u{2}\($0.pct.map { Int($0.rounded()) } ?? -1)" }
                .joined(separator: "\u{3}")
            return "\(acc)\u{1}\(p.icon ?? "")\u{1}\(p.text)\u{1}\(qs)"
        }
        if let hit = MBLabelCache.hit(key) { return hit.image }

        // 等宽数字：系统字体的比例数字会让 562.7K → 1.2M 这种纯数值变化也改宽度，
        // 状态项每刷新一轮就左右跳，还会误触 governor 的「自然宽度突变>30pt=内容结构变了」判定。
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let str = NSMutableAttributedString()
        /// 把一张图当字形插进串里，按 cap height 垂直居中。
        func appendImage(_ img: NSImage, height h: CGFloat) {
            let w = img.size.height > 0 ? img.size.width / img.size.height * h : h
            let att = NSTextAttachment()
            att.image = img
            att.bounds = CGRect(x: 0, y: (font.capHeight - h) / 2, width: w, height: h)
            str.append(NSAttributedString(attachment: att))
        }
        func appendIcon(_ img: NSImage) {          // 品牌 / ⚡ 图标：后面跟一个空格
            appendImage(img, height: 14)
            str.append(NSAttributedString(string: " ", attributes: attrs))
        }
        if model.mbShowIcon, let bolt = MBIcons.bolt { appendIcon(bolt) }
        if ps.isEmpty {
            str.append(NSAttributedString(string: "CC", attributes: attrs))
        } else {
            for p in ps {
                if str.length > 0 { str.append(NSAttributedString(string: "  ", attributes: attrs)) }
                if let name = p.icon, let img = MBIcons.brand(name) { appendIcon(img) }
                if !p.text.isEmpty { str.append(NSAttributedString(string: p.text, attributes: attrs)) }
                for q in p.quotas {
                    if str.length > 0 { str.append(NSAttributedString(string: " ", attributes: attrs)) }
                    appendImage(quotaChip(q, font: font), height: Self.chipHeight)
                }
            }
        }
        // 整串统一截断样式（含 attachment 段），超宽时 TextKit 在尾部画 "…"
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        str.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: str.length))

        let bounds = str.boundingRect(
            with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin])
        let natural = ceil(bounds.width) + 1
        let width = min(natural, cap)
        let img = NSImage(size: NSSize(width: width, height: Self.imageHeight), flipped: false) { rect in
            // 高度限一行 → 超宽只会截断，不会折行
            str.draw(with: NSRect(x: 0, y: (rect.height - bounds.height) / 2 - bounds.minY,
                                  width: rect.width, height: bounds.height),
                     options: [.usesLineFragmentOrigin])
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = voiceOverText(ps)   // 合成图本身念不出来，补一句纯文本
        MBLabelCache.store(key, image: img, natural: natural)
        return img
    }

    /// VoiceOver 文案："CC Usage · Claude D:2.2M, 5H 0% used, 7D 25% used"。
    /// 额度画成了图，念不出来，这里必须补回文字。
    private func voiceOverText(_ ps: [Piece]) -> String {
        guard !ps.isEmpty else { return "CC Usage" }
        let body = ps.map { p -> String in
            var parts: [String] = []
            if let t = p.title { parts.append(t) }
            if !p.text.isEmpty { parts.append(p.text) }
            parts += p.quotas.map(\.speech)
            return parts.joined(separator: " ")
        }.joined(separator: ", ")
        return "CC Usage · \(body)"
    }

    // MARK: 额度码片自绘

    /// 合成图高度：跟随菜单栏实际厚度（刘海屏与后续系统版本都可能不是 22），
    /// 留 4pt 上下余量；下限保住原先写死的 18，免得某些场景算出个过矮的值。
    fileprivate static var imageHeight: CGFloat { max(18, NSStatusBar.system.thickness - 4) }

    /// 危险线：到这个百分比就反白成实心胶囊。
    private static let dangerPct: Double = 90
    fileprivate static let chipHeight: CGFloat = 15

    /// 一个额度码片的图：
    /// - 默认「标签 + 进度条」（比 "5H: 25%" 窄约 14pt，且一眼看得出满没满）；
    /// - 关掉进度条开关则是「标签:百分比」；
    /// - ≥ dangerPct 反白成实心胶囊、数字抠空，并强制显示数字（快满了就得看到具体值）。
    ///
    /// 报警不用颜色：整条 label 是模板图，菜单栏底色随深浅色与壁纸变，非模板图很容易
    /// 撞成看不清；实心胶囊在任何底色下都是一块高对比实块，是唯一到处都成立的做法。
    private func quotaChip(_ q: QuotaChip, font: NSFont) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        guard let pct = q.pct else { return chipImage(q.label, bar: nil, danger: false, attrs: attrs) }
        let danger = pct >= Self.dangerPct
        if danger || !model.mbQuotaBar {
            return chipImage("\(q.label):\(Int(pct.rounded()))%", bar: nil, danger: danger, attrs: attrs)
        }
        return chipImage(q.label, bar: pct, danger: false, attrs: attrs)
    }

    private func chipImage(_ text: String, bar: Double?, danger: Bool,
                           attrs: [NSAttributedString.Key: Any]) -> NSImage {
        let str = NSAttributedString(string: text, attributes: attrs)
        let tw = ceil(str.size().width)
        let barW: CGFloat = 18, barH: CGFloat = 6, gap: CGFloat = 3
        let padX: CGFloat = danger ? 4 : 0
        let w = padX * 2 + tw + (bar != nil ? gap + barW : 0)
        let h = Self.chipHeight
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let ty = (rect.height - str.size().height) / 2
            if danger {
                // 实心胶囊 + 抠字：模板图里就是一块菜单栏色实块、数字被挖空
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0, dy: 0.5), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current?.cgContext.setBlendMode(.destinationOut)
                str.draw(at: NSPoint(x: padX, y: ty))
                NSGraphicsContext.current?.cgContext.setBlendMode(.normal)
            } else {
                str.draw(at: NSPoint(x: padX, y: ty))
            }
            if let pct = bar {
                let x = padX + tw + gap
                let track = NSRect(x: x, y: (rect.height - barH) / 2, width: barW, height: barH)
                let path = NSBezierPath(roundedRect: track, xRadius: barH / 2, yRadius: barH / 2)
                NSColor.black.withAlphaComponent(0.25).setFill()
                path.fill()
                let frac = min(1, max(0, pct / 100))
                if frac > 0.02 {                      // 0% 只留空槽
                    // 裁到轨道再填平头矩形。直接画圆角矩形的话，低百分比会缩成一个圆点，
                    // 看着像「某个东西亮着」而不是「填了多少」。
                    NSGraphicsContext.saveGraphicsState()
                    path.addClip()
                    NSColor.black.setFill()
                    NSRect(x: x, y: track.minY, width: barW * frac, height: barH).fill()
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            return true
        }
    }
}
