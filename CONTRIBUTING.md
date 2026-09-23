# Contributing / 参与贡献

Thank you for helping make local Codex sessions easier to understand. Useful contributions include format compatibility, synthetic regression cases, clearer explanations, performance fixes, accessibility, and an English UI.

欢迎改进格式兼容、合成回归用例、内容解释、性能、可访问性和英文界面。请优先描述实际遇到的问题与可验证结果。

## Development

- macOS 13+, Swift 6.1+, Xcode or compatible Command Line Tools.
- `Sources/SessionAtlasCore`: read-only collection, parsing, attention rules, context reconstruction, session ordering.
- `Sources/CodexSessionAtlas`: SwiftUI application and readable record presentation.
- `Sources/FixtureChecks` and `Sources/ObservationChecks`: executable checks using synthetic data.

```bash
swift run FixtureChecks
swift run ObservationChecks
swift build
Scripts/make-app.sh --universal
```

Tests do not require XCTest or access to personal Codex sessions. For a visible UI change, also inspect the app on macOS; a successful build alone does not validate layout. For parsing changes, add the smallest synthetic source record that demonstrates the issue and expected behavior.

## Pull requests

Keep changes focused. Describe the problem, resulting behavior, and validation. Preserve unknown/partial data instead of inventing precision. Keep SQLite source access read-only. Never introduce model calls, analytics, external uploads, or destructive controls as an incidental change.

Update both READMEs and both language guides when changing public behavior. Preserve existing preference/cache compatibility or provide an explicit migration.

## Reports and privacy

Search existing issues, then provide app/macOS versions, architecture, reproducible steps, expected/actual behavior, and sanitized evidence. Do not include actual sessions, private project names, local user paths, credentials, employer information, or a whole cache. If you cannot safely isolate the data, describe the schema and use invented values.

请不要提交真实会话导出、私有项目内容、用户名路径、凭据或完整缓存。优先用虚构数据复现；截图也需要逐项检查。

## License and conduct

Contributions are accepted under the repository's MIT license. Be respectful, focus feedback on the work, and avoid harassment or disclosure of another person's information. By submitting code or assets, you confirm you have the right to contribute them. Do not copy proprietary assets or private logs into fixtures.
