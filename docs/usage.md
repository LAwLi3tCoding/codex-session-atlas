# User guide

[简体中文](usage.zh-CN.md) · [README](../README.md) · [Install](installation.md)

## Start with a question

Use **Overview** to find an issue, **Trace** to inspect what happened, **Context** to inspect recorded materials, and **Collaboration** to follow child tasks. Session Atlas observes persisted evidence; make changes in Codex or your project.

The current interface is in Chinese:

| UI label | Meaning |
| --- | --- |
| 概览 / 上下文 / 轨迹 / 协作 | Overview / Context / Trace / Collaboration |
| 全部 / 最近活跃 / 需关注 | All / Recently active / Needs attention |
| 内容明细 / 查看内容 | Material details / View content |
| 在 Codex 打开 / 我已看过 | Open in Codex / Mark as seen |
| 首次压缩前 / 第 N 次压缩后 | Before first compaction / After compaction N |
| 已记录内容的文本占比 | Composition of recorded readable text |

## Find and sort tasks

Search matches the task title, project path, model, agent nickname, or task ID. Use the project menu to narrow the list. The top-right list menu exposes system/archived tasks and the **Sort / 排序** selector.

- **Latest activity / 最近活动 (default):** newest first. A parent row uses the newest activity in its visible descendant group, even when collapsed. The row's time and the sorting time are the same.
- **Attention first / 需关注优先:** groups with unseen, unresolved attention items first, then latest activity. A child's attention item counts for its parent group.
- Individual activity uses the latest known execution event or turn start; until either is available, it falls back to catalog recency. Equal timestamps use a stable task-ID tie-breaker.
- Group aggregation is within the current filter/search result and the ancestors included to show its hierarchy. Filtering can therefore change a group's time.
- Parent tasks added only to show an active child's location say **Contains active child / 含活跃子任务**. That label is not evidence the parent itself is executing.

The chosen sorting mode persists. Orange attention dots no longer move an old task ahead of recent tasks unless attention-first order is selected.

## Understand status before acting

| State | Interpretation |
| --- | --- |
| 最近活跃 — Recently active | Unfinished turn; execution/start evidence within five minutes; excludes archived tasks from the active filter |
| 等待用户 — Waiting for input | A recorded waiting state; open the original task to act |
| 状态待确认 — Status unconfirmed | Last known state was running, but recent execution evidence is missing |
| 本轮结束 — Turn ended | The recorded turn ended; the wider user goal may still be incomplete |
| 失败 / 已中断 — Failed / Interrupted | A recorded turn-level outcome |
| 未知 — Unknown | Insufficient compatible data |

A failed tool can be retried successfully within a running task. An isolated tool failure does not by itself mean the entire task failed. Long commands with no recorded output can become unconfirmed without having stopped.

## Overview: find the next thing to inspect

The overview shows the latest recorded action, context usage, attention items, and recent events. Open an attention item's evidence before interpreting its suggested action. **Mark as seen** changes the monitor's local attention state; it does not fix or modify the original task. “Show resolved” reveals items the rules no longer consider active.

## Trace: follow execution

1. Select a record type: input, reply, tools, file changes, lifecycle/turns, and any other available types.
2. Use summary search or the failure filter. Counts and matches refer to **loaded records**, not all historical records.
3. Sort by time, output size, or known duration, depending on the question.
4. Click a record to inspect readable content. Source information identifies the local evidence; raw structure is available separately.
5. Load more history or detail pages when needed. The initial visible batch is bounded to keep interactions responsive.

**Turns / 轮次** filters lifecycle events, such as start/end records; it is not a complete turn-by-turn transcript switch. Visible reasoning summaries are only summaries already present in the local record, not hidden reasoning.

## Context: inspect a phase, sample, and material

1. Choose **Before first compaction** or an **After compaction N** phase. Never assume the earlier phase's materials still exist in a later one.
2. Select a recorded checkpoint using the chart or previous/next sample controls. Read the timestamp with the usage value.
3. Check **Context usage / 上下文使用率**: recorded used tokens divided by known capacity.
4. Read **Recorded text composition / 已记录内容的文本占比**. The colored categories compare readable characters, not exact tokens.
5. Select a category, sort for the longest material, or inspect **new between two samples**. Open the row to read its contents and origin.

Adjacent token changes are compared only when both samples belong to the same phase, model, and known capacity. Materials between the positions are evidence of what was recorded then, not proof of exact token causality. “Retained at compaction” means the replacement message set actually recorded those materials; missing replacement data remains explicitly unknown.

| Category | Includes | Does not establish |
| --- | --- | --- |
| 规则与指令 — Rules and instructions | Visible behavior rules, project constraints, permission/memory instructions | The full hidden system prompt |
| 可用技能说明 — Available skill descriptions | Skill descriptions and invocation conditions | That every listed skill was loaded or executed |
| 运行环境信息 — Runtime environment | Recorded directory, time, runtime/plugin metadata | Environment health |
| 用户输入 — User input | User requests and follow-ups | Unrecorded UI state |
| Agent 回复与进展 — Agent replies/progress | Recorded prose replies and progress | Tool-call arguments |
| 工具调用内容 — Tool calls | Commands, queries, edits, and other tool input | What the tool eventually returned |
| 工具返回 — Tool results | Output, file contents, search results, errors, including skill documents read through tools | Which text the model still retains |
| 压缩摘要 — Compaction summaries | Recorded summary text or an opaque-summary marker | Decrypted content of opaque summaries |
| 图片与附件 — Images/attachments | Attachment information visible in the log | Exact image/attachment token usage |

## Example: investigate context growth

Suppose two comparable samples show 40K and 70K tokens. This is an illustrative example, not a measured result from your task.

1. Select the later sample and inspect materials recorded since the prior sample.
2. If a large tool return appears, open it. Check whether it contains an entire file, repeated search results, or verbose logs.
3. Inspect the matching trace event and command. Consider a narrower query, bounded output, or targeted file sections in the next task.
4. Compare a similar later run. Check the tool output and context samples again.

Do not conclude that the return “cost exactly 30K tokens.” Other input and model request construction can contribute. Likewise, a large skill-description category suggests reviewing the catalog text; it does not prove a particular skill ran or wasted tokens.

## Collaboration and settings

The collaboration view links parent and child sessions with their own states and context samples. Inspect the child to see its evidence, then open it in Codex if intervention is needed. Parent and child capacities are separate; do not add their percentages.

The sidebar settings button controls repeat count/window, high-context threshold, large-output threshold, silence interval, and optional notifications. Notifications are off by default. Only definite new failure/waiting events are eligible; heuristic attention items do not all produce notifications.

Closing the window keeps the process observing. Reopen it from the Dock. Quitting ends collection; next launch resumes from saved checkpoints. The directory refresh target is about two seconds, while queued log work and cold-session reconciliation may take longer. This is observation of persisted data, not a guaranteed two-second end-to-end signal.

## When reporting a problem

Include the app version, macOS version, Mac architecture, expected/actual behavior, and the smallest synthetic example that reproduces it. Avoid real session exports or screenshots containing private titles, paths, prompts, or tool output. See [CONTRIBUTING.md](../CONTRIBUTING.md).
