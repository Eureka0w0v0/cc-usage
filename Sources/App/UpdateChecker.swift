import Foundation
import Combine
import AppKit
import SwiftUI

/// GitHub Releases 新版本检查 + 一键更新。
///
/// 检查：匿名调用 /releases/latest（无需 token，匿名限流 60 次/小时，这里 6 小时一查远够），
/// tag 与当前 CFBundleShortVersionString 逐段数字比较；离线/限流/解析失败一律静默，
/// 绝不打扰。结果缓存 UserDefaults → 下次启动无网也能立即恢复提示。
///
/// 更新：下载 Release 的 .zip 资产 → ditto 解压 → 去 quarantine → 写一段等待本进程退出的
/// 脚本 detached 执行（先 ditto 到 staging 再原子换入，中途失败不毁现有 app）→ 自杀，
/// 脚本把新版本放回当前运行路径并 open 拉起。Release 没挂 .zip 时按钮退化为跳网页。
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String     // 规范化版本号（无 v 前缀），如 "1.2"
        let url: URL            // Release 页面（html_url），手动兜底跳这里
        let zipURL: URL?        // .zip 资产下载地址，一键更新的下载源
    }

    enum UpdateState: Equatable {
        case idle
        case downloading(Int)   // 已下载百分比；-1 = 服务器没给 Content-Length
        case installing
        case failed(String)
    }

    /// 非 nil = 有比当前更新的版本，UI 据此渲染提示按钮。
    @Published private(set) var available: Release?
    @Published private(set) var updateState: UpdateState = .idle

    private static let api = "https://api.github.com/repos/Eureka0w0v0/cc-usage/releases/latest"
    private static let interval: TimeInterval = 6 * 3600
    private enum Key {
        static let schema    = "update.cacheSchema"     // 缓存结构版本，不匹配即作废重查
        static let lastCheck = "update.lastCheckAt"     // 上次成功检查的时间戳（秒）
        static let version   = "update.latestVersion"   // 缓存的最新版本号
        static let url       = "update.latestURL"       // 缓存的 Release 页面
        static let zip       = "update.latestZipURL"    // 缓存的 .zip 资产地址
    }
    /// 缓存结构版本。v1 只存版本号+页面地址（老版本写的），v2 起含 zip 资产地址——
    /// 老缓存恢复出来 zipURL 恒为 nil，一键更新会错误退化成跳网页，必须作废。
    private static let cacheSchema = 2

    private var timer: AnyCancellable?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        restoreFromCache()
        // 首查延迟 5 秒：避开冷启动的 overlay 全量扫描，不跟数据层抢 IO
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.checkIfDue()
        }
        timer = Timer.publish(every: Self.interval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in Task { await self?.checkIfDue() } }
    }

    /// 打开 Release 页面（更新失败的手动兜底 / 无 .zip 资产时的退化路径）。
    func openReleasePage() {
        if let url = available?.url { NSWorkspace.shared.open(url) }
    }

    /// 一键更新：下载 → 解压 → 替换自身 → 重启。在途/失败态不可重入。
    func performUpdate() {
        guard let rel = available else { return }
        guard let zip = rel.zipURL else { openReleasePage(); return }
        switch updateState {
        case .idle, .failed: break
        default: return
        }
        updateState = .downloading(0)
        let target = Bundle.main.bundleURL
        // 强持有 self：更新流程的生命周期不会超过 app；@MainActor 类隐式 Sendable，跨闭包安全。
        Task.detached(priority: .userInitiated) {
            do {
                let zipFile = try await Self.download(zip) { pct in
                    Task { @MainActor in
                        if case .downloading = self.updateState { self.updateState = .downloading(pct) }
                    }
                }
                await MainActor.run { self.updateState = .installing }
                let newApp = try Self.extractApp(from: zipFile)
                try await Self.swapAndRelaunch(newApp: newApp, target: target)
            } catch {
                await MainActor.run { self.updateState = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: - 检查

    private var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 上次检查结果落过盘就先恢复显示——升级完成后 cached == current，guard 不过，提示自然消失。
    private func restoreFromCache() {
        let d = UserDefaults.standard
        guard d.integer(forKey: Key.schema) == Self.cacheSchema else {
            d.removeObject(forKey: Key.lastCheck)   // 旧结构缓存作废：解除节流，启动后立即重查
            return
        }
        guard let v = d.string(forKey: Key.version),
              let s = d.string(forKey: Key.url), let u = URL(string: s),
              Self.isNewer(v, than: current) else { return }
        let zip = d.string(forKey: Key.zip).flatMap(URL.init(string:))
        available = Release(version: v, url: u, zipURL: zip)
    }

    /// 距上次成功检查不足间隔则跳过网络（重启不重置节奏）；留 60s 容差吸收定时器抖动。
    private func checkIfDue() async {
        let last = UserDefaults.standard.double(forKey: Key.lastCheck)
        guard Date().timeIntervalSince1970 - last >= Self.interval - 60 else { return }
        await check()
    }

    private func check() async {
        guard let url = URL(string: Self.api) else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let html = obj["html_url"] as? String,
              let page = URL(string: html)
        else { return }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = obj["assets"] as? [[String: Any]] ?? []
        let zipStr = assets.compactMap { $0["browser_download_url"] as? String }
            .first { $0.hasSuffix(".zip") }
        let d = UserDefaults.standard
        d.set(Self.cacheSchema, forKey: Key.schema)
        d.set(Date().timeIntervalSince1970, forKey: Key.lastCheck)
        d.set(version, forKey: Key.version)
        d.set(html, forKey: Key.url)
        d.set(zipStr, forKey: Key.zip)
        available = Self.isNewer(version, than: current)
            ? Release(version: version, url: page, zipURL: zipStr.flatMap(URL.init(string:)))
            : nil
    }

    /// 逐段数字比较："1.10" > "1.9"、"1.1.1" > "1.1"；非数字段按 0 处理。
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: - 更新执行（全部后台线程，不占主 actor）

    private struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }

    /// 流式下载到临时文件，按 128KB 块写盘并回报百分比。
    private nonisolated static func download(
        _ url: URL, progress: @escaping @Sendable (Int) -> Void
    ) async throws -> URL {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw Err("download HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let total = resp.expectedContentLength
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-update-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var buf = Data(); buf.reserveCapacity(1 << 17)
        var written: Int64 = 0
        var lastPct = -2
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 17 {
                try handle.write(contentsOf: buf)
                written += Int64(buf.count)
                buf.removeAll(keepingCapacity: true)
                let pct = total > 0 ? Int(written * 100 / total) : -1
                if pct != lastPct { lastPct = pct; progress(pct) }
            }
        }
        if !buf.isEmpty { try handle.write(contentsOf: buf) }
        return file
    }

    /// ditto 解压并返回包内的 .app。
    private nonisolated static func extractApp(from zip: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-xk", zip.path, dir.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Err("unzip failed (ditto exit \(p.terminationStatus))") }
        let apps = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw Err("no .app in archive") }
        return app
    }

    /// 写替换脚本 detached 执行后退出自身。脚本：等本进程退出（最多 30s）→
    /// ditto 到 staging（失败不动现有 app）→ 去 quarantine → 原子换入 → open 拉起新版本。
    private nonisolated static func swapAndRelaunch(newApp: URL, target: URL) async throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let staging = target.path + ".update-staging"
        let script = """
        #!/bin/bash
        for _ in $(seq 1 150); do kill -0 \(pid) 2>/dev/null || break; sleep 0.2; done
        rm -rf "\(staging)"
        ditto "\(newApp.path)" "\(staging)" || exit 1
        xattr -dr com.apple.quarantine "\(staging)" 2>/dev/null
        rm -rf "\(target.path)" && mv "\(staging)" "\(target.path)"
        open "\(target.path)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccusage-update-\(pid).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [scriptURL.path]
        try p.run()                                     // 不 wait：脚本活得比本进程久
        await MainActor.run { NSApp.terminate(nil) }
    }
}

/// 「发现新版本」提示：compact = 主窗右上角胶囊徽标，非 compact = 菜单栏面板整行。
/// 点击直接一键更新（下载进度 → 安装 → 自动重启）；失败不静默，给出错误 + 手动跳转兜底。
/// 直接观察 UpdateChecker——嵌套 ObservableObject 的变化不会穿透 PanelModel 的
/// objectWillChange，必须由子视图自己 @ObservedObject 才能可靠刷新。
struct UpdateNotice: View {
    @ObservedObject var updater: UpdateChecker
    var compact = false

    var body: some View {
        if let rel = updater.available {
            content(rel)
        }
    }

    @ViewBuilder
    private func content(_ rel: UpdateChecker.Release) -> some View {
        switch updater.updateState {
        case .idle:
            pill("arrow.up.circle.fill", compact ? "v\(rel.version)" : "Update to v\(rel.version)") {
                updater.performUpdate()
            }
            .help(rel.zipURL == nil ? "Open release page" : "Download and install, app relaunches automatically")
        case .downloading(let pct):
            pill("arrow.down.circle",
                 pct >= 0 ? (compact ? "\(pct)%" : "Downloading… \(pct)%") : "Downloading…")
        case .installing:
            pill("hourglass", compact ? "Installing…" : "Installing… app will relaunch")
        case .failed(let msg):
            if compact {
                pill("exclamationmark.triangle.fill", "Update failed ↗") { updater.openReleasePage() }
                    .help(msg)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Update failed: \(msg)")
                        .font(.caption2).foregroundStyle(.orange)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    pill("safari", "Open release page manually") { updater.openReleasePage() }
                }
            }
        }
    }

    /// 统一样式的小胶囊/行内条目；action 为 nil 时是纯状态展示，不可点。
    @ViewBuilder
    private func pill(_ icon: String, _ text: String, action: (() -> Void)? = nil) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.system(size: compact ? 11 : 12, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, compact ? 8 : 0)
        .padding(.vertical, compact ? 4 : 0)
        .background {
            if compact { Capsule().fill(Theme.accent.opacity(0.15)) }
        }
        if let action {
            Button(action: action) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        } else {
            label
        }
    }
}
