# Security / 安全说明

Session Atlas reads potentially sensitive local session data. Its own cache can include event summaries and should be protected like the original logs. Read-only source access does not make screenshots, copied details, or caches safe to publish.

Currently, fixes target the latest release on `main`. Older versions may need to be upgraded. Community release bundles are ad-hoc signed, not Apple-notarized.

## Report a vulnerability

Do not put exploit details, real logs, or credentials in public issues. Use [GitHub private vulnerability reporting](https://github.com/LAwLi3tCoding/codex-session-atlas/security/advisories/new) when it is enabled. If unavailable, open a minimal public issue requesting a private reporting channel, without disclosing the vulnerability or sensitive data.

Include the affected version, impact, and a minimal synthetic reproduction. Please allow the maintainer time to investigate; no response-time SLA is promised.

请勿在公开 Issue 中提交漏洞利用细节、真实日志或凭据。优先使用 GitHub 私密漏洞报告；入口不可用时，只提交请求私密联系渠道的说明，不公开敏感细节。

## Verify downloads

Use this repository's Releases and compare the matching SHA-256 checksum. This detects accidental corruption; an ad-hoc signature and checksum do not independently authenticate a publisher. Follow [Apple's launch guidance](https://support.apple.com/en-us/102445) and your organization's device policy. The installer never disables Gatekeeper or strips quarantine attributes.
