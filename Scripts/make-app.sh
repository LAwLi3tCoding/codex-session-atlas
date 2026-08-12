#!/bin/zsh
set -euo pipefail

swift build -c release
bin_path="$(swift build -c release --show-bin-path)"
app_path="build/Codex Agent Monitor.app"
iconset_path="build/AppIcon.iconset"

swift Scripts/render-icon.swift Resources/AppIcon-1024.svg Resources/AppIcon-1024.png
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$iconset_path"
cp "$bin_path/CodexAgentDesktopMonitor" "$app_path/Contents/MacOS/"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
sips -z 16 16 Resources/AppIcon-1024.png --out "$iconset_path/icon_16x16.png" >/dev/null
sips -z 32 32 Resources/AppIcon-1024.png --out "$iconset_path/icon_16x16@2x.png" >/dev/null
sips -z 32 32 Resources/AppIcon-1024.png --out "$iconset_path/icon_32x32.png" >/dev/null
sips -z 64 64 Resources/AppIcon-1024.png --out "$iconset_path/icon_32x32@2x.png" >/dev/null
sips -z 128 128 Resources/AppIcon-1024.png --out "$iconset_path/icon_128x128.png" >/dev/null
sips -z 256 256 Resources/AppIcon-1024.png --out "$iconset_path/icon_128x128@2x.png" >/dev/null
sips -z 256 256 Resources/AppIcon-1024.png --out "$iconset_path/icon_256x256.png" >/dev/null
sips -z 512 512 Resources/AppIcon-1024.png --out "$iconset_path/icon_256x256@2x.png" >/dev/null
sips -z 512 512 Resources/AppIcon-1024.png --out "$iconset_path/icon_512x512.png" >/dev/null
cp Resources/AppIcon-1024.png "$iconset_path/icon_512x512@2x.png"
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"
echo "$app_path"
