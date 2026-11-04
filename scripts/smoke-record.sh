#!/bin/bash
# 录屏实录检查：真的录三次（屏幕左上角一小块 2 秒、最前面的窗口 1.5 秒、整屏 1.5 秒），
# 检查 mp4 的画面、声音轨、尺寸、时长，然后删掉视频。不弹窗口、不开麦克风。
# 不放进 test.sh：它会真的录你的屏幕（菜单栏会短暂出现系统的录屏标志）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT="$(mktemp -t mackit-smoke).txt"
"$ROOT/scripts/build.sh" >/dev/null
open -n "$ROOT/build/MacKit.app" --args --record-smoke "$RESULT"   # 用 open 启动，录屏权限才算在 MacKit 头上
for _ in $(seq 1 40); do [ -s "$RESULT" ] && break; sleep 0.5; done
cat "$RESULT"; echo
grep -q "SMOKE OK" "$RESULT"
