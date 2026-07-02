#!/bin/bash
# 一键：生成工程 → 编译 → 安装到 /Applications 并打开。需要完整 Xcode（非仅 Command Line Tools）。
# One-shot: generate project → build → install to /Applications and launch. Requires full Xcode.
set -e
cd "$(dirname "$0")/.."

# 1. 确认用的是完整 Xcode / ensure full Xcode is selected
DEV=$(xcode-select -p 2>/dev/null || true)
if [[ "$DEV" != *"Xcode.app"* ]]; then
  echo "⚠️  当前 xcode-select 指向: ${DEV:-无}"
  echo "    需要完整 Xcode。装好后执行一次 / after installing Xcode run:"
  echo "    sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "    sudo xcodebuild -license accept"
  exit 1
fi

# 2. 重新生成工程（改了 project.yml / 增删文件后需要）/ regenerate the Xcode project
if command -v xcodegen >/dev/null; then
  xcodegen generate
else
  echo "⚠️  未找到 xcodegen（brew install xcodegen），沿用现有 CCUsageWidget.xcodeproj"
fi

# 3. Release 构建（ad-hoc 签名，个人自用）/ Release build with ad-hoc signing
xcodebuild -project CCUsageWidget.xcodeproj \
  -scheme CCUsageWidget \
  -configuration Release \
  -derivedDataPath build \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO ENABLE_DEBUG_DYLIB=NO \
  build

APP=$(find build/Build/Products/Release -maxdepth 1 -name "*.app" | head -1)
echo "✅ 构建完成 / built: $APP"

# 4. 安装并打开 / install & launch
if [ -n "$APP" ]; then
  rm -rf "/Applications/CC Usage.app"
  ditto "$APP" "/Applications/CC Usage.app"
  open "/Applications/CC Usage.app"
  echo "已安装到 /Applications/CC Usage.app 并启动。"
fi
