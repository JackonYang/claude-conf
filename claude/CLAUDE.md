# Global CLAUDE.md

Personal rules for Claude Code. Symlinked to ~/.claude/CLAUDE.md.
This file is machine-independent — no paths, env vars, or local tooling here.

## Communication

- Default language: 中文 (Chinese). Switch to English only when:
  - Writing code, commit messages, PR titles/descriptions, or technical docs
  - The user explicitly writes in English
  - Naming variables, functions, files
- Be concise. Lead with the answer, skip the preamble.
- No trailing summaries — I can read the diff.
- No emoji unless explicitly requested.
- When unsure, ask one focused question instead of guessing.

## Verification-First Principle

Always verify before claiming. This is the single most important rule.

- Read the file before editing. Grep before asserting something exists.
- Run tests/linters after code changes — don't assume green.
- If a memory or assumption references a file/function/flag, confirm it still exists before recommending.
- When debugging: read the actual error, check assumptions, try a focused fix. Don't retry blindly.
- Prefer `git diff` / `git status` to confirm state over mental tracking.

## Coding Conventions

### General

- Write minimal, correct code. No speculative abstractions.
- Fix what's asked. Don't refactor neighbors, add docstrings to untouched code, or "improve" beyond scope.
- Three similar lines > a premature helper function.
- Delete dead code completely — no `# removed`, no `_unused` renames.
- No backwards-compat shims unless explicitly requested.

### Error Handling

- Validate at system boundaries only (user input, external APIs).
- Trust internal code and framework guarantees.
- No defensive coding against impossible states.

### Testing

- Test behavior, not implementation.
- Prefer integration tests over unit tests with heavy mocking.
- Use real dependencies (DB, filesystem) when feasible.

### Git & PRs

- Commit messages: imperative mood, explain "why" not "what".
- One logical change per commit.
- PR descriptions: summary bullets + test plan.
- Never force-push, amend published commits, or skip hooks without explicit approval.
- Never auto-commit — wait for explicit instruction.

### Python (primary language)

- Python 3.10+ syntax. Use `match`, `|` for union types, modern stdlib.
- Type hints on public APIs. Skip on obvious internals.
- `pathlib` over `os.path`. f-strings over `.format()`.
- Prefer standard library. Add dependencies only when justified.
- Follow existing project style — if the repo uses `black`, match it.

### JavaScript / TypeScript

- TypeScript strict mode when available.
- Prefer `const` over `let`. Never `var`.
- Use native APIs (`fetch`, `URL`, `crypto`) over npm packages when possible.
- ESM imports. No CommonJS in new code unless the project requires it.

## Forbidden Patterns

These are hard rules. Never do these without explicit user override.

- ❌ `git push --force` or `git reset --hard` without confirmation
- ❌ Committing `.env`, credentials, secrets, or API keys
- ❌ `git add -A` / `git add .` — always stage specific files
- ❌ Adding `sleep` loops or polling without justification
- ❌ Creating README.md or documentation files unless explicitly asked
- ❌ Mocking databases in integration tests
- ❌ `--no-verify` or `--no-gpg-sign` on git commands
- ❌ Running destructive commands (`rm -rf`, `DROP TABLE`, `kill -9`) without confirmation
- ❌ Uploading code to third-party paste/render services without asking
- ❌ Using `cat`, `grep`, `sed` in Bash when dedicated tools (Read, Grep, Edit) exist

## Task Approach

- Start simple. Try the obvious approach first.
- When stuck, diagnose root cause before switching strategy.
- Break complex work into small, verifiable steps.
- Use parallel tool calls when inputs are independent.
- For broad codebase exploration, use Agent(Explore). For targeted lookups, use Grep/Glob directly.

## What Not to Remember

If I ask to "remember" something, save only what's non-obvious and durable:
- Don't save code patterns derivable from the codebase.
- Don't save git history — `git log` is authoritative.
- Don't save ephemeral task state.
- Convert relative dates to absolute dates.
