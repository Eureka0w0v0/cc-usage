#!/bin/bash
# 从 cc-switch 源码同步内置模型定价表 → Sources/Shared/ModelPricing.swift。
# Sync the built-in model pricing table from cc-switch's seed_model_pricing.
#
# 为什么要有这份内置表：cc-switch 的定价来自它自己的内置 seed，新模型发布到上游
# seed 跟进之间有空窗期。空窗期内 cc-switch 入库查不到价 → 成本写 0 → 面板显示
# 「未定价」，且该值入库时就写死了。有了内置表，CC Usage 能自己补算，不必干等上游。
#
# 上游加了新模型或调价后，跑一次本脚本即可。全程只读 cc-switch 源码，不碰它的库。
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CC_SWITCH_DIR="${CC_SWITCH_DIR:-$ROOT/../cc-switch}"
SCHEMA="$CC_SWITCH_DIR/src-tauri/src/database/schema.rs"
OUT="Sources/Shared/ModelPricing.swift"

if [ ! -f "$SCHEMA" ]; then
  echo "❌ 未找到 cc-switch 源码（$SCHEMA）。先 clone / clone it first:"
  echo "    git clone https://github.com/farion1231/cc-switch.git \"$CC_SWITCH_DIR\""
  echo "    或用 CC_SWITCH_DIR=/path/to/cc-switch $0"
  exit 1
fi

if [ -d "$CC_SWITCH_DIR/.git" ]; then
  echo "📌 cc-switch @ $(git -C "$CC_SWITCH_DIR" rev-parse --short HEAD) \
($(git -C "$CC_SWITCH_DIR" describe --tags --always 2>/dev/null || echo untagged))"
fi

python3 - "$SCHEMA" "$OUT" <<'PY'
import re, sys

schema_path, out_path = sys.argv[1], sys.argv[2]
src = open(schema_path, encoding='utf-8').read()

start = src.index('let pricing_data = [', src.index('fn seed_model_pricing')) + len('let pricing_data = [')
depth, j = 1, start
while depth:
    if src[j] == '[': depth += 1
    elif src[j] == ']': depth -= 1
    j += 1
body = re.sub(r'//[^\n]*', '', src[start:j - 1])

rows = re.findall(
    r'\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*,'
    r'\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,?\s*\)', body)
if not rows:
    sys.exit("❌ 未能从 seed_model_pricing 解析出定价条目——上游格式可能变了")

def num(s):
    d = float(s)
    return '%d' % int(d) if d == int(d) else '%g' % d

table = "\n".join(
    f'        "{mid}": R({num(i)}, {num(o)}, {num(cr)}, {num(cw)}),  // {name}'
    for mid, name, i, o, cr, cw in rows)

out = open(out_path, encoding='utf-8').read()
new, n = re.subn(
    r'(public static let table: \[String: Row\] = \[\n).*?(\n    \])',
    lambda m: m.group(1) + table + m.group(2), out, flags=re.S)
if n != 1:
    sys.exit("❌ 未能在 ModelPricing.swift 中定位 table 字面量")

new = re.sub(r'对齐 cc-switch seed_model_pricing 的 \d+ 条内置定价。',
             f'对齐 cc-switch seed_model_pricing 的 {len(rows)} 条内置定价。', new)
open(out_path, 'w', encoding='utf-8').write(new)
print(f"✅ 已同步 {len(rows)} 条定价 → {out_path}")
PY

echo "👉 记得跑 scripts/test.sh 回归后再提交 / run the tests before committing"
