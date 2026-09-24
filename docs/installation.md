# Install Codex Session Atlas

[简体中文](installation.zh-CN.md) · [README](../README.md) · [User guide](usage.md)

## Requirements

- macOS 13 or newer, on Apple Silicon or Intel.
- Codex sessions persisted on this Mac. Remote-only sessions are not available.
- A universal ZIP release needs no compiler, package manager, API key, or extra account.
- Building from source needs Swift 6.1+ and Xcode or compatible Command Line Tools. Check `swift --version`; an older toolchain must be updated before building.

The app supports English and Simplified Chinese. Use **Settings → Language / 语言** to switch immediately; the choice is remembered. See the [user guide](usage.md#choose-a-language).

## Option 1: download the application

1. Open [the latest release](https://github.com/LAwLi3tCoding/codex-session-atlas/releases/latest).
2. Download the file ending in `macos-universal.zip`. The GitHub-generated “Source code” archives are not the application.
3. Unzip it and drag **Codex Session Atlas.app** into Applications, or into `~/Applications` for a per-user installation.
4. Open the application. The session list should begin loading automatically.

For an optional manual integrity check, download the matching `.zip.sha256` beside the ZIP, switch to that folder, and run:

```bash
shasum -a 256 -c Codex-Session-Atlas-0.9.1-macos-universal.zip.sha256
```

Use the filenames for the version you downloaded. The expected output ends in `OK`.

## Option 2: install from Terminal

```bash
curl -fsSL https://raw.githubusercontent.com/LAwLi3tCoding/codex-session-atlas/main/Scripts/install.sh -o /tmp/codex-session-atlas-install.sh
bash /tmp/codex-session-atlas-install.sh
```

You can inspect the downloaded script before running it. It uses macOS-provided tools, fetches the latest release, validates the archive checksum, verifies the app's signature and version, and installs into `~/Applications`. It does not need `sudo`.

Optional arguments:

```bash
# Pin a version and leave it closed after installation.
bash /tmp/codex-session-atlas-install.sh --version v0.9.1 --no-open

# Use another writable absolute directory.
bash /tmp/codex-session-atlas-install.sh --dir "$HOME/Applications"
```

Download or validation failures stop installation. An existing unrelated app or application symlink is not replaced. The installer does not register a login item or change Codex settings.

## First launch and Gatekeeper

The release is ad-hoc signed and has **no Apple Developer ID notarization**. A passing signature check establishes bundle integrity, not publisher identity.

If macOS blocks launch because the developer cannot be verified, first confirm that the file came from this repository's release and that the checksum matches. After attempting to open the app, use **System Settings → Privacy & Security → Open Anyway**, if available. See [Apple's instructions](https://support.apple.com/en-us/102445). Organization-managed Macs may disallow this exception.

If macOS reports malware or a damaged application, stop and recheck the download; do not disable Gatekeeper or run a blanket quarantine-removal command. A source build is another option when permitted by your device policy.

## Update and rollback

1. Quit the running application; closing its window does not quit it.
2. Rerun the installer or download a newer ZIP.
3. Confirm the version shown in the sidebar footer and that the session list loads.

The script keeps the replaced bundle as `Codex Session Atlas.previous.app` next to the new one. Once the new version works, move the previous app to Trash. If a backup already exists, the installer stops and asks you to move it first. To roll back, quit the new version, move it aside, and rename the previous app back.

Updating the app does not delete Codex sessions or the monitor's cache. Automatic in-app updating is not included.

## Custom data directory

The app reads `CODEX_HOME` when present, otherwise `~/.codex`. Finder launches do not necessarily inherit your shell environment. For a custom profile, quit the app and launch its executable from Terminal:

```bash
CODEX_HOME="$HOME/codex-profile" \
CODEX_MONITOR_CACHE="$HOME/Library/Application Support/SessionAtlas-Custom" \
"$HOME/Applications/Codex Session Atlas.app/Contents/MacOS/CodexSessionAtlas"
```

Use a separate cache for each profile. The environment variables above affect this launch only. The default cache remains `~/Library/Application Support/CodexAgentMonitor` for compatibility with earlier releases. The bundle identifier remains `app.agentmonitor.desktop`, preserving preferences and notification permissions.

## Build from source

```bash
git clone https://github.com/LAwLi3tCoding/codex-session-atlas.git
cd codex-session-atlas
swift run FixtureChecks
swift run ObservationChecks
Scripts/make-app.sh --universal
open "build/Codex Session Atlas.app"
```

Omit `--universal` to build for the current machine only. The script produces an ad-hoc signed app, a ZIP, and a matching SHA-256 file under `build/`. Release automation uses this same build script. Intel and Apple Silicon slices are included in the universal package; execution on each OS/architecture combination still needs separate validation.

## Troubleshooting

| Symptom | Check / recovery |
| --- | --- |
| No sessions appear | Confirm Codex has created local sessions; check the data directory in Settings. Remote-only sessions are not supported. |
| “Partial data unavailable” / 部分数据待恢复 | Read the diagnostic tooltip; the app retains its previous snapshot when a source is unavailable. New Codex formats may require an update. |
| Old task shows “Status unconfirmed” | This means no recent execution evidence, not a confirmed hang. Open the original task. |
| Terminal install cannot download | Check access to GitHub Releases and the API. Download the ZIP manually if the API is rate-limited. |
| Update says the app is running | Quit from the app menu or Dock, then retry. |
| Build fails after moving the checkout | Run `swift package clean`, then rebuild. Absolute paths in old compiler caches are no longer valid. |

## Uninstall

Quit the app and move its bundle to Trash. This leaves Codex sessions untouched. If you also want to discard the monitor's cached checkpoints, usage history, and seen flags, remove only `~/Library/Application Support/CodexAgentMonitor` (or the custom cache you selected). Preferences can be reset with `defaults delete app.agentmonitor.desktop`. Do not remove the Codex data directory to uninstall this app.
