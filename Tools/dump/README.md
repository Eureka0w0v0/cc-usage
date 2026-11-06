# 冻结库对拍

搬代码、改查询之前先留一份「旧代码的全部输出」，改完用同一份冻结数据再跑一遍，逐字节比。
单元测试抓得到写错的规则，抓不到「搬的时候少了一行」：游标三态、跨 tick 计时、浮点累加顺序都靠这个兜底。

## 用法

```bash
# 1. 建冻结数据（只读 ~/.cc-switch、~/.claude/projects、~/.omp，写到指定目录；放临时目录，绝不进仓库）
python3 Tools/dump/freeze.py /tmp/ccusage/frozen

# 2. 留基线：在改动之前的代码上跑
bash Tools/dump/dump.sh . /tmp/ccusage/frozen /tmp/ccusage/base

# 3. 改完再跑一份，比较
bash Tools/dump/dump.sh . /tmp/ccusage/frozen /tmp/ccusage/new
bash Tools/dump/compare.sh /tmp/ccusage/base /tmp/ccusage/new
```

要对比旧版本，把它解出来当 `<源码根>`，工具用那个版本自己的 `Tools/dump`：

```bash
mkdir -p /tmp/ccusage/rev
git archive <提交> Sources/Shared Tools/dump | tar -x -C /tmp/ccusage/rev
bash Tools/dump/dump.sh /tmp/ccusage/rev /tmp/ccusage/frozen /tmp/ccusage/base
```

先用同一份代码跑两遍、比较结果为空，这才算基线：哪里有不确定的东西要先修工具。

## 跑了什么

- `matrix.txt`：全部公开查询（汇总、按 app、走势、快照、Provider / Model 统计、请求日志与详情、按来源、最早日期）
  × 14 个时间窗（含不足一天、整日边界、只有 rollup 的区间、反向区间）× 12 组筛选，逐字段打印。
- `overlay-*.txt`：两个叠加层的全部待入库行。`freeze.py` 从库快照派生几个游标变体（B 态续读、A 态缺列、
  C 态合法的 0、落在行中间、越界），每个读两遍（第二遍走短路分支）；`overlay-v3` 是 cc-switch 3.20.x 的计价口径。
- `replay-*.txt`：逐 tick 回放（`DumpReplay.swift`）。真实日志按随机 1–12 行一块追加，偶尔只写半行，每块调一次
  `pendingRows`，打每拍的摘要，最后和一次读完逐行比（`same=true`）。`handoff` 模式中途模拟 cc-switch 入库
  （写字节 / 行号游标、写明细和账本），OMP 还模拟文件被改短。

## 固定了什么

- now = 2026-11-05 12:00 JST，日历 Asia/Tokyo；`TZ` 也要是它，SQL 的 `localtime` 跟进程时区走。
- cc-switch 版本注入固定值，不读本机 `/Applications`。
- `SWIFT_DETERMINISTIC_HASHING=1`：叠加行存在字典里，遍历顺序决定浮点累加顺序，不关随机种子同一份代码两次的
  成本就差最后几位。
- 回放的 mtime 由工具写死递增，随机数来自 seed。

## 注意

- 输出里是真实用量数字和模型名，和冻结目录一样不进仓库；提交说明里也不要写。
- `matrix` 约 30 秒，全部约 1 分钟。
- OMP 的现场定价（自报成本为 0 才走）在抽到的日志里可能走不到，这条靠 `OmpOverlayTests`。
