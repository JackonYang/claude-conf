---
name: tmux-cc-ops
description: Primitives for managing tmux windows with Claude Code sessions — spawn, send prompts, capture output, classify state, build grid layouts. Use when you need to run multiple CC sessions, monitor their status, or operate remote executors.
---

# tmux-cc-ops

tmux + Claude Code 操控 SOP。管理本地和远程的 CC session — 开窗、送 prompt、看状态、布局监控面板。

## Triggers

- 需要同时跑多个 CC session（本地或远程）
- 需要 poll 某个 tmux window 里 CC 的状态
- 需要给远程机器开 CC session 跑任务
- 需要搭建多 pane 监控面板

## 任意 N pane grid 布局

通用方法：split-window N-1 次 → `select-layout tiled` 自动排列。

```bash
# 通用：N pane = 1 原始 + (N-1) 次 split → tiled
for i in $(seq 1 $((N-1))); do tmux split-window -t ${SESSION}:${WINDOW}; done
tmux select-layout -t ${SESSION}:${WINDOW} tiled
```

远程：每条 tmux 命令前加 `ssh "$MACHINE"`。tiled 根据终端尺寸自动选行列比，宽屏接近 RxC，窄屏可能变形，可接受。

### 常用场景：2×3 监控 6 个 executor

```bash
# 在 101 上开 6 pane 监控面板，每个 pane 跑一个 CC executor
SESSION=jwork; WINDOW=monitor; MACHINE=101

# 开窗 + split 成 6 pane
ssh $MACHINE "tmux new-window -t ${SESSION}: -n ${WINDOW}"
for i in $(seq 1 5); do ssh $MACHINE "tmux split-window -t ${SESSION}:${WINDOW}"; done
ssh $MACHINE "tmux select-layout -t ${SESSION}:${WINDOW} tiled"

# 每个 pane 里启动一个任务（pane 编号 0-5）
TASKS=("tilert-ci" "debug-54" "debug-49" "pe-audit" "sim-test" "cleanup")
DIRS=("TileRT4AICA" "aica-lab" "aica-lab" "AICASimPlatform" "AICASimPlatform" "aica-lab")
for i in $(seq 0 5); do
  ssh $MACHINE "tmux send-keys -t ${SESSION}:${WINDOW}.${i} \
    'cd ~/workspace-2026/${DIRS[$i]} && claude --dangerously-skip-permissions' Enter"
done

# attach 进去看：ssh 101 → tmux attach -t jwork:monitor
# F11 zoom 单个 pane 操作，再 F11 回 grid
```

快速触发：`ssh 101 "tmux select-window -t jwork:monitor"` 切到监控面板。鼠标点击切 pane，F11 zoom/unzoom。

## Hard Rules

1. 远程 executor 的 tmux 必须跑在远程机器上：`ssh X → tmux new-window → claude`。禁止 `本地 tmux → ssh X → claude`（SSH 断则 CC 收 SIGHUP 退出）。本地操作无此限制。
2. 状态判定只能基于 sanitized capture-pane 输出（去 ANSI、去 status-line 噪音、保留最后 N 行），不准基于 exit code 或脑补时序。
3. 永远不替用户决策权限弹窗。识别到 `awaiting_permission` → 上报，禁止盲发数字键。必须先 capture-pane 确认含 Yes/No + `esc to cancel` 才放行。
4. 同一 window 不允许并发两个 brief。送 brief 前先 classify 确认是 `idle` 或 `done_unread`。
5. 远程操作走 `ssh X 'tmux ...'`，每条命令独立 ssh exec，不维持长连接。
6. `dead` 必须有积极证据：last non-empty line 命中 shell prompt 正则 + capture 非空 + `prev_state not in (busy, starting)`。证据不足落 `idle`。

## pane_title 快速判定

`tmux display-message -p -t {session}:{window} "#{pane_title}"`

| pane_title 首字符 | 判定 |
|---|---|
| braille (U+2800–U+28FF) | busy |
| ✳ (U+2733) | idle — 但须配合 statusline 检查（见下方） |
| hostname / 普通文本 | starting（trust-this-directory 阶段，CC TUI 尚未就绪） |
| 空 / 空白 | CC 已退出（dead），配合 capture-pane 确认 shell 提示符 |
| 其他 | 降级到 capture + classify |

注意：CC 完成任务后 pane_title 可能短暂保留 braille 旧值，过几秒后才更新为 ✳。不能单独依赖 pane_title，需配合 capture-pane + statusline 确认。

### ✳ 时必须检查 statusline — background shell/agent 场景

看到 ✳ (idle) 时，还需检查 statusline 最后两行是否含 `shell` 或 `agents` / `local agent` 关键词：

```bash
# 抓 statusline（最后 2 行含 status bar 内容）
tmux capture-pane -t {session}:{window} -p -S -2 | tail -2
```

| statusline 含什么 | 实际状态 |
|---|---|
| 无 `shell` / `agents` / `local agent` | 真 idle，可以发指令 |
| `· N shell` 或 `· N shells` | background shell 在跑，主 CC idle 但有子进程未完成 |
| `· N local agent` 或 `· N local agents` | background sub-agent 在跑，主 CC idle 但 agent 未完成 |

判定：pane_title=✳ 且 statusline 无 shell/agents → `idle`；有 shell/agents → `background_busy`（不能派新任务）。

## 常用命令速查

```bash
# 开窗 + 启动 CC
tmux new-window -t ${SESSION}: -n ${WINDOW}
tmux send-keys -t ${SESSION}:${WINDOW} "cd ${CWD} && claude --dangerously-skip-permissions" Enter

# 发指令（简单文本直接 send-keys）
tmux send-keys -t ${SESSION}:${WINDOW} '你的指令' Enter

# 发多行 brief（用命名 buffer 避免换行问题）
tmux load-buffer -b brief-${WINDOW} /tmp/brief-${WINDOW}.txt
tmux paste-buffer -b brief-${WINDOW} -t ${SESSION}:${WINDOW}
tmux delete-buffer -b brief-${WINDOW}
sleep 0.3 && tmux send-keys -t ${SESSION}:${WINDOW} Enter

# 看状态
tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -20 | tail -10

# 关窗
tmux kill-window -t ${SESSION}:${WINDOW}
```

远程：命令前加 `ssh $MACHINE "..."`。

## CC 状态判定

`tmux capture-pane -t ${SESSION}:${WINDOW} -p -S -20 | tail -10` 看输出判断：

| 看到什么 | CC 在做什么 |
|---|---|
| spinner 词（Thinking/Working/Cogitating...）+ `esc to interrupt` | 在跑，等着 |
| `Do you want to` + 编号选项 + `esc to cancel` | 等权限确认，上报 owner |
| `❯ ` 提示符，无 spinner，statusline 无 shell/agents | idle，可以发指令 |
| `❯ ` 提示符，但 statusline 含 `· N shell` 或 `· N local agent` | background busy — 主 CC idle 但有子进程/sub-agent 未完成，不能派新任务 |
| `Welcome to Claude Code` / `Loading` | 正在启动 |
| trust-this-directory 选项框（非 CC TUI，pane_title=hostname） | 启动阶段等确认，需发 Enter 或传 `--dangerously-skip-permissions` |
| `panic:` / `Traceback` / `API Error` | 出错了 |
| shell `$` / `%` 提示符，无 CC TUI，pane_title 为空 | CC 已退出 |

也可以用 pane_title 快速预判：`tmux display-message -p -t ${SESSION}:${WINDOW} "#{pane_title}"` — 首字符是 braille 旋转动画 = busy，✳ = idle（但需配合 statusline 排除 background busy，见上方"✳ 时必须检查 statusline"），空 = dead。注意 CC crash 后 pane_title 可能保留旧值，需配合 capture-pane 确认。

关键原则：不确定时当 idle 处理，不要猜 dead。dead 需要看到 shell 提示符 + pane_title 为空等积极证据。

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

- 不做路由决策（哪个任务发给哪台机器）；不管 prompt 怎么写；不替用户做权限决策（hard rule #3）；不覆盖 trust-this-directory sandbox prompt。
