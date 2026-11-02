#!/bin/bash
# 编译并装到 ~/Applications/MacKit.app，然后启动（加 --no-open 只装不启动）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HOME/Applications/MacKit.app"

"$ROOT/scripts/build.sh"
if pkill -x MacKit 2>/dev/null; then sleep 0.5; fi
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
cp -R "$ROOT/build/MacKit.app" "$DEST"
echo "✓ 已安装：$DEST"
if [ "${1:-}" != "--no-open" ]; then open "$DEST"; echo "✓ 已启动，看菜单栏右上角的扳手图标"; fi
