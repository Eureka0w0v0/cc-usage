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
CC_SWITCH_REF="${CC_SWITCH_REF:-fdbe3a85b269ed40695ded5981b6ba8288d30ac3}"

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
    # 本地在钉子之上只叠了桥接层提交（下面铺进去的 5 个文件 + 依赖清单）不算偏离：
    # 钉子须是 HEAD 的祖先，且 REF..HEAD 之间除桥接文件外零改动。
    # Local commits on top of the pin that only touch the bridge files are not drift.
    BRIDGE_ONLY=0
    if git -C "$CC_SWITCH_DIR" merge-base --is-ancestor "$REF_SHA" HEAD 2>/dev/null; then
      DRIFT=$(git -C "$CC_SWITCH_DIR" diff --name-only "$REF_SHA" HEAD -- . \
        ':!src/usage-embed.tsx' ':!src/embed-invoke-shim.ts' ':!src/embed-tauri-stub.ts' \
        ':!index-embed.html' ':!vite.embed.config.ts' ':!package.json' ':!pnpm-lock.yaml')
      [ -z "$DRIFT" ] && BRIDGE_ONLY=1
    fi
    if [ "$BRIDGE_ONLY" = "1" ]; then
      echo "ℹ️  cc-switch HEAD (${HEAD_SHA:0:12}) = 已验证提交 (${REF_SHA:0:12}) + 仅桥接层提交，视同已验证。"
    elif [ "${CC_SWITCH_CHECKOUT:-0}" = "1" ]; then
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
#    已在 package.json 里就不再 add；install 走非交互模式且不吞输出——
#    早前 >/dev/null 把 ERR_PNPM_UNEXPECTED_STORE 之类的错误一并吞掉，只剩静默 exit 1。
cd "$CC_SWITCH_DIR"
grep -q '"vite-plugin-singlefile"' package.json || pnpm add -D vite-plugin-singlefile@^2.3.3
CI=1 pnpm install --reporter=append-only

# 3) 构建，产物直写回本仓库 / build straight into this repo
CC_USAGE_WEB_PANEL_OUT="$ROOT/Sources/App/web-panel" \
  pnpm exec vite build --config vite.embed.config.ts

echo "✅ 已产出 / built: $ROOT/Sources/App/web-panel/index.html"
