#!/bin/bash
# 对拍 cc-switch 上游的「用量 app 全集」与「会话来源占位名」，发现本仓库漏跟进的项。
# Cross-check this repo against cc-switch's app-type and session-provider truth sources.
#
# 为什么要有：上游每加一种 harness（Pi、MiniMax Code…）都会同时动两处——
#   ① src/types/usage.ts 的 KNOWN_APP_TYPES（决定哪些 app 有用量）
#   ② services/usage_stats.rs 的 provider_name_coalesce（占位 provider_id → 可读名）
# 本仓库对应 MBApp 与 UsageSQL.providerNameSQL。两边都没有任何机制互相提醒，
# 结果 pi 漏了一整轮、mcode 漏到下一轮才发现（Provider Stats 直接露出 `_mcode_session`）。
# 每次上游同步跑一次本脚本即可。全程只读，不改任何文件。
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CC_SWITCH_DIR="${CC_SWITCH_DIR:-$ROOT/../cc-switch}"

if [ ! -d "$CC_SWITCH_DIR/src" ]; then
  echo "❌ 未找到 cc-switch 源码（${CC_SWITCH_DIR}）。先 clone / clone it first:"
  echo "   git clone https://github.com/farion1231/cc-switch \"$CC_SWITCH_DIR\""
  exit 1
fi
if [ -d "$CC_SWITCH_DIR/.git" ]; then
  echo "📌 cc-switch @ $(git -C "$CC_SWITCH_DIR" rev-parse --short HEAD) \
($(git -C "$CC_SWITCH_DIR" describe --tags --always 2>/dev/null || echo untagged))"
fi

python3 - "$CC_SWITCH_DIR" <<'PY'
import re, sys, pathlib

cc = pathlib.Path(sys.argv[1])
root = pathlib.Path.cwd()
fail = []

# ── ① 用量 app 全集 ───────────────────────────────────────────────
# 上游真理源：src/types/usage.ts 的 KNOWN_APP_TYPES
ts = (cc / "src/types/usage.ts").read_text(encoding="utf-8")
m = re.search(r"KNOWN_APP_TYPES[^=]*=\s*\[(.*?)\]", ts, re.S)
if not m:
    sys.exit("❌ 解析不到上游 KNOWN_APP_TYPES —— 上游结构可能变了")
upstream_apps = set(re.findall(r'"([^"]+)"', m.group(1)))

# 本仓库：MBApp 的 case 列表
mb = (root / "Sources/App/MenuBarKeys.swift").read_text(encoding="utf-8")
m = re.search(r"enum MBApp: String, CaseIterable \{.*?\n\s*case ([^\n]+)\n", mb, re.S)
if not m:
    sys.exit("❌ 解析不到 MBApp 的 case 行 —— 本仓库结构可能变了")
local_apps = {c.strip() for c in m.group(1).split(",")}

# 本仓库独有且合法的项（不来自 cc-switch 的 app_type，是本 app 自己的数据源）
LOCAL_ONLY = {"antigravity"}

missing = upstream_apps - local_apps
if missing:
    fail.append(f"MBApp 缺少上游用量 app：{sorted(missing)}\n"
                f"   → 在 Sources/App/MenuBarKeys.swift 的 MBApp 末尾追加，并在\n"
                f"     MenuBarSettingsView.swift 加对应分组 + MBKey 的 group 键")
extra = local_apps - upstream_apps - LOCAL_ONLY
if extra:
    fail.append(f"MBApp 有上游已不存在的 app：{sorted(extra)}\n"
                f"   → 确认上游是否移除了它；若是本仓库独有的来源请加进脚本的 LOCAL_ONLY")
print(f"① 用量 app：上游 {len(upstream_apps)} 项，本仓库 {len(local_apps)} 项"
      f"（含独有 {sorted(LOCAL_ONLY & local_apps)}）")

# ── ② 会话来源占位 provider_id → 可读名 ──────────────────────────
rs = (cc / "src-tauri/src/services/usage_stats.rs").read_text(encoding="utf-8")
upstream_names = dict(re.findall(r"WHEN '(_[a-z_]*session)' THEN '([^']+)'", rs))
if not upstream_names:
    sys.exit("❌ 解析不到上游 provider_name_coalesce 的占位名映射")

sql = (root / "Sources/Shared/UsageSQL.swift").read_text(encoding="utf-8")
local_names = dict(re.findall(r"WHEN '(_[a-z_]*session)' THEN '([^']+)'", sql))

miss = {k: v for k, v in upstream_names.items() if k not in local_names}
if miss:
    fail.append("UsageSQL.providerNameSQL 缺少占位名映射："
                + ", ".join(f"{k} → '{v}'" for k, v in sorted(miss.items()))
                + "\n   → 不补的话 Provider Stats 会直接显示裸的 provider_id")
diff = {k: (local_names[k], v) for k, v in upstream_names.items()
        if k in local_names and local_names[k] != v}
if diff:
    fail.append("占位名与上游不一致（会导致 providerName 筛选对不上）："
                + ", ".join(f"{k}: 本地 '{a}' ≠ 上游 '{b}'" for k, (a, b) in sorted(diff.items())))
print(f"② 会话来源占位名：上游 {len(upstream_names)} 条，本仓库 {len(local_names)} 条")

# ── ③ input_tokens 含 cache 的 app 白名单 ────────────────────────
m = re.search(r"CACHE_INCLUSIVE_APP_TYPES[^=]*=\s*&?\[(.*?)\]",
              (cc / "src-tauri/src/services/sql_helpers.rs").read_text(encoding="utf-8"), re.S)
if m:
    up_ci = set(re.findall(r'"([^"]+)"', m.group(1)))
    m2 = re.search(r'cacheInclusiveApps\s*=\s*"\((.*?)\)"', sql)
    loc_ci = set(re.findall(r"'([^']+)'", m2.group(1))) if m2 else set()
    if up_ci != loc_ci:
        fail.append(f"cacheInclusiveApps 与上游不一致：本地 {sorted(loc_ci)} ≠ 上游 {sorted(up_ci)}\n"
                    f"   → 这直接改变 fresh input 口径，数字会错")
    print(f"③ cache-inclusive 白名单：{sorted(up_ci)}")

if fail:
    print()
    for f in fail:
        print(f"❌ {f}")
    sys.exit(1)
print("\n✅ 三项均与上游一致")
PY
