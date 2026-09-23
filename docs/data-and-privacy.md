# Data, accuracy, and privacy

[简体中文](data-and-privacy.zh-CN.md) · [README](../README.md)

## Sources and scope

Session Atlas reads the local `state_*.sqlite` catalog, optional `thread_history_*.sqlite` history, and JSONL rollout files under the selected Codex data directory. It chooses the newest numbered database for each supported family. These are Codex implementation details, not a stable public API contract.

The catalog covers all indexed local sessions, including archived/system entries. Filters affect what the UI displays, not what the collector may inspect. New log work is queued with bounded processing; history and context materials load incrementally or on demand. A complete catalog does not mean every historical byte has already been read.

Source SQLite connections are read-only with `query_only=ON`. The application does not write source sessions, edit Codex configuration, resume tasks, send prompts, or invoke models. For missing titles, it may launch the installed local `codex app-server` and request a state-database-only `thread/list`; it disables plugin/app features in that subprocess. It does not control all behavior of that installed Codex binary.

## Cache and network behavior

- Default source: `CODEX_HOME`, falling back to `~/.codex`.
- Default monitor cache: `~/Library/Application Support/CodexAgentMonitor`; override with `CODEX_MONITOR_CACHE`.
- The cache contains checkpoints, bounded event summaries, context/usage samples, deduplication data, and attention seen flags. It is not a complete copy of every source record, but summaries can still contain sensitive text. Protect it like the source data.
- Observed usage retention is bounded to 30 days. It does not reconstruct an all-time bill.
- The monitor contains no telemetry client, remote sync, or session-content upload path. The installer and release checks made by a user contact GitHub; opening a task invokes the local Codex URL handler. macOS can perform its own application security checks.
- Notifications, enabled only by choice, use generic app text rather than copying task/tool contents into the notification body.

## Accuracy boundaries

| Observation | Valid interpretation | Invalid interpretation |
| --- | --- | --- |
| Last event / latest turn state | Latest evidence received from supported persisted sources | An authoritative live process heartbeat |
| Recently active | Unfinished turn with execution/start evidence no older than five minutes | Every active OS process, or all cloud activity |
| Unconfirmed | Running was last recorded; freshness is insufficient | Definitely hung, stopped, or complete |
| Context sample | Recorded context use and capacity at one timestamp | Every exact model request body |
| Recorded text composition | Relative readable-character volume of categorized materials | Precise per-skill/per-message token costs |
| Compaction replacement | Materials actually listed in the recorded replacement set | Proof that all prior materials survived compaction |
| Opaque summary | A summary exists but its text cannot be read | Empty context or zero token use |
| Tool output size | Recorded visible-text size | Tokens currently retained in context |
| Observed usage | Usage observed and attributed by the collector | A provider invoice or exact lifetime expense |

A source failure retains prior observations and adds a diagnostic. Unknown values and partial history are intentionally visible. Newer compatible lifecycle evidence can supersede older persisted state. A failed tool does not automatically turn the parent task into a failed turn.

## Sharing diagnostics

Use synthetic inputs whenever possible. Task titles, project paths, prompts, tool results, screenshots, IDs, and caches can expose private work. Review and redact anything before posting it to an issue. The `MonitorProbe` utility reports counts, timings, and diagnostics without task titles or tool bodies, but its output should still be reviewed before sharing. See [SECURITY.md](../SECURITY.md).

## Project identity

MIT licensed. Independent community software; not affiliated with or endorsed by OpenAI. The icon's editable SVG is maintained in this repository. Apple system frameworks and SF Symbols are used through the platform; they are not redistributed as an external font or icon pack. The app has no third-party Swift package dependencies.
