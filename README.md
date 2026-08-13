# Codex Agent Monitor

A native macOS desktop panel for observed Codex Agent activity. It is a normal `.app`, not a menu-bar app or WidgetKit extension.

## Build and run

Requirements: macOS 13+, Swift 6 toolchain, and the system SQLite library.

```zsh
swift run FixtureChecks
Scripts/make-app.sh
open "build/Codex Agent Monitor.app"
```

The panel uses the standard macOS window level: it can be brought in front of other apps, but it is not permanently always-on-top. It remains draggable and resizable, remembers its frame, joins all Spaces, and refreshes every five seconds. Its layout adapts from a compact workspace-grouped list, to a multi-column overview, to a wide-screen session inspector with the selected main/sub-Agent tree.

`Scripts/make-app.sh` renders `Resources/AppIcon-1024.svg` to an ignored, generated 1024px PNG with AppKit, validates its transparent alpha bounds, generates the standard multi-resolution macOS `.icns`, and ad-hoc signs the finished local bundle so macOS can launch the copied SwiftPM executable safely.

## Data sources

The app combines two local Codex sources:

- experimental `codex app-server` `thread/list` for the same generated/user-renamed title exposed by Codex Desktop (`name`, then `preview`, then thread ID)
- `~/.codex/state_5.sqlite`, opened in SQLite read-only mode, for runtime metadata, activity timestamps, and spawn edges

It displays:

- main-session identity and current-work label from app-server; when app-server is unavailable, trimmed SQLite `name`, then `title`, then the full thread identifier
- sub-Agent identity from runtime `agent_nickname` and the child thread ID
- sub-Agent current-work label from the same runtime title map; when absent, the structured `agent_path` leaf may be humanized, but it is never used to infer the model or reasoning effort
- workspace sections from the final `cwd` path component; absolute paths are never displayed
- runtime `model` and `reasoning_effort`
- optional role, tokens, and update time
- parent-child edges from `thread_spawn_edges`, with an unambiguous `agent_path` fallback when edges are missing

The monitor does not query `auth.json`, credentials, or tool inputs/outputs, and it does not log thread titles or previews. It does not change Codex routing/model configuration. Missing app-server, databases, busy/WAL states, or optional schema fields degrade to the best available local snapshot and clear diagnostics.

## Status accuracy and experimental boundary

`codex app-server` is marked **experimental** by the installed Codex CLI, and its protocol has no public stability guarantee. The app keeps a persistent local app-server subprocess for titles and automatically falls back to SQLite if it cannot start or respond. The title integration may need updating when Codex changes that protocol.

Sessions are shown as active when the latest of `recency_at_ms` and `updated_at_ms` falls within the last 15 minutes. This keeps long-running tasks visible when Codex updates the execution heartbeat without changing recency ordering. A stale ancestor is retained only when needed to attach an active descendant; it is labeled **Active child** and is not counted as directly active. Internal `codex-auto-review` guardian threads are excluded because that runtime alias does not expose a reliable underlying model. Activity remains an inferred SQLite window; app-server is currently authoritative only for display titles.

## Checks

`FixtureChecks` creates temporary SQLite databases and verifies responsive-layout boundaries, selection fallback, app-server title override, full-length SQLite fallback titles, root recognition, parent-child tree construction, current-work metadata, direct model/effort mapping, and schema degradation. It has no third-party dependencies.
