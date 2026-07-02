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
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

CC_SWITCH_DIR="${CC_SWITCH_DIR:-$ROOT/../cc-switch}"
if [ ! -d "$CC_SWITCH_DIR/src" ]; then
  echo "❌ 未找到 cc-switch 源码（$CC_SWITCH_DIR）。先执行 / clone it first:"
  echo "   git clone https://github.com/farion1231/cc-switch \"$CC_SWITCH_DIR\""
  exit 1
fi
command -v pnpm >/dev/null || { echo "❌ 需要 pnpm / pnpm is required"; exit 1; }

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
