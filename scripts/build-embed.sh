#!/bin/bash
# 重建主窗口面板前端（cc-switch 真前端 + embed 桥接 → 单文件 index.html）。
# Rebuild the main-window panel (real cc-switch frontend + embed bridge → single-file index.html).
#
# 用法 / Usage:
#   CC_SWITCH_DIR=/path/to/cc-switch scripts/build-embed.sh
#   （未设置 CC_SWITCH_DIR 时默认使用 ../cc-switch / defaults to ../cc-switch）
#
# 说明 / Notes:
#   - 需要 pnpm ≥ 9。pnpm 11 首次安装若提示 "Ignored build scripts"，按提示把
#     esbuild 允许构建（pnpm approve-builds，或在 pnpm-workspace.yaml 设 allowBuilds: esbuild: true）。
#   - Requires pnpm ≥ 9. On pnpm 11, approve esbuild's build script if prompted.
#   - 步骤 2 的 pnpm add 会改动 cc-switch 的 package.json / lockfile（加打包插件），
#     拷入的桥接文件本身均为新增、不覆盖上游文件。
#     Step 2's pnpm add does modify cc-switch's package.json/lockfile; the copied
#     bridge files themselves are additive only.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CC_SWITCH_DIR="${CC_SWITCH_DIR:-$ROOT/../cc-switch}"
# 面板桥接层验证过的上游提交（升级上游后先回归再更新此值）。
# The upstream commit this embed bridge was last verified against.
CC_SWITCH_REF="${CC_SWITCH_REF:-c6197ae32450cd70e2bf03b35e3f5f53ac12044c}"

if [ ! -d "$CC_SWITCH_DIR/src" ]; then
  echo "❌ 未找到 cc-switch 源码（$CC_SWITCH_DIR）。先执行 / clone it first:"
  echo "   git clone https://github.com/farion1231/cc-switch \"$CC_SWITCH_DIR\""
  exit 1
fi
command -v pnpm >/dev/null || { echo "❌ 需要 pnpm / pnpm is required"; exit 1; }

# 0) 上游版本校验：HEAD 偏离已验证提交时给出警告（CC_SWITCH_CHECKOUT=1 则自动切换；
#    默认不动用户工作区）。上游演进可能改掉 usage 组件的导入路径/口径，盲构建会悄悄跑偏。
if git -C "$CC_SWITCH_DIR" rev-parse --verify "$CC_SWITCH_REF^{commit}" >/dev/null 2>&1; then
  HEAD_SHA=$(git -C "$CC_SWITCH_DIR" rev-parse HEAD)
  REF_SHA=$(git -C "$CC_SWITCH_DIR" rev-parse "$CC_SWITCH_REF^{commit}")
  if [ "$HEAD_SHA" != "$REF_SHA" ]; then
    if [ "${CC_SWITCH_CHECKOUT:-0}" = "1" ]; then
      echo "↩️  切换 cc-switch 到已验证提交 / checking out pinned ref: ${REF_SHA:0:12}"
      git -C "$CC_SWITCH_DIR" checkout --quiet "$REF_SHA"
    else
      echo "⚠️  cc-switch HEAD (${HEAD_SHA:0:12}) ≠ 已验证提交 (${REF_SHA:0:12})。"
      echo "    产物可能与本仓库桥接层不兼容。可 CC_SWITCH_CHECKOUT=1 自动切换，"
      echo "    或验证新上游后更新脚本里的 CC_SWITCH_REF。"
    fi
  fi
else
  echo "⚠️  cc-switch 本地没有提交 $CC_SWITCH_REF（浅克隆/旧仓？），跳过版本校验。"
fi

# 1) 把 embed 桥接文件铺进 cc-switch 源码树（均为新增文件，不覆盖上游文件）
#    Copy embed bridge files into the cc-switch tree (all additive, no upstream file touched)
cp embed/index-embed.html embed/vite.embed.config.ts "$CC_SWITCH_DIR/"
cp embed/usage-embed.tsx embed/embed-invoke-shim.ts embed/embed-tauri-stub.ts "$CC_SWITCH_DIR/src/"

# 2) 安装依赖 + 补打包插件 / install deps + the single-file plugin
cd "$CC_SWITCH_DIR"
pnpm add -D vite-plugin-singlefile@^2.3.3 >/dev/null
pnpm install >/dev/null

# 3) 构建，产物直写回本仓库 / build straight into this repo
CC_USAGE_WEB_PANEL_OUT="$ROOT/Sources/App/web-panel" \
  pnpm exec vite build --config vite.embed.config.ts

echo "✅ 已产出 / built: $ROOT/Sources/App/web-panel/index.html"
