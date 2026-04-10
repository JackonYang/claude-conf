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
8. `dead` 必须有积极证据，单纯 not-has-tui 不构成 dead 判据。积极证据 = last non-empty line 命中 shell prompt 正则 + capture 非空 + 不是刚从 `busy` / `starting` 跳出来（这些状态有几帧 TUI 缺失是正常的）。证据不足时 catch-all 落 `idle`，让调度方靠多次 poll 的 stability 计数把"持续 idle 但其实是 trust prompt 或 dead pane"的边界 case 收敛掉。误报 dead 会触发"重起 executor"路径，撞上正在启动的 CC、trust-this-directory prompt（已知坑 #7）、或 capture race，直接破坏 owner 介入窗口。
9. `missing` 是 `capture` primitive 的结构化返回字段，不是 `classify` 的返回值。window/session 不存在 → `capture(...)` 返回 `exists=False`，调用方据此决定是否要 spawn。`classify` 只在 `exists=True && capture_ok=True` 时被调用，只负责"已经在那里、能截到的 pane"的视觉判定。混淆这两个责任会让 classify 用空字符串或 stderr 当输入猜状态，必然误判。

## Contract

调用方需要的 5 个原子操作（每个都是几行 bash，不要封 wrapper）。

target 三元组贯穿所有操作：

```
target = (machine, session, window)
  machine: "local" | "<ssh-host>"   # 116 / 105 / 101 / jackon.me / ...
  session: tmux session name        # 通常 "jack"
  window:  tmux window name         # 任务 topic，如 "33-tmux-cc-ops"
```

操作集：

| op                 | 输入                                  | 输出                                                              |
|--------------------|---------------------------------------|-------------------------------------------------------------------|
| spawn_window       | target, cwd, brief (optional)         | target (已起 claude)                                              |
| send_brief         | target, brief_text                    | -                                                                 |
| capture            | target, lines=200                     | dict `{exists, capture_ok, text, stderr}`（text 已 sanitize）     |
| classify_state     | sanitized text, prev_state (optional) | enum (见 State 段；只在 `exists && capture_ok` 时调用)            |
| kill_window        | target                                | -                                                                 |

调度方自己持久化 `(target → last_state, last_capture_hash, last_state_at)`，不在本 skill 范围。

## State enum (核心)

责任分两层：

- `capture(target)` 负责 "pane 在不在 / 能不能截"，返回 `{exists, capture_ok, text, stderr}`。`exists=False` 即调度方语义里的 `missing`，不需要 classify 参与。
- `classify(sanitized_text, prev_state)` 只在 `exists=True && capture_ok=True` 时被调用，对一个"已经在那里、能截到"的 pane 做视觉判定，返回下面 7 个值之一。判据按从上到下顺序逐条 match，第一个 match 即返回。

```
starting           CC 正在启动 (splash 还在)
busy               CC 正在跑 tool / 思考
awaiting_permission CC 卡在权限弹窗等用户选 1/2/3
error              CC 在 TUI 内打了 error / panic / traceback
done_unread        前一轮 busy 跑完，prompt 回到 idle 但还没人收
idle               空 prompt 等输入（且不是 done_unread）；也是所有"证据不足"情况的 catch-all
dead               window 存在但里面不是 CC — 必须有积极证据（见下）
```

调度方语义层另有两个状态，由 `capture` 直接产出，不进 `classify`：

```
missing            capture(...).exists == False (window/session 不存在)
capture_failed     capture(...).exists == True && capture_ok == False
                   (tmux 报错但 window 还在，例如 socket race / pane 太窄 / 权限问题)
```

判据（grep 的是 sanitized capture 的最后 ~80 行）。`missing` / `capture_failed` 不在 classify 内 — 见上面责任划分。判据顺序与 classifier 实现一致：

1. starting
   - 判据: 出现 `Welcome to Claude Code` / `Loading…` / `Initializing` / 单独的 `claude` 命令回显但还没 TUI box 字符
   - 反例: TUI box 已经画出来 + 有 `>` 输入框 = 不再是 starting。

2. busy
   - 判据: 末尾任意一行包含 `esc to interrupt`，或匹配 spinner 短语正则 `\b(Cogitating|Pondering|Synthesizing|Thinking|Working|Reasoning|Computing|Brewing|Distilling|Hatching|Conjuring|Musing|Marinating|Percolating|Ruminating|Simmering|Stewing|Vibing|Wandering|Whirring)…?\b`，或形如 `(\d+s · [↑↓] [\d.]+k? tokens · esc to interrupt)` 的 footer
   - 反例: 历史输出里出现过 "esc to interrupt" 但当前最末几行没有 → 已经不 busy；要锚定在 last ~5 lines，不是整张 capture。

3. awaiting_permission
   - 判据: 末尾 N 行同时出现 `Do you want to` (或 `Allow` / `Approve`) + 形如 `^\s*[│\s]*1\.\s` 的编号选项 + `esc to cancel`（不是 interrupt）
   - 反例: 普通 numbered list 不是权限弹窗。必须三个 marker 同时 match。

4. error
   - 判据: tail 出现 `panic:` / `Traceback (most recent call last)` / `^API Error`，且 has_tui 为真（被 TUI box 包住），且没有 busy spinner、没有权限弹窗
   - 反例: CC 在工具输出里 echo 了 "Error:" 字样不算。判定保守一点，宁愿落到 idle 也不要假报 error。
   - 注意: 只在 `has_tui == True` 时考虑，否则归到 dead/idle 判定路径。

5. done_unread
   - 判据: has_tui 为真 + 当前满足 idle 的视觉判据，但 `prev_state == busy`（即上一轮 poll 是 busy）。无 prev_state 时不准返回 done_unread，保守落到 idle。
   - 替代判据: capture 最后非空行是 Claude 的响应内容（不是 `>` 输入框 echo），且输入框是空的 — 这个判据 false positive 比较高，主用 prev_state 转移。

6. idle
   - 判据: 末尾出现 CC TUI 的输入框特征：`│ > ` / `╰─` 边框 + `? for shortcuts` 一类 footer hint，且没有 spinner、没有权限弹窗、没有 starting splash
   - catch-all 角色: 任何"证据不足"的情况（trust-prompt、capture race、空帧、非 TUI 但又不满足 dead 的积极证据）都落 idle。`idle` 是 classify 的安全 default，调度方应当靠多次 poll 的 stability 计数把"持续 idle 但其实是 trust prompt 或 dead pane"的边界 case 收敛掉。

7. dead — 严格要求积极证据，全部满足才返回（hard rule #8）：
   - last non-empty line 命中 shell prompt 正则（`$` / `❯` / `%` / `#` 在行尾），或 `command not found` / `Process completed` 字样出现在 tail
   - sanitized text 非空且体量 > 一个最小阈值（避免一帧空白 capture 触发）
   - tail 内任何一行都没有 CC TUI 特征（`│ >` / `╰─` / `? for shortcuts`）
   - `prev_state not in (busy, starting)` — 这两个状态有几帧 TUI 缺失是正常的，不算 dead
   - 反例: trust-this-directory prompt（已知坑 #7）— 非 TUI 提问框，没有 shell prompt 字符，会落 idle 而不是 dead；调度方需要靠单独的 trust-prompt 探测或 stability 计数兜底
   - 反例: capture race / 短暂空屏 / CC 启动瞬态 — 都不满足"shell prompt at end + 非空 + prev_state 干净"，会落 idle

判定函数的实现骨架（调用方现场抄）：

```python
import re

SPINNER_RE = re.compile(
    r"\b(Cogitating|Pondering|Synthesizing|Thinking|Working|Reasoning|"
    r"Computing|Brewing|Distilling|Hatching|Conjuring|Musing|Marinating|"
    r"Percolating|Ruminating|Simmering|Stewing|Vibing|Wandering|Whirring)"
)
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
# anchored at end of a *single line*: optional cwd + one of $ ❯ % # at the very end
SHELL_PROMPT_RE = re.compile(r"[\$❯%#]\s*$")
DEAD_MIN_BYTES = 40   # below this, treat capture as a transient empty frame

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

def capture(target, lines: int = 200) -> dict:
    """tmux capture-pane wrapper.

    Returns {exists, capture_ok, text, stderr}:
      exists=False        -> window/session not found ("missing" at scheduler layer)
      exists=True, capture_ok=False -> tmux errored on a present pane (race / perms)
      exists=True, capture_ok=True  -> text is sanitized, ready to feed classify()

    Caller adapts run() for local vs ssh; key point is that classify() never
    has to guess between "no pane" and "blank pane".
    """
    proc = run([
        "tmux", "capture-pane",
        "-t", f"{target.session}:{target.window}",
        "-p", "-S", f"-{lines}",
    ])
    if proc.returncode == 0:
        return {"exists": True, "capture_ok": True,
                "text": sanitize(proc.stdout), "stderr": ""}
    err = proc.stderr or ""
    if ("can't find window" in err or "no session" in err
            or "no server running" in err):
        return {"exists": False, "capture_ok": False, "text": "", "stderr": err}
    return {"exists": True, "capture_ok": False, "text": "", "stderr": err}

def classify(sanitized_text: str, prev_state: str | None = None) -> str:
    """Visual classification of a present, captured pane.

    Precondition (caller's responsibility): the corresponding capture() returned
    exists=True AND capture_ok=True. Never call classify() with "" / None as a
    way to ask "is the window there?" — that's capture()'s job.

    Returns one of:
        starting | busy | awaiting_permission | error | done_unread | idle | dead
    Never returns "missing".

    Catch-all is idle, not dead. dead requires positive evidence (hard rule #8).
    When in doubt, return idle and let the scheduler's stability counter decide.
    """
    text = sanitized_text or ""
    lines = text.splitlines()
    tail = "\n".join(lines[-80:])
    last5 = "\n".join(lines[-5:])
    last_nonempty = next((ln for ln in reversed(lines) if ln.strip()), "")

    if re.search(r"Welcome to Claude Code|Loading…|Initializing", tail):
        if "│ >" not in tail and "╰─" not in tail:
            return "starting"

    if "esc to interrupt" in last5 or SPINNER_RE.search(last5):
        return "busy"

    if (("Do you want to" in tail or "Allow" in tail)
            and re.search(r"^\s*[│\s]*1\.\s", tail, re.MULTILINE)
            and "esc to cancel" in tail):
        return "awaiting_permission"

    has_tui = ("│ >" in tail) or ("? for shortcuts" in tail) or ("╰─" in tail)

    if has_tui:
        if re.search(r"panic:|Traceback \(most recent call last\)|^API Error",
                     tail, re.MULTILINE):
            return "error"
        if prev_state == "busy":
            return "done_unread"
        return "idle"

    # No TUI in tail. dead requires POSITIVE evidence (hard rule #8):
    #   1) shell-prompt char at end of last non-empty line, OR
    #      explicit "command not found" / "Process completed" in tail
    #   2) capture is non-trivial (guards against transient blank frames)
    #   3) we are not coming out of busy/starting (those legitimately drop TUI
    #      for a frame or two — letting that look "dead" is the original bug)
    dead_signal = (
        SHELL_PROMPT_RE.search(last_nonempty)
        or "command not found" in tail
        or "Process completed" in tail
    )
    if (dead_signal
            and len(text.strip()) >= DEAD_MIN_BYTES
            and prev_state not in ("busy", "starting")):
        return "dead"

    # Ambiguous: trust-this-directory prompt, capture race, transient blank,
    # post-busy frame. Stay idle and let the scheduler's stability counter
    # decide whether the pane is really stuck.
    # NEVER catch-all to dead — dead must be earned with positive evidence.
    return "idle"
```

判定函数的硬约束：

- 输入是 sanitized text（已经走过 `sanitize`），不是 raw capture。raw 里的 ANSI 会让 regex 全 miss。
- 必须接受 `prev_state`，否则 `done_unread` / `dead` 的"prev_state 干净"判据全部失效，调度方既分不清"该收 receipt 了"和"对面在 idle 等输入"，也会在 busy → idle 的过渡帧上误报 dead。
- 任何不确定的情况落到 `idle` 而不是 `error` 或 `dead`。两者都会触发调度方的"重起" / "上报"路径，false positive 代价高，尤其是 dead → 重启会撞上 trust-prompt / 启动中的 CC。
- `dead` 必须严格按上面的三条积极证据返回 — 不要为了"看起来像 shell" 就放行（呼应 hard rule #8）。
- `missing` 不在 classify 输出集 — 调用方先调 `capture()`，根据 `exists` 字段判 missing；classify 的输入永远来自 `capture_ok=True` 的分支。
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

# 3. 等 starting → idle (poll 30s 超时)
for i in $(seq 1 30); do
  OUT=$(ssh "$MACHINE" "tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -200" \
        | python3 poll.py)
  STATE=$(echo "$OUT" | jq -r .state)
  EXISTS=$(echo "$OUT" | jq -r .exists)
  [ "$EXISTS" = "false" ] && { report_missing; exit 1; }
  [ "$STATE" = "idle" ] && break
  sleep 1
done

# 4. send brief — 两步：先用命名 buffer paste，再单独 Enter
#
#    重点: tmux load-buffer 的 -t 是 target-CLIENT（man tmux），不是 session/window。
#    不要写 `tmux load-buffer -t $SESSION file`，那是把 session 名当 client 名传，
#    行为不可靠（≥ 3.x 上要么 silently 落到默认 client，要么直接报错）。
#    正确做法：用命名 buffer（-b <name>），完全绕开 -t 歧义，也避免污染默认 buffer 栈。
cat > "$BRIEF_FILE" <<'EOF'
issue #42: ...多行 brief 内容...
EOF
ssh "$MACHINE" "cat > /tmp/brief.txt" < "$BRIEF_FILE"
ssh "$MACHINE" "tmux load-buffer -b cc-brief /tmp/brief.txt \
                && tmux paste-buffer -b cc-brief -t ${SESSION}:${WINDOW} \
                && tmux delete-buffer -b cc-brief"
sleep 0.3
ssh "$MACHINE" "tmux send-keys -t ${SESSION}:${WINDOW} Enter"

# 5. poll loop — 每 N 秒 capture + classify，落 prev_state 状态机。
#    capture() 把 missing / capture_failed 直接出在 JSON 里，classify() 只见
#    "存在且能截到"的 pane，所以 case 里 missing / capture_failed 走独立分支。
#    DEAD_STREAK 让调度方对 dead 做 stability 收敛 — 单次 dead 不动作，
#    避免误报触发重启撞上 trust-prompt / 启动中的 CC（hard rule #8）。
PREV=busy
DEAD_STREAK=0
while true; do
  OUT=$(ssh "$MACHINE" "tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -200" \
        | PREV_STATE=$PREV python3 poll.py)
  EXISTS=$(echo "$OUT" | jq -r .exists)
  CAPTURE_OK=$(echo "$OUT" | jq -r .capture_ok)
  STATE=$(echo "$OUT" | jq -r .state)

  if [ "$EXISTS" = "false" ]; then report_missing; break; fi
  if [ "$CAPTURE_OK" = "false" ]; then sleep 5; continue; fi   # tmux race, retry

  case "$STATE" in
    busy)                DEAD_STREAK=0 ;;                              # 继续等
    awaiting_permission) report_to_owner; break ;;                    # 上报，不代选
    error)               report_error; break ;;
    dead)
      DEAD_STREAK=$((DEAD_STREAK + 1))
      [ "$DEAD_STREAK" -ge 3 ] && { report_dead; break; }             # 3 连 dead 才动手
      ;;
    done_unread)         harvest_capture; break ;;                    # 收尾，写 receipt
    idle)                DEAD_STREAK=0 ;;                             # idle 是 catch-all，重置计数
  esac
  PREV=$STATE
  sleep 30
done
```

不要把上面这段封进 helper 库 — 每次调用方按自己的状态机（butler ledger / cron poller / 其他）现场拼。封装的成本是丢弃灵活性 + 引入版本漂移。SOP 才是产出物。

## 已知坑

1. tmux load-buffer -t 是 target-CLIENT，不是 session/window — 这是最常犯的错。`tmux load-buffer -t jack file` 是把 "jack" 当 client 名传，不是 session 名。正确用法：省掉 `-t`（默认 buffer），或用命名 buffer：`tmux load-buffer -b cc-brief file && tmux paste-buffer -b cc-brief -t SESSION:WINDOW && tmux delete-buffer -b cc-brief`。命名 buffer 更好，避免污染默认 buffer 栈。
2. tmux send-keys 提交多行 input — 用 `load-buffer + paste-buffer + 单独 Enter`，不要 `send-keys "$(cat brief.txt)" Enter`。后者把内嵌 \n 当 Enter，CC 输入框会断成多个不完整 prompt。
3. capture-pane 默认只截可见区域 — 必须 `-S -200`（或更大）取 history。CC TUI 滚屏快，不取 history 容易 miss spinner 行。
4. ANSI 不剥不要 grep — CC TUI 大量 SGR 序列把 "esc to interrupt" 切成片段，正则全 miss。先 sanitize 再 classify。
5. spinner 词表会随 CC 版本扩 — 上面 SPINNER_RE 是 2026-03 的快照，发现新词加进去，不要假定枚举完整。busy 的兜底判据是 `esc to interrupt` 这串字符，比 spinner 词更稳。
6. SSH ControlMaster 跟 tmux 不冲突，但跟"tmux 跑在本地套 ssh"那种错用法叠加会让症状更迷惑（断连后 mux 还假装活着）。一律按 hard rule #1 走。
7. status-line / vim-airline 之类装饰会让同一信息每秒刷新，sanitize 必须做"连续相同行去重"，否则 last-N-lines 全是 status-line 噪音。
8. CC 启动如果遇到未授权目录 / sandbox prompt，会卡在一个非 TUI 的"是否信任此目录"提问 — 这种情况判定函数会落 `idle`（catch-all，因为不满足 dead 的积极证据），调度方需要单独有"trust prompt" 探测（grep `Do you trust the files` / `trust this directory` 之类），本 skill 的 classify 不覆盖这条边界。
9. window name 含特殊字符（`/`, `:`, 空格）会让 `tmux ... -t session:window` 解析失败。命名时只用 `[A-Za-z0-9_-]`。
10. `tmux has-session` 在远程返回 "no server running" 是正常的（第一次 spawn），按 idempotent 处理，不要把它当 error。
11. `--append-system-prompt` vs `--system-prompt` — append 保留 CC 的工具能力，replace 会把工具描述也覆盖掉导致 CC 不会调用 tool。executor 隔离用 append，不要用 replace。

## Non-goals

- 不提供 bash/python 脚本封装。SOP 是产出物，调用方自己抄。封装会丢弃针对不同调度场景调整的灵活性。
- 不管 dispatch ledger / receipt 格式 / 状态机持久化 — 那是 butler 等调用方的职责，本 skill 只暴露 5 个 stateless primitive。
- 不管"哪台 executor 该接哪个 brief" 的路由决策 — 那是 routing 层，不是 ops 层。
- 不负责 brief 的语义内容 / 模板 / warmup 句注入 — 那是 dispatcher 的事，本 skill 只管 byte-level 送达。
- 不替用户做权限决策（hard rule #5）。awaiting_permission 永远是上报，不是自动放行。
- 不覆盖 trust-this-directory 的 sandbox prompt（已知坑 #8），调用方需要在 spawn 时用 `--allow-all-paths` 或预先 trust。
