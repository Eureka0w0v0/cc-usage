#!/bin/bash
# 离屏渲染对拍：<源码根> 的设置面板和菜单栏合成图写进 <输出目录>，比较用 diff -r 或 cmp。
# 用法：bash Tools/render/render.sh <源码根> <输出目录>
# 编的是 App 层视图，但不起 App：入口换成 Tools/render/main.swift，碰不到 App 的 UserDefaults 域。
set -euo pipefail
ROOT=${1:?源码根} OUT=${2:?输出目录}
mkdir -p "$OUT"
BUILD="$OUT/build"
mkdir -p "$BUILD"

# MenuBarLabel.composite 是私有的，对拍要直接取图：编译前在副本里放开。
sed 's/private var composite: NSImage/var composite: NSImage/' "$ROOT/Sources/App/MenuBarLabel.swift" > "$BUILD/MenuBarLabel.swift"

SOURCES=()
while IFS= read -r f; do SOURCES+=("$f"); done < <(
  find "$ROOT/Sources/Shared" "$ROOT/Tools/render" -name '*.swift'
  find "$ROOT/Sources/App" -maxdepth 1 -name '*.swift' ! -name 'CCUsageApp.swift' ! -name 'MenuBarLabel.swift'
)
swiftc -swift-version 5 -target arm64-apple-macos14.0 "${SOURCES[@]}" "$BUILD/MenuBarLabel.swift" -lsqlite3 -o "$BUILD/ccrender"

# HOME 指到临时目录：NSHomeDirectory 跟着变，读不到真实的 ~/.claude、钥匙串搜索列表也只剩系统的。
# UserDefaults 不吃这个（cfprefsd 还是落到真实 ~/Library/Preferences），但域名是可执行文件名 ccrender，不是 App 的；
# 跑之前清空保证结果确定，跑完删掉不留文件。
HOME_DIR=$(mktemp -d /tmp/ccrender-home.XXXXXX)
cleanup() {
  rm -rf "$HOME_DIR"
  defaults delete ccrender 2>/dev/null || true
  rm -f "$HOME/Library/Preferences/ccrender.plist"
}
trap cleanup EXIT
defaults delete ccrender 2>/dev/null || true
HOME="$HOME_DIR" CFFIXED_USER_HOME="$HOME_DIR" TZ=Asia/Tokyo "$BUILD/ccrender" "$ROOT/Sources/App/BrandIcons" "$OUT"
ls "$OUT" | grep -v build | wc -l
