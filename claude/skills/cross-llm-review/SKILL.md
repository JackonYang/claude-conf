---
name: cross-llm-review
description: Second-opinion PR review via GitHub Copilot CLI (gpt-4.1) — runs in an isolated cwd to keep the cross-model verdict free from local CLAUDE.md/AGENTS.md contamination.
---

# cross-llm-review

A different model family looks at the same PR Claude just looked at, and tells
you what Claude probably missed. Uses GitHub Copilot CLI (gpt-4.1, free tier)
under hard isolation so the second opinion is actually a second opinion.

Tracks issue: claude-conf #17.

## When to use

- Architectural / direction calls where Claude's verdict is load-bearing
- PRs touching auth, payments, migrations, anything where a blind spot is expensive
- When Claude's review feels too tidy and you suspect bias from same-model self-checking
- Before merging your own work after Claude reviewed it

Skip for: trivial fixes, doc-only changes, single-line config updates. The
free-tier latency (~40-100s) isn't worth it for low-stakes changes.

## Hard contract — DO NOT relax

These three flags exist because each one fixed a real pollution incident.
Removing any of them silently breaks the "independent second opinion" property:

- `--no-custom-instructions` — blocks AGENTS.md / CLAUDE.md auto-load. Without
  it, copilot picks up whatever instruction file lives in cwd and answers as
  that project's agent rather than as a neutral reviewer.
- `--disable-builtin-mcps` — disables `github-mcp-server`. Without it, copilot
  has cross-repo write access and has been observed making real changes
  (writing to dispatches.yaml in waypoint cwd) just to satisfy a probe prompt.
- Isolated cwd (`/tmp/cross-llm-review/<label>/`) — even with the two flags
  above, cwd determines what tools are anchored where. We always cd into a
  fresh empty dir before invoking copilot.

If you find yourself thinking "but for *this* case I just want to skip
isolation to save 2 seconds" — stop. That defeats the entire point of the
skill. Either run it properly or don't run it.

## Usage

```bash
# Review a PR in another repo:
~/.claude/skills/cross-llm-review/bin/cross-llm-review.sh owner/repo#123

# Review a PR in the current repo:
~/.claude/skills/cross-llm-review/bin/cross-llm-review.sh 123

# Save the review to a file as well as stdout:
~/.claude/skills/cross-llm-review/bin/cross-llm-review.sh owner/repo#123 --out review.md

# Use a stronger (premium-quota) model for high-stakes calls:
~/.claude/skills/cross-llm-review/bin/cross-llm-review.sh owner/repo#123 --model gpt-5.4

# Debug: keep the isolation dir for inspection
~/.claude/skills/cross-llm-review/bin/cross-llm-review.sh owner/repo#123 --keep-iso
```

Output is markdown with sections: Summary / Concerns / Questions for the
author / What looks good. A trailing italic line records premiumRequests, API
duration, and session duration.

## Model selection

- `gpt-4.1` (default) — `premiumRequests=0`, free under Copilot subscription.
  Latency 40-100s for a moderate PR. Use for the common case.
- `gpt-5.x` — premium quota. Reserve for high-stakes architecture calls or
  when gpt-4.1 produced something obviously shallow and you want to escalate.

## How it works

1. `gh pr view` + `gh pr diff` build a markdown bundle (metadata + description + diff).
2. Bundle is **inlined into the prompt** — not passed as a file reference.
   Copilot in `-p` mode does not proactively use read tools and will hallucinate
   a fictional PR if you ask it to "read ./pr-bundle.md". Inlining is the only
   way to guarantee the model sees the real diff. (Discovered the hard way
   during dogfood — see `samples/waypoint-pr-15.md` for the working version.)
3. `copilot` runs in a fresh `/tmp/cross-llm-review/<ts>-<pid>/` cwd with the
   isolation flags above.
4. JSONL output is parsed; the final `assistant.message` content is printed.
5. Isolation dir is removed unless `--keep-iso`.

## Error modes

| Symptom                              | Likely cause                          | Fix                                |
| ------------------------------------ | ------------------------------------- | ---------------------------------- |
| `copilot CLI not found`              | binary not installed / not in PATH    | install via `gh extension` or copilot docs |
| `failed to fetch PR metadata`        | wrong ref, no auth, private repo      | `gh auth status` / verify ref      |
| `copilot exited with status N` + auth msg | OAuth token expired              | `copilot login`                    |
| Output is generic / hallucinated     | bundle didn't reach the prompt        | run with `--keep-iso`, inspect `prompt.md` |
| Output mentions code not in the diff | model fabrication (rare with inline)  | re-run; if persists, escalate model |

## Dogfood evidence

- `samples/waypoint-pr-15.md` — review of `JackonYang/waypoint#15` (ledger as
  shared context). Real lines quoted from CLAUDE.md and dispatch-table.md;
  identifies enforcement gap, unbounded archive read, network-dependency
  fragility. premiumRequests=0, 101s API.

## Non-goals

- Not for CI-failure debugging (different surface — see AICASimPlatform #147)
- Not a BYOK multi-provider abstraction (v0 = copilot only)
- Not a replacement for Claude's review — it's a second opinion, run after

## Deployment

Symlinked into `~/.claude/skills/cross-llm-review/` by `setup.sh` (which
already symlinks the entire `claude/skills/` directory). No setup.sh changes
needed — once this directory is in the repo, `./setup.sh` on each of the 5
machines picks it up.

Per-machine prerequisite: `copilot` CLI installed and authenticated.
