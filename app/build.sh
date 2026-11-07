#!/bin/sh
# builds build/REV Hub Updater.app
set -e
cd "$(dirname "$0")"
app="/Applications/REV Hub Updater.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o "$app/Contents/MacOS/RevHubUpdater" App.swift
cp Info.plist "$app/Contents/"
cp ../rev-hardware-client.mjs "$app/Contents/Resources/"
if [ -f logo.png ]; then
  cp logo.png "$app/Contents/Resources/"
  # app icon from logo
  tmp=$(mktemp -d); set=$tmp/AppIcon.iconset; mkdir "$set"
  swift icon.swift logo.png "$tmp/1024.png"
  for n in 16 32 128 256 512; do
    sips -z $n $n "$tmp/1024.png" --out "$set/icon_${n}x${n}.png" >/dev/null
    sips -z $((n*2)) $((n*2)) "$tmp/1024.png" --out "$set/icon_${n}x${n}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$app/Contents/Resources/AppIcon.icns"
  rm -rf "$tmp"
fi
codesign -s - --force "$app" >/dev/null 2>&1 || true
echo "built $app"
