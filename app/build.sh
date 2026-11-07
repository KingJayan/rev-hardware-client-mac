#!/bin/sh
# builds build/REV Hub Updater.app
set -e
cd "$(dirname "$0")"
app="build/REV Hub Updater.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13.0" \
  -o "$app/Contents/MacOS/RevHubUpdater" App.swift
cp Info.plist "$app/Contents/"
cp ../rev-hardware-client.mjs "$app/Contents/Resources/"
[ -f logo.png ] && cp logo.png "$app/Contents/Resources/"
codesign -s - --force "$app" >/dev/null 2>&1 || true
echo "built $app"
