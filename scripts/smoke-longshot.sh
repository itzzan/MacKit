#!/bin/bash
# 长截图实录检查：真的拍屏幕左上角一小块 1.5 秒（不弹窗口、不滚动、不存文件），看画面能不能送到、尺寸对不对；
# 再量一下大画面拼一张要多久。不放进 test.sh：它会真的拍你的屏幕（菜单栏会短暂出现系统的录屏标志）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT="$(mktemp -t mackit-longshot).txt"
"$ROOT/scripts/build.sh" >/dev/null
open -n "$ROOT/build/MacKit.app" --args --longshot-smoke "$RESULT"   # 用 open 启动，录屏权限才算在 MacKit 头上
for _ in $(seq 1 40); do [ -s "$RESULT" ] && break; sleep 0.5; done
cat "$RESULT"; echo
grep -q "SMOKE OK" "$RESULT"
