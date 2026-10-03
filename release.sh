#!/bin/bash
# 打发布包到 dist/：Mac 通用二进制 dmg + Windows x64 exe
# Mac 发布包只做 ad-hoc 签名：开发者证书名里带个人信息，签进去谁都能用 codesign -dv 看到
set -euo pipefail
cd "$(dirname "$0")"
VER=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
STAGE=$(mktemp -d)
APP="$STAGE/JoyClicker.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" \
    -framework AppKit -framework IOKit -framework ServiceManagement \
    -o "$STAGE/JoyClicker-$arch" JoyClicker.swift
done
lipo -create -output "$APP/Contents/MacOS/JoyClicker" "$STAGE"/JoyClicker-arm64 "$STAGE"/JoyClicker-x86_64
cp Info.plist "$APP/Contents/"
cp AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
ln -s /Applications "$STAGE/Applications"
rm -f "$STAGE"/JoyClicker-arm64 "$STAGE"/JoyClicker-x86_64
rm -f "dist/JoyClicker-$VER-macOS.dmg"
hdiutil create -quiet -volname "JoyClicker" -srcfolder "$STAGE" -ov -format UDZO "dist/JoyClicker-$VER-macOS.dmg"
rm -rf "$STAGE"

(cd windows && GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-H windowsgui -s -w" \
  -o "../dist/JoyClicker-$VER-Windows-x64.exe" .)
rm -f dist/JoyClicker-Windows-x64.exe
ls -lh dist/
