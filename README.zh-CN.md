<div align="center">
  <img src="Resources/AppIcon-1024.svg" width="96" alt="Codex Session Atlas 图标">
  <h1>Codex Session Atlas</h1>
  <p><strong>看清 Codex 正在做什么，以及什么内容占用了上下文。</strong></p>
  <p>原生 macOS 会话监控工具，集中查看执行轨迹、上下文组成、Token 用量与子 Agent 活动。</p>
  <p><a href="https://github.com/LAwLi3tCoding/codex-session-atlas/releases/latest">下载 Mac 版</a> · <a href="docs/installation.zh-CN.md">安装手册</a> · <a href="docs/usage.zh-CN.md">使用手册</a> · <a href="README.md">English</a></p>
  <p>
    <a href="https://github.com/LAwLi3tCoding/codex-session-atlas/actions/workflows/ci.yml"><img src="https://github.com/LAwLi3tCoding/codex-session-atlas/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
    <a href="https://github.com/LAwLi3tCoding/codex-session-atlas/releases/latest"><img src="https://img.shields.io/github/v/release/LAwLi3tCoding/codex-session-atlas" alt="最新版本"></a>
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555555" alt="MIT 许可证"></a>
    <img src="https://img.shields.io/badge/macOS-13%2B-555555" alt="macOS 13 及以上">
  </p>
</div>

同时运行多个 Codex 任务时，逐个打开会话很难及时发现等待输入、工具反复失败或上下文突然增长。Session Atlas 把本地会话目录、执行记录和已记录的上下文材料放在同一个窗口，支持查看证据，再返回原任务处理。

**本地数据、只读观察，无需 API Key，不额外调用模型。** 应用支持简体中文和 English，可在「设置 → Language / 语言」即时切换；会话原文保持不变。README、安装手册和使用手册也提供中英文版本。

![会话活动、执行轨迹与上下文材料三种观察视角；图中为示例，不是真实会话截图。](docs/assets/overview.svg)

## 它能帮你分析什么

| 想解决的问题 | 观察入口 | 可以据此采取的行动 |
| --- | --- | --- |
| 哪个任务需要我处理？ | 最近活动、等待用户、需关注事项 | 返回 Codex 补充输入或处理失败 |
| 为什么执行变慢或失败？ | 失败调用、已记录耗时、重复调用及返回内容 | 修复具体命令，缩小后续排查范围 |
| 两次采样之间，上下文为什么变大？ | 上下文采样与两次采样间新增材料 | 收窄工具输出，减少重复读取 |
| 项目规则或 Skills 是否过于冗长？ | 可见规则、技能说明及具体正文 | 看清材料后，再调整 `AGENTS.md` 或技能提示 |
| 子 Agent 分别在做什么？ | 父子会话树与协作页 | 独立检查各子任务的状态和上下文 |

## 已有功能

- **会话列表：** 本地目录、项目和模型搜索、归档及系统任务筛选、父子关系。默认按整组最近活动排序，也可选择「需关注优先」。
- **执行轨迹：** 查看已记录的输入、回复、工具调用、文件修改、轮次事件、压缩和可见推理摘要；筛选已加载记录，展开可读正文与来源。
- **上下文分析：** 按压缩阶段查看使用率采样、已记录文本占比、保留与新增材料，以及相邻采样变化。
- **需关注事项：** 呈现失败、等待输入、重复操作、大输出和高占用提示，附带依据，阈值可调整。
- **原生桌面体验：** SwiftUI 界面、本地增量采集、历史分页、可选系统通知；关闭窗口继续观察，退出应用停止采集。

## 几分钟开始使用

要求 **macOS 13 及以上**、Apple Silicon 或 Intel Mac，以及已保存在本机的 Codex 会话。

**直接下载：** 从 [Releases](https://github.com/LAwLi3tCoding/codex-session-atlas/releases/latest) 下载 `macos-universal.zip`，解压后把 **Codex Session Atlas.app** 拖入「应用程序」。无需安装 Xcode、Swift 或 Homebrew。

**终端安装：** 下载安装脚本，可先查看内容，再执行：

```bash
curl -fsSL https://raw.githubusercontent.com/LAwLi3tCoding/codex-session-atlas/main/Scripts/install.sh -o /tmp/codex-session-atlas-install.sh
bash /tmp/codex-session-atlas-install.sh
```

脚本自动下载最新通用版本，检查 SHA-256 和应用签名，安装到 `~/Applications`，无需 `sudo`。更新时保留一个旧版本备份。脚本不会修改 Codex 数据，也不会关闭 macOS 安全检查。

社区构建使用**临时签名，尚未通过 Apple 公证**。首次启动被阻止时，按[安装手册](docs/installation.zh-CN.md#首次启动与系统提示)操作。校验和只能确认文件完整性，不等于 Apple 开发者身份认证。

## 第一次可以这样看

1. 打开应用，默认读取 `~/.codex` 中的本地数据。
2. 选择任务，在「概览」查看最近动作、上下文使用率与需关注事项。
3. 进入「轨迹」，展开一次失败调用或较大的工具返回。
4. 进入「上下文」，选择阶段和采样，查看最长材料，或比较两次采样之间新增的内容。
5. 通过「在 Codex 打开」返回原任务处理。

[使用手册](docs/usage.zh-CN.md)提供完整分析示例、分类解释、排序规则与设置说明。

## 先分清这几种数字

| 指标 | 表示什么 | 不能据此推断什么 |
| --- | --- | --- |
| 上下文使用率 | 最近采样的已用上下文 Token ÷ 已记录容量 | 不是每一次模型请求的实时完整视图 |
| 已记录内容的文本占比 | 按材料类别统计可读字符数量 | **不是精确 Token 占比**，不包含不可见正文 |
| Token 消耗 | 日志中已记录的请求、轮次或会话用量 | 不等于当前上下文占用，也不是费用账单 |
| 最近活跃 | 轮次未结束，近 5 分钟有执行或开始记录 | 长命令无输出也可能变为「状态待确认」，不能据此判定卡死 |

工具无法读取隐藏推理、解密不透明摘要、补全日志缺失的系统提示或工具定义，也无法观察未落盘到本机的远端会话。「本轮结束」不等于整个用户目标已完成。历史不完整或数据缺失时会保留提示与未知值。[数据口径与隐私](docs/data-and-privacy.zh-CN.md)

## 隐私与兼容性

应用只读本地 SQLite 索引和 JSONL 日志，在自身缓存中保存检查点、有限摘要及用量。不上传会话内容，不含遥测，不编辑源会话。缺少标题时，可通过本地 `codex app-server` 的 `thread/list` 补全标题；监控器不会发送模型请求或恢复任务命令。Codex 子进程自身的行为不由监控器控制。

这些本地格式属于 Codex 实现细节，可能随版本变化。应用会提示字段缺失或数据不可读，但不保证兼容所有 Codex 版本。当前不提供云同步、跨机器监控、自动修复或精确计费。

## 从源码构建与参与贡献

需要 **Swift 6.1+** 与 macOS 开发工具。无第三方包依赖。

```bash
git clone https://github.com/LAwLi3tCoding/codex-session-atlas.git
cd codex-session-atlas
swift run FixtureChecks
swift run ObservationChecks
Scripts/make-app.sh --universal
open "build/Codex Session Atlas.app"
```

欢迎补充经过脱敏的格式兼容用例、改善上下文解释、排查性能问题或参与英文界面适配。提交 Issue 或 PR 前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。不要上传真实会话日志、凭据或私有项目内容。

## 文档导航

- [安装与故障排查](docs/installation.zh-CN.md) · [Installation](docs/installation.md)
- [使用手册](docs/usage.zh-CN.md) · [User guide](docs/usage.md)
- [数据口径与隐私](docs/data-and-privacy.zh-CN.md) · [Data and privacy](docs/data-and-privacy.md)
- [更新记录](CHANGELOG.md) · [安全说明](SECURITY.md) · [贡献指南](CONTRIBUTING.md)
- [架构与采集设计](docs/design.md)

采用 [MIT 许可证](LICENSE)。这是独立社区项目，不是 OpenAI 官方产品。Codex 和 OpenAI 名称仅用于说明兼容对象，不表示官方认可。
