import SwiftUI
import WebKit

/// 用 WKWebView 跑真正的 Recharts（与 cc-switch 同库同配置），
/// 悬停/tooltip 就是 Recharts 本体 → 手感与网页端 1:1。
struct ChartWebView: NSViewRepresentable {
    let trend: [TrendBucket]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // 允许 file:// 页面加载/访问同目录脚本，并按同源处理（否则报 "Script error."）
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        // 透明背景，透出面板底色
        wv.setValue(false, forKey: "drawsBackground")
        wv.underPageBackgroundColor = .clear
        context.coordinator.webView = wv
        if let url = Bundle.main.url(forResource: "chart", withExtension: "html") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.send(json(trend))
    }

    private func json(_ trend: [TrendBucket]) -> String {
        let iso = ISO8601DateFormatter()
        let items: [[String: Any]] = trend.map { b in
            [
                "dateISO": iso.string(from: Date(timeIntervalSince1970: TimeInterval(b.startTs))),
                "inputTokens": b.input,
                "outputTokens": b.output,
                "cacheCreationTokens": b.creation,
                "cacheReadTokens": b.hit,
                "cost": b.cost,
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: items),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var ready = false
        private var pending: String?
        private var last: String = ""

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            if let p = pending { eval(p); pending = nil }
        }

        func send(_ json: String) {
            guard json != last else { return }   // 数据没变就不重绘
            last = json
            if ready { eval(json) } else { pending = json }
        }

        private func eval(_ json: String) {
            webView?.evaluateJavaScript("window.updateData(\(json))", completionHandler: nil)
        }
    }
}
