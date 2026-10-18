#!/bin/zsh
# 构建 奶蛙桌宠.app（macOS 原生移植版）
# 用法：
#   ./build.sh                     # 自动在 ~/Projects/naiwa、../naiwa 等处寻找素材
#   NAIWA_ASSETS=/path ./build.sh  # 指定素材目录（需含 素材.nwp 与 原版笑声.wav）
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${NAIWA_CONFIG:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Naiwa"
APP="dist/奶蛙桌宠.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

cp "$BIN" "$APP/Contents/MacOS/Naiwa"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/使用说明-macOS.txt "$APP/Contents/Resources/使用说明-macOS.txt"

# 定位素材（优先使用仓库自带的 assets/，也支持从原项目目录读取）
ASSETS_DIR="${NAIWA_ASSETS:-}"
if [[ -z "$ASSETS_DIR" ]]; then
  for d in "assets" "$HOME/Projects/naiwa" "../naiwa" "."; do
    if [[ -f "$d/素材.nwp" ]]; then ASSETS_DIR="$d"; break; fi
  done
fi
if [[ -z "${ASSETS_DIR:-}" || ! -f "$ASSETS_DIR/素材.nwp" ]]; then
  echo "错误：找不到 素材.nwp。请设置 NAIWA_ASSETS=/素材所在目录 ./build.sh" >&2
  exit 1
fi

cp "$ASSETS_DIR/素材.nwp" "$APP/Contents/Resources/素材.nwp"
if [[ -f "$ASSETS_DIR/原版笑声.wav" ]]; then
  cp "$ASSETS_DIR/原版笑声.wav" "$APP/Contents/Resources/原版笑声.wav"
else
  echo "警告：素材目录里没有 原版笑声.wav，将只能静音运行。" >&2
fi

# 由素材生成应用图标
"$BIN" --make-icon "$APP/Contents/Resources/naiwa.icns" --assets "$ASSETS_DIR" >/dev/null

# 同时在 dist 根目录保留一份素材与说明，便于替换 / 查看
cp "$ASSETS_DIR/素材.nwp" "dist/素材.nwp"
if [[ -f "$ASSETS_DIR/原版笑声.wav" ]]; then cp "$ASSETS_DIR/原版笑声.wav" "dist/原版笑声.wav"; fi
cp Resources/使用说明-macOS.txt "dist/使用说明-macOS.txt"

# 本地 ad-hoc 签名（首次在本机构建即可直接运行）
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "构建完成：$(pwd)/$APP"
