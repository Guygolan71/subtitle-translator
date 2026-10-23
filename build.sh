#!/bin/bash
# Builds "Subtitle Translator.app" (universal: Apple Silicon + Intel) and zips it.
set -euo pipefail
cd "$(dirname "$0")"

APP="Subtitle Translator"
BUILD=build
rm -rf "$BUILD"
mkdir -p "$BUILD"

for arch in arm64 x86_64; do
  echo "== compiling $arch"
  swiftc -O -parse-as-library -target "${arch}-apple-macos13.0" \
    -o "$BUILD/st-$arch" Sources/main.swift
done
lipo -create -output "$BUILD/SubtitleTranslator" "$BUILD/st-arm64" "$BUILD/st-x86_64"

C="$BUILD/$APP.app/Contents"
mkdir -p "$C/MacOS" "$C/Resources"
cp "$BUILD/SubtitleTranslator" "$C/MacOS/SubtitleTranslator"
cp Info.plist "$C/Info.plist"

echo "== icon"
ICONSET="$BUILD/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$C/Resources/AppIcon.icns"

echo "== signing (ad-hoc)"
codesign --force --deep --sign - "$BUILD/$APP.app"
codesign --verify --verbose "$BUILD/$APP.app"

echo "== zipping"
(cd "$BUILD" && ditto -c -k --keepParent "$APP.app" SubtitleTranslator.zip)
ls -la "$BUILD"
echo "BUILD OK"
