# 安装 Codex Session Atlas

[English](installation.md) · [README](../README.zh-CN.md) · [使用手册](usage.zh-CN.md)

## 环境要求

- macOS 13 及以上，支持 Apple Silicon 和 Intel。
- 本机已有落盘的 Codex 会话；仅保存在远端的会话无法观察。
- 使用通用 ZIP 安装包，无需编译器、包管理器、API Key 或额外账号。
- 从源码构建需要 Swift 6.1+ 和 Xcode 或兼容的 Command Line Tools。先运行 `swift --version`，旧工具链需要更新后才能构建。

应用支持简体中文和英文。在「设置 → Language / 语言」切换后立即生效，并记住选择。

## 方式一：直接下载

1. 打开[最新 Release](https://github.com/LAwLi3tCoding/codex-session-atlas/releases/latest)。
2. 下载文件名以 `macos-universal.zip` 结尾的安装包。GitHub 自动提供的「Source code」是源码，不是应用。
3. 解压，将 **Codex Session Atlas.app** 拖入「应用程序」，或放入个人目录 `~/Applications`。
4. 打开应用，会话列表会自动开始加载。

如需手动校验，把对应 `.zip.sha256` 文件与 ZIP 放在同一个目录，在该目录执行：

```bash
shasum -a 256 -c Codex-Session-Atlas-0.9.0-macos-universal.zip.sha256
```

文件名应与下载版本一致。结果以 `OK` 结尾表示校验通过。

## 方式二：终端安装

```bash
curl -fsSL https://raw.githubusercontent.com/LAwLi3tCoding/codex-session-atlas/main/Scripts/install.sh -o /tmp/codex-session-atlas-install.sh
bash /tmp/codex-session-atlas-install.sh
```

可以先查看下载后的脚本再执行。脚本使用 macOS 自带工具，下载最新 Release，验证校验和、应用签名与版本，然后安装到 `~/Applications`，无需 `sudo`。

可选参数：

```bash
# 安装指定版本，安装完成后暂不启动。
bash /tmp/codex-session-atlas-install.sh --version v0.9.0 --no-open

# 指定有写入权限的绝对目录。
bash /tmp/codex-session-atlas-install.sh --dir "$HOME/Applications"
```

下载或校验失败时停止安装。脚本不会覆盖无关应用或应用符号链接，不会添加登录启动项，也不会修改 Codex 配置。

## 首次启动与系统提示

Release 使用临时签名，**尚未通过 Apple Developer ID 签名和公证**。签名校验可确认应用包完整性，不能确认发布者身份。

如果 macOS 因无法验证开发者而阻止启动，先确认文件来自本仓库 Release，且校验和一致。尝试打开后，在「系统设置 → 隐私与安全性」中选择「仍要打开」（如果系统提供该选项）。具体见 [Apple 官方说明](https://support.apple.com/en-us/102445)。受组织管理的 Mac 可能不允许添加例外。

如果系统报告恶意软件或应用损坏，应停止并重新核对下载，不要关闭 Gatekeeper 或批量移除隔离属性。设备策略允许时，也可以选择从源码构建。

## 更新与回退

1. 退出应用。只关闭窗口不会退出。
2. 重新运行安装脚本，或下载新版 ZIP。
3. 检查左侧底部版本号，并确认会话列表正常加载。

脚本将旧应用保留为同目录下的 `Codex Session Atlas.previous.app`。新版确认正常后，可将旧版移到废纸篓。如果已有备份，安装器会停止，要求先移走该备份。需要回退时，退出新版，将其移走，再把旧版恢复为原应用名。

更新应用不会删除 Codex 会话或监控缓存。当前没有应用内自动更新功能。

## 使用自定义数据目录

应用优先读取 `CODEX_HOME`，否则读取 `~/.codex`。从 Finder 启动不一定继承终端环境变量。使用自定义目录时，先退出应用，再从终端启动可执行文件：

```bash
CODEX_HOME="$HOME/codex-profile" \
CODEX_MONITOR_CACHE="$HOME/Library/Application Support/SessionAtlas-Custom" \
"$HOME/Applications/Codex Session Atlas.app/Contents/MacOS/CodexSessionAtlas"
```

不同数据目录应使用独立缓存。这些环境变量仅影响本次启动。为兼容旧版，默认缓存仍为 `~/Library/Application Support/CodexAgentMonitor`，应用标识仍为 `app.agentmonitor.desktop`，保留原有偏好和通知授权。

## 从源码构建

```bash
git clone https://github.com/LAwLi3tCoding/codex-session-atlas.git
cd codex-session-atlas
swift run FixtureChecks
swift run ObservationChecks
Scripts/make-app.sh --universal
open "build/Codex Session Atlas.app"
```

省略 `--universal` 可只构建当前机器架构。脚本在 `build/` 中生成临时签名应用、ZIP 和 SHA-256 文件；自动发布使用同一脚本。通用包包含 Intel 和 Apple Silicon 两种架构，但不同系统和架构组合的实际运行仍需分别验证。

## 常见问题

| 现象 | 检查与处理 |
| --- | --- |
| 没有会话 | 确认 Codex 已生成本地会话，在设置中检查数据目录；不支持仅在远端保存的会话。 |
| 显示「部分数据待恢复」 | 查看底部提示；源数据暂不可读时保留上次快照。Codex 数据格式变化可能需要更新应用。 |
| 历史任务显示「状态待确认」 | 表示近期没有执行证据，不是已确认卡死；请打开原任务核实。 |
| 脚本无法下载 | 检查 GitHub Releases 和 API 的可访问性；API 限流时可直接下载 ZIP。 |
| 更新提示应用仍在运行 | 从应用菜单或 Dock 退出，再重试。 |
| 移动源码目录后构建失败 | 执行 `swift package clean` 再构建，旧编译缓存中的绝对路径已经失效。 |

## 卸载

退出应用，将应用包移到废纸篓即可，不会删除 Codex 会话。如需丢弃监控器的检查点、用量历史和已看标记，只移除 `~/Library/Application Support/CodexAgentMonitor` 或自行指定的缓存目录。偏好可通过 `defaults delete app.agentmonitor.desktop` 重置。不要为了卸载本应用而删除 Codex 数据目录。
