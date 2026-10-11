#!/usr/bin/env bash
# 生成 Resources/AppIcon.icns（需要 macOS 自带的 iconutil）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
# 用 swiftc 编译后运行，避免依赖 SwiftPM
BIN="$(mktemp -d)/make-icon"
swiftc -O "$ROOT/scripts/make-icon.swift" -o "$BIN"
"$BIN" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/AppIcon.icns"
echo "已生成 $ROOT/Resources/AppIcon.icns"
