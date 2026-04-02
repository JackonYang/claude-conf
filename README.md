# claude-conf
Claude Code configuration management across machines

## Long-term refinement notes

模型不读这里。Jack 常看常新，在最有价值的时候落实。

- agent teams 拆分能力：当前模型倾向串行做完，不主动拆 teams。"什么时候该拆"是通用短板，适合在 starting-work skill 里加拆分评估 heuristic；"怎么拆"按项目走，写在项目级 CLAUDE.md 里。
- 通知机制落地：#9 — 飞书推送封装为 agent 可调用的形式，补回 CLAUDE.md 自动化边界里的通知规则。
