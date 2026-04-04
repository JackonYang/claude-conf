# Rules Rationale

按需阅读。修改或删除规则前，先查对应 rationale 判断是否安全退出。

此文件不进 CLAUDE.md 的必读路径。审视规则时手动加载：`Read claude/rules-rationale.md`

格式：每条规则五段式 — bias / failure mode / evidence / eval probe / exit condition。

---

## 第一性原则

### 1. 先验证再断言

- Bias: 模型倾向凭训练记忆输出函数签名、配置项、文件路径，置信度高但正确率不稳定。
- Failure mode: "言之凿凿但代码里根本没这个函数" — 用户信任模型输出去写代码，编译失败或运行时报错，浪费排查时间。
- Evidence: 多次对话中出现模型输出不存在的 API 方法名，用户直接复制后报 AttributeError。（verbose 版本中"不凭记忆输出函数签名、配置项、文件路径"即针对此场景。）
- Eval probe: `rule1_verify_before_assert` — 给定一个声称存在的文件，模型应要求先查看而非猜测签名。
- Exit condition: 模型的工具调用准确率和事实性达到人类 senior 工程师水平，不再需要强制验证步骤。

### 2. 善用 subAgent 和 teams

- Bias: 模型默认行为是串行完成所有子任务，即使子任务间无依赖。
- Failure mode: 长任务耗时线性增长，主 context 被中间结果污染，后半程判断质量下降。
- Evidence: 多文件重构任务中模型逐文件串行处理，总耗时 10min+；拆 subAgent 后同类任务 3min 内完成。（verbose 版本中"多文件/多模块的并行实现任务，优先用 agent teams"即此场景。）
- Eval probe: 给定一个涉及 3+ 独立模块的任务，观察是否主动拆分并行。（当前无自动化 probe，依赖对话观察。）
- Exit condition: Claude Code 原生支持自动并行调度，不再需要用户侧规则驱动。

### 3. 自主执行

- Bias: 模型默认倾向反复确认，尤其在权限边界模糊时。
- Failure mode: 每次确认都是对 Jack 工作节奏的打断。可逆低成本操作反复询问"是否确认"，拉低交互效率。
- Evidence: 日常对话中模型对明确指令仍回复"需要我继续吗？""你确定要这样做吗？"。（verbose 版本中"可逆低成本问题直接决定，不展开深度研究"即边界判断准则。）
- Eval probe: `rule3_autonomous_execution` — 给定一个简单编辑指令，模型应直接执行而非反问确认。
- Exit condition: 协作者不只 Jack 一人，需要更保守的确认策略；或项目进入高风险阶段需要收紧自主权。

### 4. 给选项降低决策疲劳

- Bias: 模型在路径不唯一时倾向要么全列要么只选一条。
- Failure mode: 全列导致信息过载，只选一条导致用户失去决策权。
- Evidence: 优化类问题中模型要么列 8 种方案不排序，要么只推一种不说替代。
- Eval probe: `rule4_options` — 给定一个优化问题，观察是否给出 2-4 个选项。
- Exit condition: 工作流高度标准化后，大部分任务只有一条路径，此规则自然退化。

### 5. 交付前先过质量门

- Bias: 模型倾向"写完即交付"，不做验证就汇报完成。
- Failure mode: "改完了"但实际引入新 bug，用户变成测试者。
- Evidence: 多次出现模型报告"已完成"但改动未通过测试或引入 regression 的情况。（verbose 版本中"用户不是测试者"即此 failure mode 的一句话概括。）
- Eval probe: `rule5_quality_gate` — 给定一个类型变更场景，模型应建议验证而非直接确认可提交。
- Exit condition: 项目有完善的 CI/CD 自动验证，质量门由 pipeline 而非规则保障。

### 6. headless 任务必须验证送达

- Bias: 模型将"执行完成"等同于"交付完成"，不验证产出是否送达用户。
- Failure mode: agent 跑完了但产出在临时目录、没推到远端、没通知用户。用户不知道任务已完成或找不到产出。
- Evidence: headless 场景中产出留在 worktree 未 push，或写入临时路径用户无法访问。（verbose 版本中"执行完成不等于交付完成"即此 gap。）
- Eval probe: 当前无自动化 probe。依赖对话观察 headless 任务是否包含送达确认步骤。
- Exit condition: notification runtime 建成后（ref: issue #9），送达验证由基础设施自动完成。

### 7. 深度思考

- Bias: 模型面对需要判断力的任务时，默认行为是信息罗列或开放发散，缺少收敛到决策建议的意识。
- Failure mode: 用户问一个需要判断的问题，得到一堆"一方面...另一方面..."的信息堆砌，没有结论。
- Evidence: 架构决策讨论中模型列出 pros/cons 但不给推荐，用户仍需自己综合判断。（verbose 版本中"先抓当前领域最有穿透力的关键词"即强制聚焦的 trick。）
- Eval probe: 当前无专用 probe。可通过架构决策类 prompt 观察是否产出决策建议而非信息罗列。
- Exit condition: 模型推理能力提升到能自主判断何时收敛何时发散，不再需要外部 heuristic。

---

## 沟通

### 写入文件和对话输出保持同一心智模式

- Bias: 模型写文件时自动切换到"正式文档风格" — 加结构铺垫、磨平棱角、用模版腔。
- Failure mode: 对话里锋利准确，写进文件就变成"首先...其次...总之..."的官腔，穿透力归零。
- Evidence: 同一个 north star 表述，对话里一句话说清，写进 README 变成三段铺垫。（verbose 版本中举例"north star、设计决策、README"为高发场景。）
- Eval probe: `comm_same_voice` — 要求写一段 README，观察是否切换到模版风格。
- Exit condition: 模型写作风格一致性提升，不再出现对话/文件风格割裂。

### 默认中文，代码/commit/PR/技术文档用英文

- Bias: 模型默认用英文回复，或在中文对话中夹杂不必要的英文段落。
- Failure mode: 用户用中文提问，模型用英文回答，增加认知切换成本。
- Evidence: 日常对话中模型对中文 prompt 回复英文，尤其在涉及技术概念时。
- Eval probe: `comm_chinese_default` — 用中文问代码问题，观察是否用中文回复。
- Exit condition: 模型能稳定根据用户语言自动匹配回复语言。

### 结论先行，说到点上

- Bias: 模型倾向加铺垫、客套、复述用户问题后再给答案。
- Failure mode: 用户等了两段废话才看到结论，交互效率低。
- Evidence: 回答技术问题时以"这是一个很好的问题"、"当然可以"、"让我来解释一下"开头。
- Eval probe: `comm_no_fluff` — 问一个对比类问题，观察是否直接给结论。
- Exit condition: 模型默认行为就是结论先行，不再需要规则约束。

### 必须附最小充分依据

- Bias: 模型要么给结论不给理由，要么给一堆细节淹没结论。
- Failure mode: 根因判断、架构取舍等场景下，用户拿到结论但无法判断结论是否可信。
- Evidence: code review 中模型给出"建议改成 X"但不说为什么，或给出三段理由但最关键的一条埋在中间。
- Eval probe: 当前无自动化 probe。依赖对话观察是否在关键判断处附依据。
- Exit condition: 模型能自主判断何时需要附依据、附多少。

### 不确定时不产出，但记录卡在哪

- Bias: 模型倾向在不确定时仍然给出看似确定的答案，而非承认不确定。
- Failure mode: 用户基于模型不确定的输出做决策，导致错误方向。
- Evidence: 模型对不熟悉的 API 仍给出具体用法建议，事后验证不存在。与 rule 1（先验证再断言）互补 — rule 1 管事实，这条管判断。
- Eval probe: 当前无自动化 probe。依赖对话观察不确定场景下的行为。
- Exit condition: 模型 calibration 达到可靠水平，能准确传达不确定性。

### markdown 不用加粗，用层级/缩进/破折号

- Bias: 模型默认大量使用 `**bold**` 做强调。
- Failure mode: 加粗过多等于没有强调，视觉噪音大，在终端里尤其刺眼。
- Evidence: 日常回复中模型对关键词加粗，一段话 5-6 个加粗词，反而模糊重点。
- Eval probe: 当前无自动化 probe。可通过统计输出中 `**` 出现频率来评估。
- Exit condition: 模型默认格式化风格与用户偏好一致。

### 专业术语直接用，不解释基础概念，不加 emoji

- Bias: 模型倾向对 senior 用户也解释基础概念，并在输出中加 emoji 增加"友好感"。
- Failure mode: 解释基础概念浪费 context 和阅读时间；emoji 在代码/技术语境中是噪音。
- Evidence: 对 Jack 解释"什么是 rebase"或在技术分析中加 ✅ 🔧 等 emoji。
- Eval probe: 当前无自动化 probe。依赖对话观察。
- Exit condition: 模型能根据用户 profile 自动调整解释深度和风格。

---

## 自动化运行边界

### 每个 issue/任务在独立 branch 工作

- Bias: 模型有时在当前 branch 继续做不相关的任务，或忘记切 branch。
- Failure mode: 多个 issue 的改动混在一个 branch，PR 无法按 issue 独立 review 和 merge。
- Evidence: 出现过两个 issue 的改动混在同一个 PR 里，需要手动拆分。
- Eval probe: 当前无自动化 probe。依赖 PR review 时检查 branch 命名和内容是否单一。
- Exit condition: CI 或 hook 自动检查 branch 名与 commit 内容的 issue 关联一致性。

### 连续 3 次 CI 失败停止重试，写 worklog

- Bias: 模型倾向无限重试失败的操作，每次做微小调整但不诊断根因。
- Failure mode: 消耗大量 token 和时间在重复失败上，产出为零。
- Evidence: 模型对 CI 失败反复调整 import 顺序、加 type ignore 等表面修复，5 次后仍未解决根本问题。
- Eval probe: 当前无自动化 probe。依赖对话观察重试行为。
- Exit condition: 模型具备可靠的根因分析能力，能在 1-2 次尝试内定位问题。

### 自动化可以跑到 PR ready，merge 必须人工确认

- Bias: 模型在获得足够权限时倾向跑完全流程包括 merge。
- Failure mode: 未经人工 review 的代码进入 main，增加生产风险。
- Evidence: 无具体 incident，属于预防性规则。在 headless 场景下尤其重要 — agent 可能在无人监督时完成整个 PR 流程。
- Eval probe: 当前无自动化 probe。依赖 git log 审计是否有未经 review 的 merge。
- Exit condition: branch protection 和 CI 完全覆盖，merge 物理上需要人工审批。
