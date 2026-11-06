#!/bin/bash
# 跑全部检查：坐标单元测试 + 编译 + 应用自检（不弹窗、不碰剪贴板、不截屏）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/tests"
mkdir -p "$OUT"

echo "▸ 坐标单元测试"
xcrun swiftc -swift-version 5 -target arm64-apple-macos15.0 -sdk "$(xcrun --show-sdk-path)" \
  -o "$OUT/GeometryTests" "$ROOT/MacKit/Tools/Screenshot/Geometry.swift" \
  "$ROOT/MacKit/Tools/Pin/PinGeometry.swift" "$ROOT/MacKit/Tools/Annotate/EditGeometry.swift" \
  "$ROOT/MacKit/Tools/Clipboard/ClipboardText.swift" "$ROOT/MacKit/Tools/Recorder/RecordGeometry.swift" \
  "$ROOT/MacKit/Tools/Recorder/KeyFormatter.swift" "$ROOT/MacKit/Tools/Recognize/RecognizeMath.swift" "$ROOT/MacKit/Tools/Recognize/ColorPalette.swift" \
  "$ROOT/MacKit/Tools/LongShot/ScrollStitcher.swift" "$ROOT/MacKit/Tools/Misc/SystemText.swift" \
  "$ROOT/MacKit/Tools/Beautify/BeautifyMath.swift" "$ROOT/MacKit/Tools/Recorder/AutoZoom.swift" \
  "$ROOT/Tests/main.swift"
"$OUT/GeometryTests"

echo "▸ 编译"
"$ROOT/scripts/build.sh"

echo "▸ 应用自检"
"$ROOT/build/MacKit.app/Contents/MacOS/MacKit" --selftest
