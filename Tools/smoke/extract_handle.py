#!/usr/bin/env python3
"""把 PanelWebView.Bridge.handle 原样抠出来，包成不依赖 WebKit 的类，冒烟时走的就是发版的那段 switch。"""
import sys

source, target = sys.argv[1:3]
text = open(source, encoding="utf-8").read()
start = text.index("        private func handle(_ cmd: String, _ raw: [String: Any]) throws -> Any {")
end = text.rindex("    }\n}")
wrapper = """import Foundation

final class SmokeBridge {
    private let store: UsageStore
    init(store: UsageStore) { self.store = store }
    struct Err: LocalizedError {
        let msg: String
        init(_ m: String) { msg = m }
        var errorDescription: String? { msg }
    }
    let onRefreshIntervalChanged: @MainActor (Int) -> Void = { _ in }
    func run(_ cmd: String, _ args: [String: Any]) throws -> Any { try handle(cmd, args) }

"""
open(target, "w", encoding="utf-8").write(wrapper + text[start:end].rstrip() + "\n}\n")
