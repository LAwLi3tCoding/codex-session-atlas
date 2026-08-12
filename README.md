# Codex Agent Monitor

A native macOS desktop panel for observed Codex Agent activity. It is a normal `.app`, not a menu-bar app or WidgetKit extension.

## Build and run

Requirements: macOS 13+, Swift 6 toolchain, and the system SQLite library.

```zsh
swift run FixtureChecks
Scripts/make-app.sh
open "build/Codex Agent Monitor.app"
```

The panel uses the standard macOS window level: it can be brought in front of other apps, but it is not permanently always-on-top. It remains draggable and resizable, remembers its frame, joins all Spaces, and refreshes every five seconds.

`Scripts/make-app.sh` renders `Resources/AppIcon-1024.svg` to an ignored, generated 1024px PNG with AppKit, validates its transparent alpha bounds, and generates the standard multi-resolution macOS `.icns`.

## Data and privacy boundary

The MVP opens `~/.codex/state_5.sqlite` with SQLite's read-only mode. It reads only thread metadata and spawn edges:

- main-session identity and current-work label from a single-line `name` or `title` no longer than 80 characters; multiline or long values are not displayed
- sub-Agent identity from runtime `agent_nickname` and the child thread ID
- sub-Agent current-work label from the same safe `name`/`title`; when absent, the structured `agent_path` leaf may be humanized, but it is never used to infer the model or reasoning effort
- workspace sections from the final `cwd` path component; absolute paths are never displayed
- runtime `model` and `reasoning_effort`
- optional role, tokens, and update time
- parent-child edges from `thread_spawn_edges`, with an unambiguous `agent_path` fallback when edges are missing

It never reads `auth.json`, conversation text, tool inputs/outputs, or credentials. It does not write to Codex files or change Codex routing/model configuration. Missing databases, busy/WAL states, or missing activity metadata produce a clear empty state; missing optional display fields use safe `Unavailable` labels.

## Status accuracy and experimental boundary

`codex app-server` is marked **experimental** by the installed Codex CLI, and no public, stable event protocol was available for this MVP. The app therefore labels every status as an **observed SQLite snapshot**.

Sessions are shown as active when the latest of `recency_at_ms` and `updated_at_ms` falls within the last 15 minutes. This keeps long-running tasks visible when Codex updates the execution heartbeat without changing recency ordering. A stale ancestor is retained only when needed to attach an active descendant; it is labeled **Active child** and is not counted as directly active. Internal `codex-auto-review` guardian threads are excluded because that runtime alias does not expose a reliable underlying model. This is an inferred activity window, not an exact real-time execution state. A future app-server adapter should remain opt-in and retain this SQLite fallback.

## Checks

`FixtureChecks` creates temporary SQLite databases and verifies root recognition, parent-child tree construction, current-work metadata and fallbacks, direct model/effort mapping, and safe schema degradation. It has no third-party dependencies.
