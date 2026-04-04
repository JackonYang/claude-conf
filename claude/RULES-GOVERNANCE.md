# Rules Governance

Global rules 的变更流程。目的不是管文档结构，而是让规则持续反漂移而不自身成为漂移源。

## 变更流程

所有 CLAUDE.md 规则变更必须 issue-first。Issue 至少包含：

1. Bias — 这条规则在纠正模型的什么默认偏差
2. Failure mode — 不加这条规则，具体会发生什么坏结果（附实际案例或可复现场景）
3. Before / after comparison — 改前改后的行为差异如何验证，至少有一个 eval probe
4. Exit criteria — 什么条件下这条规则可以安全退出

规则合入后，上述四项记录在 `rules-rationale.md` 对应条目中。

## 规则生命周期

- 提出：开 issue，填上述四项
- 验证：在 PR 里附 eval 结果（behavioral test 或对话截图）
- 合入：PR merge 后规则生效
- 退休：当 exit criteria 满足时，开 issue 提议删除，附验证证据

## 边界

- 只管 CLAUDE.md 里的规则变更，不管 hooks / settings 的工程改动
- 紧急修正（规则导致明显错误行为）可以先改后补 issue，但 24h 内必须补
