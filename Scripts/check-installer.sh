#!/bin/bash
# Exercise the installer against a locally built release; only transport/process checks are stubbed.
set -euo pipefail
cd "$(dirname "$0")/.."
archive="${1:?Usage: Scripts/check-installer.sh build/release.zip}"
export ATLAS_TEST_ARCHIVE="$(cd "$(dirname "$archive")" && pwd)/$(basename "$archive")"
version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
export ATLAS_TEST_VERSION="$version"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/session-atlas-installer-check.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin"
cat > "$test_root/bin/curl" <<'STUB'
#!/bin/bash
set -eu
url=''; out=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://*) url="$1"; shift ;;
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$url" in
  */releases/latest) printf '{"tag_name":"v%s"}\n' "$ATLAS_TEST_VERSION" > "$out" ;;
  *.zip.sha256)
    if [ "${ATLAS_TEST_BAD_CHECKSUM:-0}" = 1 ]; then
      printf '%064d  %s\n' 0 "$(basename "$ATLAS_TEST_ARCHIVE")" > "$out"
    else cp "$ATLAS_TEST_ARCHIVE.sha256" "$out"; fi ;;
  *.zip) cp "$ATLAS_TEST_ARCHIVE" "$out" ;;
  *) exit 1 ;;
esac
STUB
cat > "$test_root/bin/pgrep" <<'STUB'
#!/bin/bash
# Do not let an unrelated running development app invalidate this isolated test.
exit 1
STUB
chmod +x "$test_root/bin/"*
export PATH="$test_root/bin:$PATH"
run_install() { bash Scripts/install.sh --dir "$test_root/apps" --no-open > "$test_root/output" 2>&1; }
if ! run_install; then cat "$test_root/output"; exit 1; fi
test -x "$test_root/apps/Codex Session Atlas.app/Contents/MacOS/CodexSessionAtlas"
# A failed checksum must leave the installed application intact.
before="$(shasum -a 256 "$test_root/apps/Codex Session Atlas.app/Contents/MacOS/CodexSessionAtlas")"
export ATLAS_TEST_BAD_CHECKSUM=1
if run_install; then echo 'FAIL: accepted incorrect checksum'; exit 1; fi
test "$before" = "$(shasum -a 256 "$test_root/apps/Codex Session Atlas.app/Contents/MacOS/CodexSessionAtlas")"
unset ATLAS_TEST_BAD_CHECKSUM
if ! run_install; then cat "$test_root/output"; exit 1; fi
test -d "$test_root/apps/Codex Session Atlas.previous.app"
if run_install; then echo 'FAIL: overwrote existing backup'; exit 1; fi
# Existing symlinks and unrelated apps must not be replaced.
mv "$test_root/apps" "$test_root/completed"
mkdir -p "$test_root/apps"
ln -s "$test_root/completed/Codex Session Atlas.app" "$test_root/apps/Codex Session Atlas.app"
if run_install; then echo 'FAIL: replaced application symlink'; exit 1; fi
rm "$test_root/apps/Codex Session Atlas.app"
mkdir -p "$test_root/apps/Codex Session Atlas.app"
if run_install; then echo 'FAIL: replaced unrelated application'; exit 1; fi
echo 'Installer checks passed: latest download, verified install, checksum rejection, update backup, backup protection, symlink protection, unrelated app protection.'
