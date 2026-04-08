---
name: copilot-second-opinion
description: Second-opinion review on a PR or issue via GitHub Copilot CLI (a different model family from Claude). Two modes — manual gpt-5.4 for high-stake moments, automatic gpt-4.1 sub-agent in parallel during Claude self-review for blind-spot coverage.
---

# copilot-second-opinion

让另一个模型家族（OpenAI via Copilot CLI）对 Claude 的判断做 second opinion。Claude review Claude 是同模型同 bias，对方向 blind spot 几乎无效，需要"非 Claude 的眼睛"来兜底。

Tracks: claude-conf #17.

## When to use

两个模式，按调用方判断。

### Mode A — 关键时刻手动触发

触发：

- owner 直接说 "用 second opinion 看一下 PR/issue X"
- Claude 主动判断"这是个方向决策 / 架构取舍 / 高 stake review"，建议 owner 跑一次

频率：按工作量挂钩，不按日历

- 大 issue：draft 后 / 设计中 / 动手前 各一次
- 大 PR：方向 / 设计 / pre-merge 各一次

模型：`gpt-5.4`（premium）。低频高 stake，烧 1 个 premium request 换最强 reasoning，值。

### Mode B — Claude self-review 时 sub-agent 并行

触发：**任何 Claude self-review 自己工作的节点**

- 准备 mark PR ready-for-review 之前
- 多步任务 final delivery 之前
- 显式 `/self-review` 之前
- 任何 "let me check my own work" 的时刻

实现：主线 Claude 自己跑 self-review 的同时，**fork 一个 sub-agent 并行跑 copilot**，最后两份意见并列呈现给 owner。不要串行——copilot ~40-100s wall，串行会显著拖慢交付，且独立性会被主线观察污染。

模型：`gpt-4.1`（`premiumRequests=0`，免费）。高频，cost 必须接近零；用途是 blind-spot 兜底而非决策权威，gpt-4.1 够用。

## 调用模板

```bash
cd /tmp/copilot-iso-$(date +%s) && mkdir -p . && \
~/.local/share/gh/copilot/copilot \
  --model <gpt-5.4 | gpt-4.1> \
  --no-custom-instructions \
  --disable-builtin-mcps \
  --no-ask-user \
  --silent \
  --output-format json \
  --allow-all-tools \
  --allow-all-paths \
  -p "$PROMPT"
```

`$PROMPT` 是 prompt 模板 + inline 的 PR/issue body 全文，下面 "Prompt 模板" 段说怎么拼。

### Isolation 三件套（硬约束，任一缺失都会污染 second opinion 的独立性）

1. **`--no-custom-instructions`** — 阻止 `AGENTS.md` / `CLAUDE.md` auto-load。否则 copilot 把自己当成 cwd 项目的 agent 而不是中立 reviewer。
2. **`--disable-builtin-mcps`** — 关掉默认 connected 的 `github-mcp-server`。否则跨 repo 时它会成污染源。**事故记录**：在 waypoint cwd 跑过一次"reply OK"探测，copilot 自动读 `dispatches.yaml` 并写入了一条假 dispatch 才返回 OK——拥有写权限就会用。
3. **隔离 cwd** — 进 copilot 前必须 `cd` 到一个空 `/tmp` 子目录。即使前两个 flag 都加了，cwd 还是决定了"哪些工具的工作半径在这里"，不能省。

如果想"为这一次省 2 秒钟"绕过其中任何一条 — 停下，那等于没跑这个 skill。

## Prompt 模板

两个，照抄替换占位符即可。Mode B 复用模板 1。

### 模板 1 — PR 方向 review（Mode A 主用 + Mode B 复用）

```
帮我 review 一下 PR #<NNN>，对应的 issue 是 #<MMM>。特别的，先看看是否有方向性的错误或者 goals 的偏差，设计是否合理，然后再看细节。

=== PR 内容 ===
<INLINE: gh pr view NNN + gh pr diff NNN 的完整输出>

=== 关联 issue 内容 ===
<INLINE: gh issue view MMM 的完整输出>
```

重点不是"找 bug"，是"方向 / goals / 设计"。细节是次要的。

### 模板 2 — Issue 价值 / 清晰度 review（Mode A）

```
帮我看一下下面这个 issue，看一下是否讲清楚了问题的背景、目标，这是不是一个有价值的真实需求，title 和 desc 有误导性吗？是否合理。

=== ISSUE 内容 ===
<INLINE: gh issue view NNN 的完整输出（含 title + body）>
```

用在 issue 写完后、动手前的"自检关"。防止把模糊或错误的需求当成事实开干（issue #17 自己的 v0 body 就踩了这个，#23 据此跑偏）。

## 调用形态示例

### Mode A 手动触发

```bash
# 准备 prompt
PROMPT_FILE=/tmp/prompt-$$.md
{
  echo "帮我 review 一下 PR #15，对应的 issue 是 #14。先看方向 / goals / 设计，再看细节。"
  echo
  echo "=== PR 内容 ==="
  gh pr view 15 -R JackonYang/waypoint
  echo
  gh pr diff 15 -R JackonYang/waypoint
  echo
  echo "=== 关联 issue 内容 ==="
  gh issue view 14 -R JackonYang/waypoint
} > "$PROMPT_FILE"

# 进 isolated cwd 调 copilot
ISO=/tmp/copilot-iso-$$
mkdir -p "$ISO" && cd "$ISO"
~/.local/share/gh/copilot/copilot \
  --model gpt-5.4 --no-custom-instructions --disable-builtin-mcps \
  --no-ask-user --silent --output-format json \
  --allow-all-tools --allow-all-paths \
  -p "$(cat "$PROMPT_FILE")" > out.jsonl

# 提取最终 review
python3 -c "
import json
for line in open('out.jsonl'):
    try: o = json.loads(line)
    except: continue
    if o.get('type')=='assistant.message':
        print(o.get('data',{}).get('content','').rstrip())
"

rm -rf "$ISO" "$PROMPT_FILE"
```

### Mode B sub-agent 并行

主线 Claude 在 self-review 节点，同时发起一个 sub-agent（Agent tool / Task tool），交给它如下任务：

> 你是 copilot-second-opinion 的 Mode B sub-agent。任务：用 `~/.claude/skills/copilot-second-opinion/SKILL.md` 里的模板 1 + `gpt-4.1` 模型，对 PR #<N>（issue #<M>）跑一次 second-opinion review。完成后把 copilot 的最终 markdown 输出原样返回，不要总结、不要重写。

主线继续跑自己的 self-review 不等待 sub-agent。两份输出最后并列呈现给 owner，owner 看哪份戳出对方没看到的点。

## 已知坑

- **inline-bundle 是硬约束**：copilot 在 `-p` 模式下不主动用 read 工具。prompt 里写 "read ./pr-bundle.md" 它会幻觉一个文件出来——验证过，曾经把一个 Python ledger PR review 成虚构的 JS `sanitize_input` PR。bundle 必须 inline 进 `-p` 参数。
- **ARG_MAX 上限**：`-p "$(cat prompt.md)"` 走 shell argv，macOS 上 `getconf ARG_MAX` ≈ 256KB，Linux 通常 2MB。超大 PR 会被截断且没有友好报错。v0 不解决，遇到再说。
- **copilot 不在 PATH**：在 zsh 是 alias，bash 子 shell 不继承。脚本/sub-agent 调用必须用绝对路径 `~/.local/share/gh/copilot/copilot`，或在调用前 `PATH=/opt/homebrew/bin:/usr/local/bin:$PATH` 兜底。
- **JSONL 没有 assistant.message 时 == 失败**：如果 quota 耗尽 / rate limited / 只返回 error 事件，解析 JSONL 拿不到 final message。这种情况 **必须当成失败上报**，不能用占位符当成空 review 交付。

## Non-goals

- 不写 bash wrapper / JSONL parser / 工程化封装（v0 lesson from #23：单文件 SKILL.md 已足够）
- 不做 BYOK 多 provider 抽象
- 不解决 ARG_MAX 大 PR 截断
- 不做 Mode A / Mode B 输出冲突的自动 escalation 逻辑
