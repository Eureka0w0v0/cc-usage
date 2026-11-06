import Foundation

// 冒烟用的桥接进程：stdin 每行 {"cmd","args"}，stdout 每行 {"result"} 或 {"error"}。数据是冻结库，
// 叠加层目录都指到冻结目录，不读用户环境。额度不走网络和钥匙串，给一份假的。
setlinebuf(stdout)
let frozen = CommandLine.arguments[1]
let session = SessionOverlay(projectsDir: frozen + "/claude/projects", minRefreshInterval: 0, ccSwitchVersion: { "4.0.12" })
let omp = OmpOverlay(sessionsDir: frozen + "/omp/sessions", minRefreshInterval: 0)
let bridge = SmokeBridge(store: UsageStore(path: frozen + "/db/live.db", sources: [session, omp]))

func encode(_ value: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
        return #"{"error":"payload is not JSON serializable"}"#
    }
    return String(decoding: data, as: UTF8.self)
}

while let line = readLine() {
    guard let request = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
          let cmd = request["cmd"] as? String else {
        print(#"{"error":"bad invoke payload"}"#)
        continue
    }
    if cmd == "get_quota" {
        let tiers = [QuotaTier(name: "five_hour", utilization: 42, resetsAt: Date(timeIntervalSince1970: 1_900_000_000),
                               planLabel: "Smoke"),
                     QuotaTier(name: "seven_day", utilization: 12, resetsAt: nil, planLabel: "Smoke")]
        print(encode(["result": BridgePayload.quota(tiers)]))
        continue
    }
    do {
        print(encode(["result": try bridge.run(cmd, request["args"] as? [String: Any] ?? [:])]))
    } catch {
        print(encode(["error": "\(error)"]))
    }
}
