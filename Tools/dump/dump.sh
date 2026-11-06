#!/bin/bash
# 冻结库对拍：用 <源码根> 的代码把冻结数据集全查一遍，结果写进 <输出目录>。
# 用法：bash Tools/dump/dump.sh <源码根> <冻结目录> <输出目录> [matrix|overlay|replay|all]
#   <源码根> 下要有 Sources/Shared 和 Tools/dump（仓库根，或 git archive 解出来的旧版本）
#   冻结目录由 Tools/dump/freeze.py 建；输出目录每次清空重建
# 比较两份结果：bash Tools/dump/compare.sh <基线输出目录> <新输出目录>
set -euo pipefail

ROOT=${1:?源码根} FROZEN=${2:?冻结目录} OUT=${3:?输出目录} WHAT=${4:-all}
mkdir -p "$OUT"
BIN="$OUT/ccdump.bin"

# 文件遍历顺序不影响编译结果；只是路径里可能有空格。
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources/Shared" "$ROOT/Tools/dump" -name '*.swift' | sort)
swiftc -O -wmo -swift-version 5 -target arm64-apple-macos14.0 "${SOURCES[@]}" -lsqlite3 -o "$BIN"

# 字典遍历顺序决定浮点累加顺序和同一时刻的行序：不关掉随机种子，同一份代码两次的结果都对不上。
export SWIFT_DETERMINISTIC_HASHING=1 TZ=Asia/Tokyo LC_ALL=C
CLAUDE="$FROZEN/claude/projects"
OMP="$FROZEN/omp/sessions"

if [ "$WHAT" = all ] || [ "$WHAT" = matrix ]; then
  "$BIN" matrix "$FROZEN/db/live.db" "$CLAUDE" "$OMP" > "$OUT/matrix.txt"
fi
if [ "$WHAT" = all ] || [ "$WHAT" = overlay ]; then
  for variant in live byteNull noByteCol byteZero byteMid; do
    "$BIN" overlay "$FROZEN/db/$variant.db" "$CLAUDE" "$OMP" > "$OUT/overlay-$variant.txt"
  done
  # 3.20.x 的缓存写入不分 1 小时档
  "$BIN" overlay "$FROZEN/db/live.db" "$CLAUDE" "$OMP" 3.20.3 > "$OUT/overlay-v3.txt"
fi
if [ "$WHAT" = all ] || [ "$WHAT" = replay ]; then
  for seed in 1 2; do
    for mode in ticks handoff; do
      "$BIN" replay-claude "$FROZEN/db/live.db" "$FROZEN/replay/claude" "$OUT/work" "$seed" "$mode" \
        > "$OUT/replay-claude-$mode-$seed.txt"
      "$BIN" replay-omp "$FROZEN/db/live.db" "$FROZEN/replay/omp" "$OUT/work" "$seed" "$mode" \
        > "$OUT/replay-omp-$mode-$seed.txt"
    done
  done
  rm -rf "$OUT/work"
fi
wc -l "$OUT"/*.txt | tail -1
