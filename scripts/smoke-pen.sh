#!/bin/bash
# 屏幕画笔实录检查：真的录屏幕左上角一小块 2 秒，同时用屏幕画笔在那里画一条红线、打开放大镜（台阶 22），看视频里有没有红线和放大镜的蓝框；录完删掉视频。
# 不放进 test.sh：它会真的录你的屏幕（菜单栏会短暂出现系统的录屏标志，左上角会闪一下红线和放大镜）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESULT="$(mktemp -t mackit-pen).txt"
"$ROOT/scripts/build.sh" >/dev/null
open -n "$ROOT/build/MacKit.app" --args --pen-smoke "$RESULT"   # 用 open 启动，录屏权限才算在 MacKit 头上
for _ in $(seq 1 40); do [ -s "$RESULT" ] && break; sleep 0.5; done
cat "$RESULT"; echo
grep -q "SMOKE OK" "$RESULT"
