#!/bin/bash
# 做发布用的安装包：编译发布版 → 换成临时签名（签名里不带证书名字、团队编号）→ 做 dmg → 算 SHA-256
# 产物在 build/release/，不会上传到任何地方。你自己用的版本还是走 scripts/install.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/MacKit/Resources/Info.plist")
DMG="$OUT/MacKit-$VERSION.dmg"

echo "▸ 编译 MacKit $VERSION"
"$ROOT/scripts/build.sh" >/dev/null
rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ditto "$ROOT/build/MacKit.app" "$OUT/dmg/MacKit.app"
APP="$OUT/dmg/MacKit.app"

echo "▸ 换成临时签名"
# 先把原来的签名整个去掉再签：直接覆盖的话，旧签名（里面有证书上的名字、邮箱、团队编号）会残留在空白里
rm -f "$APP/Contents/embedded.provisionprofile"
codesign --remove-signature "$APP"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "▸ 检查包里没有个人信息"
if codesign -dvv "$APP" 2>&1 | grep -q "^Authority="; then echo "✗ 签名里还有证书信息" >&2; exit 1; fi
if codesign -dvv "$APP" 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; then echo "✗ 签名里还有团队编号" >&2; exit 1; fi
TEAM=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | tr -d '[:space:]' || true)
if [ -n "$TEAM" ] && grep -rqa -- "$TEAM" "$APP"; then echo "✗ 包里有团队编号" >&2; exit 1; fi
if LC_ALL=C grep -rqa -e "Apple Development" -e "Developer ID" "$APP"; then echo "✗ 包里有证书名字" >&2; exit 1; fi
if LC_ALL=C grep -rqaE "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|cn|net|org|me|io)" "$APP"; then echo "✗ 包里有邮箱地址" >&2; exit 1; fi
ARCHS=$(lipo -archs "$APP/Contents/MacOS/MacKit")

echo "▸ 做 dmg"
ln -s /Applications "$OUT/dmg/应用程序"
hdiutil create -volname "MacKit $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SHA  MacKit-$VERSION.dmg" > "$DMG.sha256"

echo "✓ 安装包：$DMG（$(du -h "$DMG" | cut -f1 | tr -d ' ')，$ARCHS）"
echo "  SHA-256：$SHA"
echo "  （release.sh 每次会清空 build/release，发布说明放在 build/ 下面）"
