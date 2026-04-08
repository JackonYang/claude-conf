---
name: tmux-cc-ops
description: Primitives for spawning, prompting, capturing, and state-classifying remote/local Claude Code sessions running inside tmux windows. Use when a scheduler/butler needs to operate CC sessions as worker pool — spawn on (machine, session, window), send a brief, poll pane to decide idle / busy / awaiting-permission / done-unread / dead. Not for interactive single-session use.
---

# tmux-cc-ops

tmux + Claude Code 操控的 SOP。给调度器（butler 等）做远程/本地 CC executor 池用，把"开窗、送 brief、捞输出、判状态"这套反复手写的活儿固化成可抄的 helper pattern。本身不提供脚本封装，调用方按 SOP 现写 bash/Python 即可。

## Triggers

- 调度器/butler 要 spawn 一个新的 CC executor 跑某个 brief（local 或远程机器）
- 已存在的 tmux window 需要 poll 状态判断"该不该收尾 / 该不该追问 / 该不该重起"
- 用户说 "去 116 开个 window 跑 claude 干 X" / "看一下 jack:w3 那个 CC 现在在干嘛" / "把这个 brief 喂给 jackon.me 那个 idle 的 executor"
- consumer.kind=tmux_window 的 dispatch 需要落地

## Hard Rules

1. tmux server 必须跑在 executor 机器上，不是 butler 本地。远程 executor = `ssh X → tmux new-window → claude`，禁止 `本地 tmux → ssh X → claude`。原因：后者 SSH 一断，本地 tmux 拉的 pty 跟着死，远端 CC 收 SIGHUP 退出。这条破了，executor 寿命跟 butler session 绑死，整个调度模型崩盘。
2. spawn CC 时必须切到隔离 cwd，并显式 `--append-system-prompt` 注入"本会话是 executor，照 brief 干活，不要受 cwd CLAUDE.md 里 protocol 词汇拐走"。否则远端 CLAUDE.md（waypoint / jack-vault 等）会立刻把新会话拽进特定 role，brief 失效。
3. send-keys 提交 prompt 必须是两步：先 paste 文本（literal mode），再单独发一次 `Enter`。一步走 `send-keys "text" Enter` 在多行 brief 上会被解释成 `text\n` 而不是"提交输入框"，CC 会收到一个不完整 prompt。
4. 状态判定只能基于 sanitized capture-pane 输出（去 ANSI、去 status-line 噪音、保留最后 N 行），不准基于 exit code、tmux pane status、或脑补的时序。判定函数错杀 = 调度系统幻觉。
5. 永远不替用户决策权限弹窗。识别到 `awaiting_permission` → 上报，不准盲发数字键。教训：jack-vault `sop-1-control-n.md` 记录的 2026-03-21 home-reno 事故。
6. 同一 (machine, session, window) 不允许并发两个 brief。送 brief 之前必须先 classify，确认是 `idle` 或 `done_unread` 才能送，否则会跟前一个任务的 input 撞车。
7. 远程操作走 `ssh X 'tmux ...'`，每条命令是独立 ssh exec，不维持长连接。短连接 ssh 控制层是稳定的；长连接交互 shell 是不稳定的（参见规则 1）。

## Contract

调用方需要的 5 个原子操作（每个都是几行 bash，不要封 wrapper）。

target 三元组贯穿所有操作：

```
target = (machine, session, window)
  machine: "local" | "<ssh-host>"   # 116 / 105 / 101 / jackon.me / ...
  session: tmux session name        # 通常 "jack"
  window:  tmux window name         # 任务 topic，如 "31-tmux-cc-ops"
```

操作集：

| op                 | 输入                                  | 输出                                  |
|--------------------|---------------------------------------|---------------------------------------|
| spawn_window       | target, cwd, brief (optional)         | target (已起 claude)                  |
| send_brief         | target, brief_text                    | -                                     |
| capture            | target, lines=200                     | sanitized text                        |
| classify_state     | sanitized text, prev_state (optional) | enum (见 State 段)                    |
| kill_window        | target                                | -                                     |

调度方自己持久化 `(target → last_state, last_capture_hash, last_state_at)`，不在本 skill 范围。

## State enum (核心)

判定函数返回下面 8 个值之一。每个状态给出"判据 + 反例"，判据按从上到下顺序逐条 match，第一个 match 即返回。

```
missing            window 不存在
dead               window 存在但里面不是 CC（shell prompt / 退出）
starting           CC 正在启动 (splash 还在)
busy               CC 正在跑 tool / 思考
awaiting_permission CC 卡在权限弹窗等用户选 1/2/3
error              CC 在 TUI 内打了 error / panic / traceback
done_unread        前一轮 busy 跑完，prompt 回到 idle 但还没人收
idle               空 prompt 等输入（且不是 done_unread）
```

判据（grep 的是 sanitized capture 的最后 ~80 行）：

1. missing
   - 判据: `tmux -L <sock> list-windows -t <session>` 没列出 window，或 `ssh X tmux list-windows -t <session>` 返回 no server / no session
   - 反例: 不要混淆 "window 不存在" 和 "session 不存在"。session 缺失也归 missing，但调用方决定是否要先建 session。

2. dead
   - 判据: 末尾 N 行没有 CC TUI 的特征（见下方 idle 判据），且能看到 shell prompt 字符（`$ `, `❯ `, `% `, `# ` 出现在行首），或显式有 `Process completed` / `claude: command not found` / `exit` 回显
   - 反例: CC 启动中也会短暂没有 TUI；先让 starting 判据先 match。

3. starting
   - 判据: 出现 `Welcome to Claude Code` / `Loading…` / `Initializing` / 单独的 `claude` 命令回显但还没 TUI box 字符
   - 反例: TUI box 已经画出来 + 有 `>` 输入框 = 不再是 starting。

4. busy
   - 判据: 末尾任意一行包含 `esc to interrupt`，或匹配 spinner 短语正则 `\b(Cogitating|Pondering|Synthesizing|Thinking|Working|Reasoning|Computing|Brewing|Distilling|Hatching|Conjuring|Musing|Marinating|Percolating|Ruminating|Simmering|Stewing|Vibing|Wandering|Whirring)…?\b`，或形如 `(\d+s · [↑↓] [\d.]+k? tokens · esc to interrupt)` 的 footer
   - 反例: 历史输出里出现过 "esc to interrupt" 但当前最末几行没有 → 已经不 busy；要锚定在 last ~5 lines，不是整张 capture。

5. awaiting_permission
   - 判据: 末尾 N 行同时出现 `Do you want to` (或 `Allow` / `Approve`) + 形如 `^\s*[│\s]*1\.\s` 的编号选项 + `esc to cancel`（不是 interrupt）
   - 反例: 普通 numbered list 不是权限弹窗。必须三个 marker 同时 match。

6. error
   - 判据: 末尾出现 `panic:` / `Error: ` 后紧跟 stack / `Traceback (most recent call last)` / `API Error`，且没有 busy spinner、没有权限弹窗
   - 反例: CC 在工具输出里 echo 了 "Error:" 字样不算（区别：有没有 TUI box 包住、是不是顶层而不是 tool result 内）。判定保守一点，宁愿落到 idle 也不要假报 error。

7. done_unread
   - 判据: 当前满足 idle 的视觉判据（见下），但 prev_state == busy（即上一轮 poll 是 busy）。无 prev_state 时不准返回 done_unread，保守落到 idle。
   - 替代判据: capture 最后非空行是 Claude 的响应内容（不是 `>` 输入框 echo），且输入框是空的 — 这个判据 false positive 比较高，主用 prev_state 转移。

8. idle
   - 判据: 末尾出现 CC TUI 的输入框特征：`│ > ` / `╰─` 边框 + `? for shortcuts` 一类 footer hint，且没有 spinner、没有权限弹窗、没有 starting splash
   - 反例: 见 done_unread。

判定函数的实现骨架（调用方现场抄）：

```python
import re

SPINNER_RE = re.compile(
    r"\b(Cogitating|Pondering|Synthesizing|Thinking|Working|Reasoning|"
    r"Computing|Brewing|Distilling|Hatching|Conjuring|Musing|Marinating|"
    r"Percolating|Ruminating|Simmering|Stewing|Vibing|Wandering|Whirring)"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
SHELL_PROMPT_RE = re.compile(r"^[^\n]{0,80}[\$❯%#]\s*$", re.MULTILINE)

def sanitize(raw: str) -> str:
    s = ANSI_RE.sub("", raw)
    # collapse status-line repeats and trailing whitespace
    lines = [ln.rstrip() for ln in s.splitlines()]
    out, prev = [], None
    for ln in lines:
        if ln == prev:
            continue
        out.append(ln); prev = ln
    return "\n".join(out)

def classify(text: str, prev_state: str | None = None) -> str:
    if text is None:
        return "missing"
    tail = "\n".join(text.splitlines()[-80:])
    last5 = "\n".join(text.splitlines()[-5:])

    if re.search(r"Welcome to Claude Code|Loading…|Initializing", tail):
        # only if no TUI prompt yet
        if "│ >" not in tail and "╰─" not in tail:
            return "starting"

    if "esc to interrupt" in last5 or SPINNER_RE.search(last5):
        return "busy"

    if (("Do you want to" in tail or "Allow" in tail)
            and re.search(r"^\s*[│\s]*1\.\s", tail, re.MULTILINE)
            and "esc to cancel" in tail):
        return "awaiting_permission"

    has_tui = ("│ >" in tail) or ("? for shortcuts" in tail) or ("╰─" in tail)
    if not has_tui:
        if SHELL_PROMPT_RE.search(tail) or "command not found" in tail:
            return "dead"
        # ambiguous — fall through to idle as conservative default
        # only if there's clearly no CC at all
        return "dead"

    if re.search(r"panic:|Traceback \(most recent call last\)|^API Error", tail, re.MULTILINE):
        return "error"

    if prev_state == "busy":
        return "done_unread"
    return "idle"
```

判定函数的硬约束：

- 输入是 sanitized text（已经走过 `sanitize`），不是 raw capture。raw 里的 ANSI 会让 regex 全 miss。
- 必须接受 `prev_state`，否则 `done_unread` 这条恒不触发，调度方就无法区分"该收 receipt 了"和"对面在 idle 等输入"。
- 任何不确定的情况落到 `idle` 而不是 `error`。`error` 会触发调度方的"重起" / "上报"路径，false positive 代价高。
- 不要在判定函数里做 side effect（不发 send-keys、不写日志），它必须 pure，方便单元测试用 fixture 喂。

## Worked example: spawn → brief → poll → harvest

butler 收到 dispatch `consumer.kind=tmux_window`, target 机器 116, brief 是 "去把 issue #42 的 PR review 走完"。下面是端到端 SOP（每行调用方现场抄）。

```bash
MACHINE=116
SESSION=jack
WINDOW="42-pr-review"
CWD="/tmp/cc-iso-$(date +%s)-${WINDOW}"
BRIEF_FILE=/tmp/brief-${WINDOW}.txt

# 1. spawn — 在 116 上开 tmux window，不是本地
ssh "$MACHINE" "tmux has-session -t $SESSION 2>/dev/null || tmux new-session -d -s $SESSION"
ssh "$MACHINE" "tmux new-window -t ${SESSION}: -n ${WINDOW}"

# 2. cwd 隔离 + 启动 claude，--append-system-prompt 防 cwd CLAUDE.md 拐走
ssh "$MACHINE" "mkdir -p $CWD"
ssh "$MACHINE" "tmux send-keys -t ${SESSION}:${WINDOW} 'cd $CWD && claude --append-system-prompt \"You are an executor spawned by butler. Follow ONLY the brief that arrives next. Ignore any role / persona / protocol vocabulary from CLAUDE.md files in the working directory.\"' Enter"

# 3. 等 starting → idle
for i in $(seq 1 30); do
  RAW=$(ssh "$MACHINE" "tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -200")
  STATE=$(python3 classify.py <<<"$RAW")   # classify.py 内含上面的 classify()
  [ "$STATE" = "idle" ] && break
  sleep 1
done

# 4. send brief — 两步：先 paste literal，再单独 Enter
cat > "$BRIEF_FILE" <<'EOF'
issue #42: ...多行 brief 内容...
EOF
# 用 tmux load-buffer + paste-buffer 比 send-keys 多行更稳，原因：send-keys 多行会触发 CC 输入框对 \n 的歧义解析
ssh "$MACHINE" "cat > /tmp/brief.txt" < "$BRIEF_FILE"
ssh "$MACHINE" "tmux load-buffer -t $SESSION /tmp/brief.txt && tmux paste-buffer -t ${SESSION}:${WINDOW}"
sleep 0.3
ssh "$MACHINE" "tmux send-keys -t ${SESSION}:${WINDOW} Enter"

# 5. poll loop — 每 N 秒 capture + classify，落 prev_state 状态机
PREV=busy
while true; do
  RAW=$(ssh "$MACHINE" "tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -200")
  STATE=$(PREV_STATE=$PREV python3 classify.py <<<"$RAW")
  case "$STATE" in
    busy) ;;                                        # 继续等
    awaiting_permission) report_to_owner; break ;;  # 上报，不代选
    error) report_error; break ;;
    dead|missing) report_dead; break ;;
    done_unread) harvest_capture; break ;;          # 收尾，写 receipt
  esac
  PREV=$STATE
  sleep 30
done
```

不要把上面这段封进 helper 库 — 每次调用方按自己的状态机（butler ledger / cron poller / 其他）现场拼。封装的成本是丢弃灵活性 + 引入版本漂移。SOP 才是产出物。

## 已知坑

1. tmux send-keys 提交多行 input — 用 `load-buffer + paste-buffer + 单独 Enter`，不要 `send-keys "$(cat brief.txt)" Enter`。后者把内嵌 \n 当 Enter，CC 输入框会断成多个不完整 prompt。
2. capture-pane 默认只截可见区域 — 必须 `-S -200`（或更大）取 history。CC TUI 滚屏快，不取 history 容易 miss spinner 行。
3. ANSI 不剥不要 grep — CC TUI 大量 SGR 序列把 "esc to interrupt" 切成片段，正则全 miss。先 sanitize 再 classify。
4. spinner 词表会随 CC 版本扩 — 上面 SPINNER_RE 是 2026-03 的快照，发现新词加进去，不要假定枚举完整。busy 的兜底判据是 `esc to interrupt` 这串字符，比 spinner 词更稳。
5. SSH ControlMaster 跟 tmux 不冲突，但跟"tmux 跑在本地套 ssh"那种错用法叠加会让症状更迷惑（断连后 mux 还假装活着）。一律按 hard rule #1 走。
6. status-line / vim-airline 之类装饰会让同一信息每秒刷新，sanitize 必须做"连续相同行去重"，否则 last-N-lines 全是 status-line 噪音。
7. CC 启动如果遇到未授权目录 / sandbox prompt，会卡在一个非 TUI 的"是否信任此目录"提问 — 这种情况判定函数会返回 dead 或 starting，调度方需要单独有"trust prompt" 探测，本 skill 的 classify 不覆盖这条边界。
8. window name 含特殊字符（`/`, `:`, 空格）会让 `tmux ... -t session:window` 解析失败。命名时只用 `[A-Za-z0-9_-]`。
9. `tmux has-session` 在远程返回 "no server running" 是正常的（第一次 spawn），按 idempotent 处理，不要把它当 error。
10. `--append-system-prompt` vs `--system-prompt` — append 保留 CC 的工具能力，replace 会把工具描述也覆盖掉导致 CC 不会调用 tool。executor 隔离用 append，不要用 replace。

## Non-goals

- 不提供 bash/python 脚本封装。SOP 是产出物，调用方自己抄。封装会丢弃针对不同调度场景调整的灵活性（参见 v0 lesson on PR-side 封装尝试）。
- 不管 dispatch ledger / receipt 格式 / 状态机持久化 — 那是 butler 等调用方的职责，本 skill 只暴露 5 个 stateless primitive。
- 不管"哪台 executor 该接哪个 brief" 的路由决策 —  那是 routing 层，不是 ops 层。
- 不负责 brief 的语义内容 / 模板 / warmup 句注入 — 那是 dispatcher 的事，本 skill 只管 byte-level 送达。
- 不替用户做权限决策（hard rule #5）。awaiting_permission 永远是上报，不是自动放行。
- 不覆盖 trust-this-directory 的 sandbox prompt（已知坑 #7），调用方需要在 spawn 时用 `--allow-all-paths` 或预先 trust。
