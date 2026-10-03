#!/bin/bash
# 编译 JoyClicker.app 到 build/；加 --install 装进 /Applications 并重新启动
set -euo pipefail
cd "$(dirname "$0")"

APP=build/JoyClicker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -framework AppKit -framework IOKit -framework ServiceManagement \
  -o "$APP/Contents/MacOS/JoyClicker" JoyClicker.swift
cp Info.plist "$APP/Contents/"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

# 签名：有开发者证书就用它，重编译后「辅助功能」授权不会失效；没有就 ad-hoc（每次重编译都要重新授权）
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "==> ${APP}（签名：${IDENTITY:-ad-hoc}）"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x JoyClicker || true
  rm -rf /Applications/JoyClicker.app
  cp -R "$APP" /Applications/
  open /Applications/JoyClicker.app
  echo "==> 已装到 /Applications 并启动"
fi
