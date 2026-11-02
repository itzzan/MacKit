#!/bin/bash
# 编译 MacKit，产物统一放在 build/MacKit.app
#   装了 Xcode（xcode-select 指向 Xcode.app）→ 用 Xcode 编译，签名看 Config/Local.xcconfig
#   没装 Xcode → 用命令行工具的 swiftc 编译，临时签名
# 可选环境变量：
#   MACKIT_BUILDER=xcode|swiftc         强制用某一种
#   MACKIT_SIGN_IDENTITY="证书名"        swiftc 方式下用指定证书签名
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/MacKit.app"
BUILDER="${MACKIT_BUILDER:-auto}"
mkdir -p "$ROOT/build"

if [ "$BUILDER" = "auto" ]; then
  if xcodebuild -version >/dev/null 2>&1; then BUILDER=xcode; else BUILDER=swiftc; fi
fi

build_with_xcode() {
  echo "▸ 用 $(xcodebuild -version | head -1) 编译…"
  (cd "$ROOT" && xcodegen generate --spec project.yml --quiet)
  xcodebuild -project "$ROOT/MacKit.xcodeproj" -scheme MacKit -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$ROOT/build/DerivedData" -quiet build
  local products="$ROOT/build/DerivedData/Build/Products/Release"
  rm -rf "$APP" "$ROOT/build/MacKit.dSYM"
  cp -R "$products/MacKit.app" "$APP"
  if [ -d "$products/MacKit.app.dSYM" ]; then cp -R "$products/MacKit.app.dSYM" "$ROOT/build/MacKit.dSYM"; fi
}

build_with_swiftc() {
  local identity="${MACKIT_SIGN_IDENTITY:--}"
  local sources=()
  while IFS= read -r f; do sources+=("$f"); done < <(find "$ROOT/MacKit" -name '*.swift' | sort)

  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  echo "▸ 用命令行工具编译 ${#sources[@]} 个 Swift 文件…"
  xcrun swiftc \
    -parse-as-library \
    -swift-version 5 \
    -target arm64-apple-macos15.0 \
    -sdk "$(xcrun --show-sdk-path)" \
    -module-name MacKit \
    -O -g \
    -o "$APP/Contents/MacOS/MacKit" \
    "${sources[@]}"
  cp "$ROOT/MacKit/Resources/Info.plist" "$APP/Contents/Info.plist"
  # 调试符号放到包外面（崩溃时用来看是哪一行）
  rm -rf "$ROOT/build/MacKit.dSYM"
  if [ -d "$APP/Contents/MacOS/MacKit.dSYM" ]; then mv "$APP/Contents/MacOS/MacKit.dSYM" "$ROOT/build/"; fi

  if [ "$identity" = "-" ]; then echo "▸ 签名（临时签名）…"; else echo "▸ 签名（$identity）…"; fi
  codesign --force --sign "$identity" --timestamp=none "$APP"
}

case "$BUILDER" in
  xcode)  build_with_xcode ;;
  swiftc) build_with_swiftc ;;
  *) echo "MACKIT_BUILDER 只能是 xcode 或 swiftc" >&2; exit 2 ;;
esac

# 只显示证书类型（例如 Apple Development），不显示证书上的名字
SIGNER=$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 | cut -d: -f1)
echo "✓ 编译完成：$APP（签名：${SIGNER:-临时签名}）"
