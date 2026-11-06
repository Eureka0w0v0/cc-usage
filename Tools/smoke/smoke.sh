#!/bin/bash
# 无头 Chrome 冒烟：真前端（web-panel/index.html）+ 真桥接（PanelWebView.handle + BridgePayload）+ 冻结库。
# 用法：bash Tools/smoke/smoke.sh <冻结目录> <输出目录>
# 冻结目录由 Tools/dump/freeze.py 建。不碰 /Applications 的 App、用户的 UserDefaults 和 Chrome 配置。
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FROZEN=${1:?冻结目录} OUT=${2:?输出目录}
mkdir -p "$OUT"

python3 "$ROOT/Tools/smoke/extract_handle.py" "$ROOT/Sources/App/PanelWebView.swift" "$OUT/SmokeBridge.swift"
SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(find "$ROOT/Sources/Shared" -name '*.swift')
swiftc -O -wmo -swift-version 5 -target arm64-apple-macos14.0 "${SOURCES[@]}" \
  "$ROOT/Sources/App/MenuBarKeys.swift" "$OUT/SmokeBridge.swift" "$ROOT/Tools/smoke/serve/main.swift" \
  -lsqlite3 -o "$OUT/bridgeserve"

TZ=Asia/Tokyo node "$ROOT/Tools/smoke/smoke.mjs" "$OUT/bridgeserve" "$FROZEN" \
  "$ROOT/Sources/App/web-panel/index.html" "$OUT"
