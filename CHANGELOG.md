# Changelog

## 0.8.0 — 2026-09-24

- Default session ordering uses recent activity, includes descendants, and displays the same time used for ranking. Stable task-ID ties avoid arbitrary reordering.
- Added a saved attention-first sort option, with child attention propagated to groups.
- Renamed the repository, package, and application executable to Codex Session Atlas names. Preserved existing cache/preference identifiers.
- Added MIT licensing, bilingual READMEs and manuals, accuracy/privacy guidance, contribution/security information, issue templates, and CI.
- Added universal macOS release builds and a checksum-verifying installer with update backup and rollback behavior.

## 0.7.2 — 2026-09-23 (local build)

- Adopted the white session-monitor icon selected from the design candidates.

## 0.7.1 — 2026-09-23 (local build)

- Adopted the Codex Session Atlas name and session/trace/context positioning.

## Earlier local development

- Added incremental all-session observation, execution traces, context phases/materials, usage samples, attention rules, and parent/child collaboration.
- Refined the interface toward a neutral native macOS style.
- Bounded trace rendering to resolve lifecycle-filter freezes; replaced stale persisted running flags with evidence-based recent activity and an unconfirmed state.

Earlier local validation notes remain in [docs/acceptance.md](docs/acceptance.md); they describe historical builds, not a promise about every current environment.
