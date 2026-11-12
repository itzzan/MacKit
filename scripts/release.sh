#!/bin/bash
# 做发布用的安装包：编译发布版 → 用"MacKit"证书签名（签名里只有"MacKit"这个名字，没有你的名字、邮箱、团队编号）→ 做 dmg → 算 SHA-256
# 产物在 build/release/，不会上传到任何地方。你自己用的版本还是走 scripts/install.sh
#
# 台阶 26 起发布版用钥匙串里的"MacKit"自签证书签：系统记权限认的是"标识 + 这张证书"，以后再发新版本，别人不用重给权限。
# 证书怎么做见 docs/开发记录/台阶26-发布3.0.md。找不到证书就停下，不偷偷退回临时签名。
#   MACKIT_RELEASE_IDENTITY="别的证书名"   换一张证书；写成 - 就是临时签名（每个新版本都要重给权限，一般别用）
#   --test-update                          另打一个"下一个版本号"的测试包（build/release-test/，不发布），
#                                          并用系统的签名检查确认它和正式包是"同一个软件"
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
TEST_OUT="$ROOT/build/release-test"
IDENTITY="${MACKIT_RELEASE_IDENTITY:-MacKit}"
TEST_UPDATE=false
[ "${1:-}" = "--test-update" ] && TEST_UPDATE=true
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/MacKit/Resources/Info.plist")
DMG="$OUT/MacKit-$VERSION.dmg"

fail() { echo "✗ $*" >&2; exit 1; }

if [ "$IDENTITY" != "-" ]; then
  # 只看钥匙串里有没有这个名字的签名证书（不碰密钥）；自签的证书系统说"不受信任"不要紧
  security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\"" \
    || fail "钥匙串里找不到叫「$IDENTITY」的签名证书：按 docs/开发记录/台阶26-发布3.0.md 里\"你要做的事\"做一张"
fi

echo "▸ 编译 MacKit $VERSION"
"$ROOT/scripts/build.sh" >/dev/null
rm -rf "$OUT"
mkdir -p "$OUT/dmg"
ditto "$ROOT/build/MacKit.app" "$OUT/dmg/MacKit.app"
APP="$OUT/dmg/MacKit.app"

# 先把原来的签名整个去掉再签：直接覆盖的话，旧签名（里面有开发证书上的名字、邮箱、团队编号）会残留在空白里
sign() {
  rm -f "$1/Contents/embedded.provisionprofile"
  codesign --remove-signature "$1"
  codesign --force --sign "$IDENTITY" --timestamp=none "$1"
  codesign --verify --strict "$1"
}

# 签名里只许有"MacKit"这张证书，证书上只有名字（国家可以有），没有邮箱、单位、城市
check_signature() {
  local app="$1"
  local authorities
  authorities=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p')
  if [ "$IDENTITY" = "-" ]; then
    [ -z "$authorities" ] || fail "临时签名里不该有证书：$authorities"
  else
    [ "$authorities" = "$IDENTITY" ] || fail "签名里的证书应该只有「$IDENTITY」，现在是：$(echo "$authorities" | tr '\n' ' ')"
    local tmp subject
    tmp=$(mktemp -d)
    (cd "$tmp" && codesign -d --extract-certificates "$app" >/dev/null 2>&1)
    [ -f "$tmp/codesign0" ] || fail "取不出签名里的证书"
    for c in "$tmp"/codesign*; do
      subject=$(openssl x509 -inform DER -in "$c" -noout -subject -issuer 2>/dev/null)
      echo "$subject" | grep -Eiq "(^|/|, *|= *)(emailAddress|O|OU|L|ST|street|UID) *=" \
        && fail "证书上除了名字还有别的信息（邮箱、单位、城市……）：$subject；按任务单重做一张"
      echo "$subject" | grep -Eq "CN *= *$IDENTITY(,|/|$| )" || fail "证书上的名字不是「$IDENTITY」：$subject"
    done
    rm -rf "$tmp"
  fi
  if codesign -dvv "$app" 2>&1 | grep -q "^TeamIdentifier=[A-Z0-9]"; then fail "签名里还有团队编号"; fi
  local team
  team=$(sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*//p' "$ROOT/Config/Local.xcconfig" 2>/dev/null | tr -d '[:space:]' || true)
  if [ -n "$team" ] && grep -rqa -- "$team" "$app"; then fail "包里有团队编号"; fi
  if LC_ALL=C grep -rqa -e "Apple Development" -e "Developer ID" "$app"; then fail "包里有开发证书的名字"; fi
  if LC_ALL=C grep -rqaE "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|cn|net|org|me|io)" "$app"; then fail "包里有邮箱地址"; fi
}

if [ "$IDENTITY" = "-" ]; then echo "▸ 临时签名（注意：每个新版本别人都要重给权限）"; else echo "▸ 用「$IDENTITY」证书签名（第一次会问能不能用钥匙串里的密钥，点\"始终允许\"）"; fi
sign "$APP"
echo "▸ 检查签名和包里没有个人信息"
check_signature "$APP"
REQUIREMENT=$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^#* *designated => //p')   # 系统自己生成的要求前面带 "# "
ARCHS=$(lipo -archs "$APP/Contents/MacOS/MacKit")

if $TEST_UPDATE; then
  echo "▸ 另打一个测试版（下一个版本号），看系统认不认它和 $VERSION 是同一个软件"
  rm -rf "$TEST_OUT"
  mkdir -p "$TEST_OUT/dmg"
  NEXT=$(echo "$VERSION" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  TEST_APP="$TEST_OUT/dmg/MacKit.app"
  ditto "$APP" "$TEST_APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEXT" -c "Set :CFBundleVersion $((BUILD + 1))" "$TEST_APP/Contents/Info.plist"
  sign "$TEST_APP"
  check_signature "$TEST_APP"
  if codesign --verify -R="$REQUIREMENT" "$TEST_APP" 2>/dev/null; then
    echo "  ✓ 测试版 $NEXT 符合 $VERSION 的签名要求：系统会认成同一个软件，权限不用重给"
  else
    fail "测试版 $NEXT 不符合 $VERSION 的签名要求（$REQUIREMENT）：更新后权限会丢"
  fi
  ln -s /Applications "$TEST_OUT/dmg/应用程序"
  hdiutil create -volname "MacKit $NEXT 测试版" -srcfolder "$TEST_OUT/dmg" -ov -format UDZO "$TEST_OUT/MacKit-$NEXT-测试版-别发布.dmg" >/dev/null
  rm -rf "$TEST_OUT/dmg"
fi

echo "▸ 做 dmg"
ln -s /Applications "$OUT/dmg/应用程序"
hdiutil create -volname "MacKit $VERSION" -srcfolder "$OUT/dmg" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$OUT/dmg"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
echo "$SHA  MacKit-$VERSION.dmg" > "$DMG.sha256"

echo "✓ 安装包：$DMG（$(du -h "$DMG" | cut -f1 | tr -d ' ')，$ARCHS）"
echo "  SHA-256：$SHA"
echo "  签名要求：$REQUIREMENT"
if $TEST_UPDATE; then echo "  测试版：$TEST_OUT/MacKit-$NEXT-测试版-别发布.dmg（只用来试更新，别发布）"; fi
echo "  （release.sh 每次会清空 build/release，发布说明放在 build/ 下面）"
