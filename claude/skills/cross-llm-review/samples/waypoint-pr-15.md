## Summary

This PR overhauls the "status query" and context-sharing mechanisms between the owner and butler in the system. It replaces the old triage view with a richer, thread-based narrative that merges active and archived dispatches, introduces stricter summary writing guidelines, and clarifies the display and archival rules for dispatches, especially around weekends and context retention.

## Concerns

### CLAUDE.md
> ```diff
> +summary 是 recent context 段的载体 — owner 24 小时甚至 3 天后看到这条，必须能立刻明白做了什么、为什么、结果如何。它不是机器元数据，是给人读的 context。
> +写作要求：
> +1. 自包含 — 不依赖 dispatch_id、不依赖 owner 记得当时上下文。owner 隔几天回来看到这条，必须能立刻读懂。
> +...
> +状态推进时（dispatched → delivered/green/blocked），summary 必须随之改写以反映新结果，不能停留在 dispatch 时的初稿。
> ```

**Risk:**  
The new summary requirements are much stricter and require manual discipline or code enforcement. If not programmatically enforced, summaries may still be left in an outdated or incomplete state, especially during rapid status transitions. This could undermine the intended context clarity.

---

> ```diff
> +active + archive 合并读取，不受 24h 归档规则影响 — 归档只是物理位置变化，读取时合并即可。
> ```

**Risk:**  
Merging active and archived dispatches for context display is a sound idea, but if the archive grows large, this could introduce performance issues or unbounded memory usage, especially if not paginated or limited to "recent N" as described. The spec says "最近 3-5 条 summary" but does not clarify if this is enforced in code.

---

> ```diff
> +相关 repo 的 open issues（按 dispatch table 涉及到的 repo 去查 `gh` / `glab`）
> ```

**Risk:**  
Querying external issue trackers (GitHub/GitLab) for every status query could introduce latency, rate-limiting, or failure modes if the network is down or credentials are missing. There is no mention of error handling or fallback behavior.

---

### dispatch-table.md

> ```diff
> +2. butler 自完成 general 任务时：执行成功且无需 owner 决策的，直接推 status → green，last_update_source=auto_complete。这条任务进入 archive 流程（24h 后归档），不在 active items 段显示，但仍可能出现在 recent context 段（最近 N 条范围内）。
> ```

**Risk:**  
The distinction between "active items" and "recent context" is now more nuanced. If the code that generates these views is not updated in lockstep, there is a risk of confusion or inconsistency in what the owner sees, especially for green/archived items.

---

## Questions for the author

1. Is there code in place to enforce the new summary writing requirements, or is this purely a documentation/process change?
2. How is the "recent N" (3-5) limit enforced when merging active and archived dispatches for the context view? Is there a risk of unbounded output?
3. What is the fallback behavior if external issue tracker queries fail or are slow? Is the status query robust to network/API errors?
4. Are there automated tests covering the new context loading and thread narrative logic, especially for edge cases (e.g., empty archive, only archived items, large archives)?

## What looks good

- The separation of "recent context" and "active items" is well-motivated and addresses real user workflow pain points.
- The summary writing guidelines are clear, actionable, and likely to improve long-term context retention.
- The documentation is thorough, with concrete examples and anti-patterns, which will help maintainers and users understand the new expectations.

---
_cross-llm-review · model: see invocation · premiumRequests: 0 · api: 101315ms · session: 103079ms_
[cross-llm-review] kept isolation dir: /tmp/cross-llm-review/1775650600-26870
