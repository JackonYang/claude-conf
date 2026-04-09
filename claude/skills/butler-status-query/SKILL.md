---
name: butler-status-query
description: Use ONLY when this session is the butler dedicated session (cwd is waypoint repo, CLAUDE.md declares the butler role) AND owner asks about progress/status. Trigger phrases (Chinese): "进展" / "现状" / "现在啥情况" / "status" / "有什么要我处理的". Do not invoke in arbitrary CC sessions even if these phrases appear.
---

# Butler Status Query — Response SOP

## Triggers

- "进展" / "现状" / "现在啥情况" / "status" / "有什么要我处理的"
- 任何 owner 显式问"butler 现在在做什么"的等价表达

## Hard Rules

1. 永远按 thread/topic 视角聚合输出，禁止按 dispatch entry 时间倒序列流水账
2. dispatch table 不只是任务记录，是 owner 与 butler 的 shared working context 载体 — 输出目标是让 owner 跨 session 复出后 5 秒内 anchor 上"在做什么、卡在哪、下一步选什么"
3. 触发条件不满足（不在 butler dedicated session）则不调用本 skill

## 数据源

- active 表: `~/.butler/dispatches.yaml`
- 归档目录: `~/.butler/archive/`
- 相关 repo 的 open issues: 按 dispatch table 涉及到的 repo 查 `gh issue list` / `glab issue list`

active + archive 合并读取，不受 24h 归档规则影响 — 归档只是物理位置变化，读取时合并即可。

## 输出结构

### 1. 活跃主线（thread narrative）

把 active 表 + archive 里的 dispatch 按 thread 聚合后，每条 thread 一段 narrative。聚合规则：

- 主分组按 destination.repo（同一 repo 的 dispatch 大概率是同一条 thread）
- 同 repo 内按 issue/PR/MR 号 + intent 关键词二次聚类（PR #6 → PR #13 → PR #15 是同一条线）
- "已完成且无后续"的 thread 不进此段，归到第 3 段 footer

每条 thread 一段，格式：

```
N. <thread 名称>（<destination repo / 远程 machine>）
   <来路 narrative：怎么走到这里的，关键节点用 PR/issue 号 + 语义 anchor 串起来>
   当前：<当前状态 + 等谁的下一步> [<status>, <dispatch_id>]
```

排序：thread 内部按"最高优先级 status"为锚（blocked > delivered > running）。同级按 updated_at 降序。

如果一条 thread 涉及多个 dispatch（如 PR #6/#13/#15 的演进），dispatch_id 只标注当前 active 的那条。

如无活跃主线，明确写 "当前没有活跃主线"。

### 2. 下一步候选（next moves）

数据源：相关 repo 的 open issues（`gh issue list` / `glab issue list`，只查 dispatch table 已涉及的 repo），加 butler 自己的判断。

过滤：排除已在第 1 段 thread 中的 issue。

排序：按 readiness — 可独立起步 > 等依赖（注明依赖谁）> 战略级 / 非 actionable。

数量：2-3 条最优先的，不要列全。每条一行：

```
- <repo> <issue/PR 号> <语义 anchor> — <一句推荐理由 / 依赖说明>
```

省略条件：如无可推荐项，整段省略，不写"无候选"占位。

### 3. 收尾 footer

一行带过"已完成且无后续"的 thread。例：

```
收尾：issue #5 (butler bootstrap) 复盘已确认可 close
```

无 footer 内容时省略。

### 4. 结尾引导

一句轻量引导（"要继续做点什么吗" / "按建议起 X 吗" / "选哪条主线推进"），不刷消息流。

## 兜底

- 如果 table + archive 都为空：说 "当前没有任何 dispatch 记录，给我一个请求"
- 如果只有 footer 没有活跃主线和 next moves：说 "当前没有进行中的事，最近完成的：..."

## 输出形态参考

```
两条活跃主线：

1. butler ledger 演进（waypoint）
   PR #6 (groundwork) → 实跑发现 4 gap → PR #13 (schema fix) 修复 → PR #15 (ledger as shared context) 升级
   当前：PR #15 ready，等你 fresh session 验收 + merge [delivered, d-14e1a7]

2. AICASimPlatform #146 调试信号质量（远程 101）
   已完成可执行性评估：scope 1/2/4 (pre-flight、flaky 分流、failure taxonomy) 可立刻起步，scope 3 (smoke gate) 阻塞于 #142
   当前：等你决策先拆分推进 1/2/4 还是先顶 #142 [delivered, d-30589c]

下一步候选：
- waypoint #11 skill 化 + 多入口 — 等 #14 ledger 形态稳定后动
- waypoint #9 每日巡检 — 依赖 #14 summary 写作规范成型，PR #15 merge 后可起

收尾：issue #5 (butler bootstrap) 复盘已确认可 close

要先把 PR #15 merge 掉再起 #11 / #9 吗？
```
