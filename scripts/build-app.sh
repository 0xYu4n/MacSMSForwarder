#!/usr/bin/env bash
# =============================================================================
# Mac短信转发 打包脚本（纯 SwiftPM，无需 Xcode）
#
# 用法：
#   scripts/build-app.sh              # 编译本机架构的 Release 版，生成 dist/Mac短信转发.app
#   scripts/build-app.sh --universal  # 同时编译 arm64 + x86_64 并合并为通用二进制
#   scripts/build-app.sh --dmg        # 额外生成 dist/MacSMSForwarder-<版本>.dmg
#   scripts/build-app.sh --run        # 编译后结束旧进程并启动新版本
#
# 版本号读取自 version.env 中的 VERSION，可用环境变量 VERSION 覆盖
# =============================================================================
set -euo pipefail

# 切换到项目根目录
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Mac短信转发"
EXECUTABLE="MacSMSForwarder"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

# ---- 解析参数 ----
UNIVERSAL=0
MAKE_DMG=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --universal) UNIVERSAL=1 ;;
    --dmg) MAKE_DMG=1 ;;
    --run) RUN=1 ;;
    *) echo "未知参数：$arg" >&2; exit 1 ;;
  esac
done

# ---- 版本号 ----
# shellcheck disable=SC1091
[ -f version.env ] && source version.env
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
echo "==> 版本 ${VERSION}（构建号 ${BUILD_NUMBER}）"

# ---- 编译 ----
# 每个架构单独编译，最后用 lipo 合并（命令行工具环境下最稳妥的通用二进制方式）
if [ "$UNIVERSAL" = 1 ]; then
  ARCHS=(arm64 x86_64)
else
  ARCHS=("$(uname -m)")
fi

BINARIES=()
BUILD_DIR=""
for arch in "${ARCHS[@]}"; do
  echo "==> 编译 ${arch}"
  swift build -c release --triple "${arch}-apple-macosx14.0"
  BUILD_DIR="$(swift build -c release --triple "${arch}-apple-macosx14.0" --show-bin-path)"
  BINARIES+=("$BUILD_DIR/${EXECUTABLE}")
done

# ---- 组装 .app ----
echo "==> 组装 ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

if [ "${#BINARIES[@]}" -gt 1 ]; then
  lipo -create "${BINARIES[@]}" -output "${APP}/Contents/MacOS/${EXECUTABLE}"
else
  cp "${BINARIES[0]}" "${APP}/Contents/MacOS/${EXECUTABLE}"
fi

# Info.plist：替换版本号占位符
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD_NUMBER}/" \
  Resources/Info.plist > "${APP}/Contents/Info.plist"

# 依赖库的资源包（例如 PhoneNumberKit 的号码元数据、GRDB 的隐私清单）
# SwiftPM 生成的资源访问代码会在 Bundle.main.resourceURL 下查找这些 .bundle
find "$BUILD_DIR" -maxdepth 1 -name "*.bundle" -print0 | while IFS= read -r -d '' bundle; do
  cp -R "$bundle" "${APP}/Contents/Resources/"
done

# 应用图标：首次没有时自动生成
if [ ! -f Resources/AppIcon.icns ]; then
  echo "==> 生成应用图标"
  scripts/make-icon.sh
fi
cp Resources/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
# 打赏码图片
cp Resources/donate.jpg "${APP}/Contents/Resources/donate.jpg"

# ---- ad-hoc 签名 ----
# 未使用 Developer ID 证书；每次构建签名不同，系统可能要求重新授予「完全磁盘访问」
echo "==> ad-hoc 签名"
codesign --force --deep --sign - \
  --entitlements Resources/MacSMSForwarder.entitlements \
  "${APP}"
codesign --verify --verbose=1 "${APP}"

echo "==> 完成：${APP}"

# ---- 生成 DMG ----
if [ "$MAKE_DMG" = 1 ]; then
  DMG="$DIST/MacSMSForwarder-${VERSION}.dmg"
  STAGING="$(mktemp -d)"
  echo "==> 生成 ${DMG}"
  cp -R "${APP}" "$STAGING/"
  # 拖拽安装：放一个「应用程序」文件夹的快捷方式
  ln -s /Applications "$STAGING/Applications"
  rm -f "${DMG}"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "${DMG}" >/dev/null
  rm -rf "$STAGING"
  echo "==> 完成：${DMG}"
fi

# ---- 结束旧进程并启动新版本 ----
if [ "$RUN" = 1 ]; then
  echo "==> 结束旧进程"
  pkill -x "${EXECUTABLE}" 2>/dev/null || true
  sleep 1
  echo "==> 启动"
  open "${APP}"
fi
