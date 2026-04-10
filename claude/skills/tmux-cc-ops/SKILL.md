---
name: tmux-cc-ops
description: Primitives for spawning, prompting, capturing, and state-classifying remote/local Claude Code sessions running inside tmux windows. Use when a scheduler/butler needs to operate CC sessions as worker pool — spawn on (machine, session, window), send a brief, poll pane to decide idle / busy / awaiting_permission / done-unread / dead. Not for interactive single-session use.
---

# tmux-cc-ops

tmux + Claude Code 操控 SOP。给调度器（butler 等）做远程/本地 CC executor 池用。本身不提供脚本封装，调用方按 SOP 现写 bash/Python。

## Triggers

- 调度器要 spawn 新 CC executor（local 或远程）
- 已有 tmux window 需要 poll 状态
- `consumer.kind=tmux_window` 的 dispatch 需要落地

## 任意 N pane grid 布局

通用方法：split-window N-1 次 → `select-layout tiled` 自动排列。

```bash
# 2×3 = 6 pane: 1 原始 + 5 次 split → tiled
for i in $(seq 1 5); do tmux split-window -t ${SESSION}:${WINDOW}; done
tmux select-layout -t ${SESSION}:${WINDOW} tiled

# 2×4 = 8 pane: 1 原始 + 7 次 split → tiled
# 3×3 = 9 pane: 1 原始 + 8 次 split → tiled
```

远程：每条 tmux 命令前加 `ssh "$MACHINE"`。tiled 根据终端尺寸自动选行列比，宽屏接近 RxC，窄屏可能变形，可接受。

## Hard Rules

1. tmux server 必须跑在 executor 机器上，不是 butler 本地。远程 executor = `ssh X → tmux new-window → claude`，禁止 `本地 tmux → ssh X → claude`。原因：后者 SSH 断则 CC 收 SIGHUP 退出，executor 寿命跟 butler session 绑死。
2. 状态判定只能基于 sanitized capture-pane 输出（去 ANSI、去 status-line 噪音、保留最后 N 行），不准基于 exit code 或脑补时序。
3. 永远不替用户决策权限弹窗。识别到 `awaiting_permission` → 上报，禁止盲发数字键。必须先 capture-pane 确认含 Yes/No + `esc to cancel` 才放行。
4. 同一 `(machine, session, window)` 不允许并发两个 brief。送 brief 前先 classify 确认是 `idle` 或 `done_unread`。
5. 远程操作走 `ssh X 'tmux ...'`，每条命令独立 ssh exec，不维持长连接。
6. `dead` 必须有积极证据：last non-empty line 命中 shell prompt 正则 + capture 非空 + `prev_state not in (busy, starting)`。证据不足落 `idle`。

## pane_title 快速判定

`tmux display-message -p -t {session}:{window} "#{pane_title}"`

| pane_title 首字符 | 判定 |
|---|---|
| braille (U+2800–U+28FF) | busy |
| ✳ (U+2733) | idle |
| 其他 / 空 | 降级到 capture + classify |

注意：CC 异常退出后 pane_title 可能保留旧值，不能单独依赖，需配合 capture-pane 二次确认。

## Contract：5 个原子操作

target 三元组：`(machine, session, window)`，machine = `"local"` 或 ssh host。

| op | 输入 | 输出 |
|---|---|---|
| spawn_window | target, cwd | target（已起 claude） |
| send_brief | target, brief_text | — |
| capture | target, lines=200 | `{exists, capture_ok, text, stderr}`（text 已 sanitize） |
| classify_state | sanitized text, prev_state | state enum（仅在 `exists && capture_ok` 时调用） |
| kill_window | target | — |

调度方自己持久化 `(target → last_state, last_capture_hash, last_state_at)`。

## State enum

`capture()` 负责 "pane 在不在"，返回 `{exists, capture_ok, text, stderr}`。`exists=False` = `missing`，不进 classify。`classify()` 只在 `exists=True && capture_ok=True` 时调用。

| state | 判据（sanitized tail ~80 行，顺序 match） |
|---|---|
| starting | 出现 `Welcome to Claude Code` / `Loading…` / `Initializing`，且无 TUI box 字符 |
| busy | last5 含 `esc to interrupt`，或 spinner 词（Cogitating/Thinking/Working 等）+ `…` |
| awaiting_permission | tail 同时含 `Do you want to`/`Allow` + 编号选项 `1.` + `esc to cancel` |
| error | tail[-10:] 含 `panic:` / `Traceback` / `^API Error`，且 has_tui=True |
| done_unread | has_tui=True + idle 视觉判据 + `prev_state == busy` |
| idle | TUI 输入框特征（`│ > ` / `╰─` / `? for shortcuts`），或证据不足的 catch-all |
| dead | 积极证据全满足：shell prompt 在末行 + capture 非空 + prev_state 不在 busy/starting |

调度方语义层：`missing`（`exists=False`）、`capture_failed`（`exists=True, capture_ok=False`）不进 classify。

classify 实现要点：
- 输入必须是 sanitized text，接受 `prev_state` 参数
- catch-all 是 `idle` 不是 `dead`；`dead` 必须严格按积极证据返回
- 函数必须 pure，无 side effect

## Worked example: spawn → brief → poll → harvest

```bash
MACHINE=116; SESSION=jack; WINDOW="42-pr-review"
# 1. spawn（在远端开窗，不是本地）
ssh "$MACHINE" "tmux has-session -t $SESSION 2>/dev/null || tmux new-session -d -s $SESSION"
ssh "$MACHINE" "tmux new-window -t ${SESSION}: -n ${WINDOW} && cd /tmp && claude"

# 2. send brief（两步：paste + 单独 Enter；用命名 buffer 避免 -t 歧义）
ssh "$MACHINE" "cat > /tmp/brief-${WINDOW}.txt" < brief.txt
ssh "$MACHINE" "tmux load-buffer -b cc-brief /tmp/brief-${WINDOW}.txt \
  && tmux paste-buffer -b cc-brief -t ${SESSION}:${WINDOW} \
  && tmux delete-buffer -b cc-brief"
sleep 0.3 && ssh "$MACHINE" "tmux send-keys -t ${SESSION}:${WINDOW} Enter"

# 3. poll loop（prev_state 驱动状态机，dead streak 防误报）
PREV=busy; DEAD_STREAK=0
while true; do
  STATE=$(ssh "$MACHINE" "tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -200" | PREV_STATE=$PREV python3 poll.py | jq -r .state)
  case "$STATE" in
    busy)                DEAD_STREAK=0 ;;
    awaiting_permission) report_to_owner; break ;;
    done_unread)         harvest_capture; break ;;
    dead) DEAD_STREAK=$((DEAD_STREAK+1)); [ $DEAD_STREAK -ge 3 ] && { report_dead; break; } ;;
    idle) DEAD_STREAK=0 ;;
  esac
  PREV=$STATE; sleep 30
done
```

## 已知坑

1. `tmux load-buffer -t` 是 target-CLIENT 不是 session — 用命名 buffer：`-b <name>` + `paste-buffer -b <name> -t SESSION:WINDOW`。
2. send-keys 多行 brief — 用 `load-buffer + paste-buffer + 单独 Enter`，不要 `send-keys "$(cat brief.txt)" Enter`（嵌入 \n 断行）。
3. capture-pane 默认只截可见区 — 必须 `-S -200` 取 history，否则 miss spinner 行。
4. ANSI 不剥不要 grep — 先 sanitize 再 classify；spinner 词被 SGR 切段会全 miss。
5. spinner 词表随版本扩 — 兜底判据用 `esc to interrupt`，比词表更稳。
6. status-line 噪音 — sanitize 必须做连续相同行去重，否则 last-N-lines 全是 status-line。
7. CC 启动遇 trust-this-directory prompt — 非 TUI 提问框，classify 落 `idle`（catch-all）。需在调度方单独 grep `trust this directory` 探测，或 spawn 时传 `--dangerously-skip-permissions`。
8. 并行 `claude -p` 上限约 4（CC issue #24990）— executor pool 保守设 4，超出排队。

## ctx% 快速读取

`tmux capture-pane -t {session}:{window} -p -S -1 | grep -oP 'ctx:\K\d+(?=%)'`

抓不到时输出空，调度方按"未知"处理。

## Non-goals

- 不管 dispatch ledger / receipt 格式；不做路由决策；不管 brief 语义内容；不替用户做权限决策（hard rule #3）；不覆盖 trust-this-directory sandbox prompt。
