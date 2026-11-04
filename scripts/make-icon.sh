#!/bin/bash
# 重新画 App 图标：MacKit 自己用代码画各种尺寸 → iconutil 打包成 MacKit/Resources/AppIcon.icns
# 只在改了图标的样子时跑（画法在 MacKit/App/IconMaker.swift）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SET="$ROOT/build/AppIcon.iconset"
"$ROOT/scripts/build.sh" >/dev/null
rm -rf "$SET"
"$ROOT/build/MacKit.app/Contents/MacOS/MacKit" --make-iconset "$SET"
iconutil -c icns "$SET" -o "$ROOT/MacKit/Resources/AppIcon.icns"
echo "✓ 图标：$ROOT/MacKit/Resources/AppIcon.icns"
