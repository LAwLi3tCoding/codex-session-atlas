#!/bin/bash
# Install an official release without Git, Swift, Homebrew, or administrator access.
set -euo pipefail
repo='LAwLi3tCoding/codex-session-atlas'
version='latest'
install_dir="$HOME/Applications"
open_app=true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --version|--dir)
      [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 2; }
      if [ "$1" = '--version' ]; then version="$2"; else install_dir="$2"; fi
      shift 2 ;;
    --no-open) open_app=false; shift ;;
    -h|--help)
      echo 'Usage: bash install.sh [--version v0.8.0] [--dir DIRECTORY] [--no-open]'
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ "$(uname -s)" = Darwin ] || { echo 'Requires macOS 13 or newer.' >&2; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 13 ] || { echo 'Requires macOS 13 or newer.' >&2; exit 1; }
case "$(uname -m)" in arm64|x86_64) ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
case "$install_dir" in /*) ;; *) echo '--dir must be an absolute directory path.' >&2; exit 2 ;; esac
if pgrep -x CodexSessionAtlas >/dev/null || pgrep -x CodexAgentDesktopMonitor >/dev/null; then
  echo 'Quit Codex Session Atlas before installing or updating.' >&2
  exit 1
fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/session-atlas-install.XXXXXX")"
pending=''
cleanup() { rm -rf "$stage"; if [ -n "$pending" ]; then rm -rf "$pending"; fi; }
trap cleanup EXIT
fetch() { curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 "$1" -o "$2"; }
if [ "$version" = latest ]; then
  fetch "https://api.github.com/repos/$repo/releases/latest" "$stage/release.json"
  version="$(plutil -extract tag_name raw "$stage/release.json")"
fi
if ! [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then echo 'Use a release version such as v0.8.0.' >&2; exit 2; fi
asset="Codex-Session-Atlas-${version#v}-macos-universal.zip"
base="https://github.com/$repo/releases/download/$version"
fetch "$base/$asset" "$stage/$asset"
fetch "$base/$asset.sha256" "$stage/checksum"
# Accept exactly the expected checksum entry; never treat remote text as commands or paths.
expected="$(awk -v name="$asset" 'NF == 2 && $2 == name {print $1}' "$stage/checksum")"
if ! [[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]]; then echo 'Invalid checksum file.' >&2; exit 1; fi
actual="$(shasum -a 256 "$stage/$asset" | cut -d' ' -f1)"
[ "$actual" = "$expected" ] || { echo 'Checksum mismatch; nothing installed.' >&2; exit 1; }
# Reject traversal and unexpected top-level entries before extraction.
if ! unzip -Z1 "$stage/$asset" | awk '
  /^\// || /(^|\/)\.\.($|\/)/ {bad=1}
  $0 !~ /^Codex Session Atlas\.app\// {bad=1}
  END {exit bad}
'; then echo 'Unexpected archive layout; nothing installed.' >&2; exit 1; fi
ditto -x -k "$stage/$asset" "$stage/unpacked"
app="$stage/unpacked/Codex Session Atlas.app"
codesign --verify --deep --strict "$app"
[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" = app.agentmonitor.desktop ] || { echo 'Unexpected app identifier.' >&2; exit 1; }
[ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" = "${version#v}" ] || { echo 'Unexpected app version.' >&2; exit 1; }
mkdir -p "$install_dir"
target="$install_dir/Codex Session Atlas.app"
if [ -L "$target" ]; then echo 'Refusing to replace an application symlink.' >&2; exit 1; fi
if [ -e "$target" ]; then
  [ "$(plutil -extract CFBundleIdentifier raw "$target/Contents/Info.plist" 2>/dev/null)" = app.agentmonitor.desktop ] || { echo 'The target is a different application.' >&2; exit 1; }
fi
pending="$(mktemp -d "$install_dir/.session-atlas-install.XXXXXX")"
ditto "$app" "$pending/Codex Session Atlas.app"
codesign --verify --deep --strict "$pending/Codex Session Atlas.app"
backup="$install_dir/Codex Session Atlas.previous.app"
if [ -e "$target" ]; then
  [ ! -e "$backup" ] || { echo 'Move the existing .previous.app backup before updating again.' >&2; exit 1; }
  mv "$target" "$backup"
fi
if ! mv "$pending/Codex Session Atlas.app" "$target"; then
  if [ -e "$backup" ]; then mv "$backup" "$target"; fi
  echo 'Install failed; previous version restored.' >&2; exit 1
fi
echo "Installed Codex Session Atlas ${version#v}."
echo 'This community build is ad-hoc signed, not Apple-notarized. macOS may require Open Anyway in Privacy & Security.'
if [ -e "$backup" ]; then echo 'The previous application is saved next to the new one; remove it after verification.'; fi
if [ "$open_app" = true ]; then open "$target"; fi
