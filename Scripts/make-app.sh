#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Build each slice separately: this also works with Command Line Tools only.
architectures=("$(uname -m)")
archive_arch="$(uname -m)"
if [[ "${1:-}" == "--universal" ]]; then
  architectures=(arm64 x86_64)
  archive_arch="universal"
elif [[ $# -gt 0 ]]; then
  echo "Usage: Scripts/make-app.sh [--universal]" >&2
  exit 2
fi
binaries=()
for architecture in "${architectures[@]}"; do
  build_args=(-c release --scratch-path ".build/distribution-$architecture" --arch "$architecture"
    -Xswiftc -debug-prefix-map -Xswiftc "$PWD=."
    -Xswiftc -file-prefix-map -Xswiftc "$PWD=.")
  swift build "${build_args[@]}" --product CodexSessionAtlas
  bin_path="$(swift build "${build_args[@]}" --show-bin-path)"
  binaries+=("$bin_path/CodexSessionAtlas")
done
mkdir -p build
stage="$(mktemp -d "$PWD/build/package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
app_path="$stage/Codex Session Atlas.app"
iconset_path="$stage/AppIcon.iconset"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$iconset_path"
lipo -create "${binaries[@]}" -output "$app_path/Contents/MacOS/CodexSessionAtlas"
strip -S "$app_path/Contents/MacOS/CodexSessionAtlas"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp LICENSE "$app_path/Contents/Resources/LICENSE.txt"
swift Scripts/render-icon.swift Resources/AppIcon-1024.svg "$stage/icon.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$stage/icon.png" --out "$iconset_path/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$stage/icon.png" --out "$iconset_path/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$app_path/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict "$app_path"
app_version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
archive_name="Codex-Session-Atlas-$app_version-macos-$archive_arch.zip"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noacl --keepParent "$app_path" "build/$archive_name"
(cd build && shasum -a 256 "$archive_name" > "$archive_name.sha256")
# Only replace this script's generated application, never source or user data.
rm -rf "build/Codex Session Atlas.app"
mv "$app_path" "build/Codex Session Atlas.app"
echo "build/Codex Session Atlas.app"
echo "build/$archive_name"
