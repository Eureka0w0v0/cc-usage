#!/bin/bash
# 跑单元测试（生成工程 → xcodebuild test）。Run the unit tests.
# 测试全部对着临时 sqlite / 临时目录，不读写真实 ~/.cc-switch 与 ~/.claude/projects。
set -e
cd "$(dirname "$0")/.."

if command -v xcodegen >/dev/null; then
  xcodegen generate
else
  echo "⚠️  未找到 xcodegen（brew install xcodegen），沿用现有 CCUsageWidget.xcodeproj"
fi

xcodebuild test -project CCUsageWidget.xcodeproj \
  -scheme CCUsageWidgetTests \
  -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO \
  -quiet
echo "✅ 测试通过 / all tests passed"
