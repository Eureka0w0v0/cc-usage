#!/bin/bash
# 比较两份 dump.sh 的输出：逐文件 diff，全部相同才算过。不同就打出前几行差异并返回 1。
# 用法：bash Tools/dump/compare.sh <基线输出目录> <新输出目录>
set -u
BASE=${1:?基线输出目录} NEW=${2:?新输出目录}
status=0
checked=0
for f in "$BASE"/*.txt; do
  name=$(basename "$f")
  checked=$((checked + 1))
  if [ ! -f "$NEW/$name" ]; then
    echo "缺文件: $name"; status=1; continue
  fi
  if ! cmp -s "$f" "$NEW/$name"; then
    echo "不同: $name"
    diff "$f" "$NEW/$name" | head -20
    status=1
  fi
done
[ "$checked" -gt 0 ] || { echo "基线目录里没有 .txt"; status=1; }
[ "$status" = 0 ] && echo "一致：$checked 个文件逐字节相同"
exit "$status"
