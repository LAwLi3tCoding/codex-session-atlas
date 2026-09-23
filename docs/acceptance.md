# Validation / 验证

## 0.9.0

- `swift run FixtureChecks`: passed. `swift run ObservationChecks`: 27 synthetic scenarios passed.
- Localization checks cover both languages, all catalog placeholders, Unicode/source arguments, cached labels, source-text collisions, encrypted-content markers and detail pagination independent of visible text.
- A legacy-checkpoint rebuild preserves collected token usage and seen markers.
- Native UI checks on Apple Silicon cover English settings/layout, restart persistence, trace-filter retention, historical context sample retention, context categories and an open opaque-content sheet switching languages. Source excerpts remain unchanged.
- English sort controls and the task sidebar accommodate longer labels. App-owned menus and the language shortcut menu update immediately.
- Universal arm64/x86_64 build, strict signature verification and isolated installer checks pass. Intel runtime has not been tested on hardware.
- Both READMEs and installation/user guides describe language selection and source-text preservation. macOS-owned permission dialogs continue to use the system language.

## 0.8.0

- `swift run FixtureChecks`: passed.
- `swift run ObservationChecks`: 23 synthetic scenarios passed, including activity freshness, group ordering, stable ties, attention-first sorting, cycle termination, context phases, token deduplication, pagination, source replacement, and recovery.
- The catalog scale scenario uses 5,000 synthetic sessions and 20 updating logs; it is not a claim about arbitrary workloads or a production latency guarantee.
- Universal release build contains arm64 and x86_64 slices. The ZIP, SHA-256, and strict code-signature checks pass. Runtime UI checks were performed on Apple Silicon; Intel hardware has not been directly tested.
- The default recent-activity mode, attention-first menu selection, and return to the default mode were exercised in the native application. The footer reports v0.8.0.
- The installer has isolated checks for successful installation, incorrect checksum rejection, update backup, and refusal to overwrite existing backups, symlinks, or unrelated applications. CI reruns them against its own release archive.
- Local document links and source whitespace checks pass. Published sources pass the configured GitHub privacy inspection before push.

The [CI workflow](../.github/workflows/ci.yml) records checks for each pushed revision. The [release workflow](../.github/workflows/release.yml) tests and packages tagged source before publishing downloadable assets. A successful cross-architecture build is not evidence of execution on every supported macOS version.

中文：本版回归使用合成数据。通用包包含两种架构，原生界面验证在 Apple Silicon 上完成，未直接验证 Intel 硬件。历史样本或单次耗时不作为性能保证；当前版本的流水线结果以 GitHub Actions 为准。
