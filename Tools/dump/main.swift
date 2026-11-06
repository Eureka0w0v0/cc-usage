import Foundation
import SQLite3

// 冻结库对拍工具的入口。用法见 Tools/dump/README.md。
//
//   ccdump matrix <db> <claude projects 目录> <omp sessions 目录> [cc-switch 版本]
//       全部公开查询 × 时间窗 × 筛选，逐字段打印
//   ccdump overlay <db> <claude projects 目录> <omp sessions 目录> [cc-switch 版本]
//       只打两个叠加层的全部待入库行（游标变体用，比 matrix 快）
//   ccdump replay-claude <db> <回放源目录> <工作目录> <seed> <ticks|handoff>
//   ccdump replay-omp    <db> <回放源目录> <工作目录> <seed> <ticks|handoff>
//       逐 tick 回放（见 DumpReplay.swift）
//
// 输出只取决于入参和冻结数据：now、时区、cc-switch 版本都固定，dump.sh 还会打开确定性哈希。

setlinebuf(stdout)
guard TimeZone.current.identifier == "Asia/Tokyo" else {
    FileHandle.standardError.write(Data("ccdump 必须在 TZ=Asia/Tokyo 下跑（SQL 的 localtime 跟进程时区走）\n".utf8))
    exit(2)
}

let arguments = CommandLine.arguments
func argument(_ i: Int) -> String {
    guard i < arguments.count else {
        FileHandle.standardError.write(Data("参数不够，用法见 Tools/dump/README.md\n".utf8))
        exit(2)
    }
    return arguments[i]
}

switch argument(1) {
case "matrix":
    let version = arguments.count > 5 ? arguments[5] : DumpContext.defaultVersion
    DumpMatrix(DumpContext(db: argument(2), projects: argument(3), omp: argument(4), version: version)).run()
case "overlay":
    let version = arguments.count > 5 ? arguments[5] : DumpContext.defaultVersion
    DumpContext(db: argument(2), projects: argument(3), omp: argument(4), version: version).dumpOverlays()
case "replay-claude":
    DumpReplay(kind: .claude, db: argument(2), sources: argument(3), work: argument(4),
               seed: UInt64(argument(5)) ?? 1, handoff: argument(6) == "handoff").run()
case "replay-omp":
    DumpReplay(kind: .omp, db: argument(2), sources: argument(3), work: argument(4),
               seed: UInt64(argument(5)) ?? 1, handoff: argument(6) == "handoff").run()
default:
    FileHandle.standardError.write(Data("未知子命令 \(argument(1))\n".utf8))
    exit(2)
}
