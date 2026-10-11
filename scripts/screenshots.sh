#!/usr/bin/env bash
# 生成 README 用的功能截图，输出到 docs/screenshots/
# 原理：以截图模式启动 App（内存演示数据，不读写真实数据、不启动收发服务），
#       依次切换页面并截取自身窗口，完成后自动退出。过程中屏幕上会短暂出现窗口。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/docs/screenshots"
mkdir -p "$OUT"

# 先组装 .app（截图需要 App 包中的图标、资源和版本号）
scripts/build-app.sh

# 直接运行包内可执行文件，并通过环境变量进入截图模式
MSF_SCREENSHOT_DIR="$OUT" "dist/Mac短信转发.app/Contents/MacOS/MacSMSForwarder"

echo "==> 截图已保存到 $OUT"
ls -1 "$OUT"
