#!/usr/bin/env bash
# cross-llm-review — second-opinion PR review via GitHub Copilot CLI (gpt-4.1).
#
# Why this exists: Claude reviewing Claude's own work shares the same biases.
# This wrapper invokes a different model family (OpenAI via Copilot CLI) on
# the same diff, isolated from any local CLAUDE.md / AGENTS.md context that
# could pollute the second opinion.
#
# Hard isolation contract (do NOT relax):
#   --no-custom-instructions   block AGENTS.md / CLAUDE.md auto-load
#   --disable-builtin-mcps     disable github-mcp-server (cross-repo pollution source)
#   cwd is a fresh /tmp dir    nothing in cwd except the diff bundle we put there
#
# Usage:
#   cross-llm-review.sh <owner/repo#N> [--model gpt-4.1] [--out FILE] [--keep-iso]
#   cross-llm-review.sh <N>            (uses current repo from gh)
#
# Output: markdown review on stdout. Exit 0 on success, non-zero on failure.

set -euo pipefail

# ─── PATH augmentation ──────────────────────────────────
# This script is meant to be self-contained: callable from cron, launchd,
# systemd --user, butler dispatch, or any other context where PATH may not
# include Homebrew or local bin dirs. Augment PATH with the standard
# Homebrew locations on both macOS arch flavors and Linuxbrew, plus the
# usual local bins. We append rather than prepend so the caller's PATH
# still wins for any binary they care to override.
PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.local/bin"
export PATH

PR_REF=""
MODEL="gpt-4.1"
OUT_FILE=""
KEEP_ISO=false

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)    MODEL="$2"; shift 2 ;;
    --out)      OUT_FILE="$2"; shift 2 ;;
    --keep-iso) KEEP_ISO=true; shift ;;
    -h|--help)  usage ;;
    -*)         echo "unknown flag: $1" >&2; exit 2 ;;
    *)          PR_REF="$1"; shift ;;
  esac
done

[[ -z "$PR_REF" ]] && { echo "missing PR ref" >&2; usage; }

# ─── parse PR ref ───────────────────────────────────────
# Forms: owner/repo#N  |  N (current repo)
if [[ "$PR_REF" == *"#"* ]]; then
  REPO="${PR_REF%#*}"
  PR_NUM="${PR_REF#*#}"
  GH_REPO_FLAG=(-R "$REPO")
else
  REPO=""
  PR_NUM="$PR_REF"
  GH_REPO_FLAG=()
fi

if ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "invalid PR number: $PR_NUM" >&2; exit 2
fi

# ─── preflight ──────────────────────────────────────────
# Resolve copilot binary. The interactive shell aliases `copilot` to its real
# path; that alias doesn't propagate to bash subshells, so look for the binary
# directly with a fallback to the known install location.
COPILOT_BIN="$(command -v copilot 2>/dev/null || true)"
if [[ -z "$COPILOT_BIN" || ! -x "$COPILOT_BIN" ]]; then
  for cand in "$HOME/.local/share/gh/copilot/copilot" "/usr/local/bin/copilot"; do
    if [[ -x "$cand" ]]; then COPILOT_BIN="$cand"; break; fi
  done
fi
[[ -x "$COPILOT_BIN" ]] || { echo "copilot CLI not found in PATH or ~/.local/share/gh/copilot/" >&2; exit 3; }

command -v gh      >/dev/null || { echo "gh CLI not installed" >&2; exit 3; }
command -v python3 >/dev/null || { echo "python3 required for JSONL parsing" >&2; exit 3; }

# ─── fetch PR context ───────────────────────────────────
TMP_LABEL="$(date +%s)-$$"
ISO_DIR="/tmp/cross-llm-review/${TMP_LABEL}"
mkdir -p "$ISO_DIR"

cleanup() {
  if ! $KEEP_ISO; then
    rm -rf "$ISO_DIR"
  else
    echo "[cross-llm-review] kept isolation dir: $ISO_DIR" >&2
  fi
}
trap cleanup EXIT

PR_META_JSON="$ISO_DIR/pr-meta.json"
PR_DIFF="$ISO_DIR/pr.diff"
PR_BUNDLE="$ISO_DIR/pr-bundle.md"

# gh stderr is captured to a file and surfaced on failure rather than
# discarded — auth/network/permission errors need to reach the caller, a
# generic "failed to fetch" with no underlying message is undebuggable.
GH_META_ERR="$ISO_DIR/gh-meta.err"
if ! gh pr view "$PR_NUM" "${GH_REPO_FLAG[@]}" \
       --json number,title,body,author,baseRefName,headRefName,state,url,additions,deletions,changedFiles \
       > "$PR_META_JSON" 2> "$GH_META_ERR"; then
  echo "failed to fetch PR metadata for $PR_REF" >&2
  echo "--- gh stderr ---" >&2
  cat "$GH_META_ERR" >&2
  exit 4
fi

GH_DIFF_ERR="$ISO_DIR/gh-diff.err"
if ! gh pr diff "$PR_NUM" "${GH_REPO_FLAG[@]}" > "$PR_DIFF" 2> "$GH_DIFF_ERR"; then
  echo "failed to fetch PR diff for $PR_REF" >&2
  echo "--- gh stderr ---" >&2
  cat "$GH_DIFF_ERR" >&2
  exit 4
fi

# ─── build context bundle ───────────────────────────────
python3 - "$PR_META_JSON" "$PR_DIFF" "$PR_BUNDLE" <<'PY'
import json, sys, pathlib
meta_path, diff_path, out_path = sys.argv[1:]
meta = json.loads(pathlib.Path(meta_path).read_text())
diff = pathlib.Path(diff_path).read_text()

out = []
out.append(f"# PR #{meta['number']}: {meta['title']}")
out.append("")
out.append(f"- URL: {meta['url']}")
out.append(f"- State: {meta['state']}")
out.append(f"- Author: {meta['author']['login']}")
out.append(f"- Branch: {meta['headRefName']} -> {meta['baseRefName']}")
out.append(f"- Files changed: {meta['changedFiles']}  (+{meta['additions']} / -{meta['deletions']})")
out.append("")
out.append("## Description")
out.append("")
out.append((meta.get('body') or '*(no description)*').strip())
out.append("")
out.append("## Diff")
out.append("")
out.append("```diff")
out.append(diff.rstrip())
out.append("```")
pathlib.Path(out_path).write_text("\n".join(out))
PY

# ─── build prompt (bundle is INLINED — copilot in -p mode does not
#     proactively use read tools, so file references get hallucinated). ──
PROMPT_FILE="$ISO_DIR/prompt.md"
{
  cat <<'PROMPT_HEAD'
You are a senior code reviewer providing a SECOND OPINION on a pull request
that another AI reviewer has already looked at. Your job is to be a useful
skeptic — find what the first reviewer might have missed.

Below is the full PR bundle. Read it carefully — do NOT invent code or
filenames that are not present in the diff. If the diff is small or obvious,
say so plainly rather than padding.

Produce a review with these sections:

## Summary
One paragraph on what this PR actually does, in your own words.

## Concerns
For each concern, quote the exact file path and a few diff lines you are
reacting to, then explain the risk. Focus on:
- Correctness bugs (off-by-one, null/nil, race, ordering)
- API / contract changes (breaking callers, silent behavior shifts)
- Security (injection, auth, secrets, untrusted input)
- Edge cases not handled (empty input, large input, error paths)
- Performance traps (N+1, unbounded growth, sync I/O in hot path)
Omit any category where you have nothing real to say.

## Questions for the author
Specific questions whose answers would change your assessment. Be concrete —
no "did you add tests?" filler.

## What looks good
Brief. Only mention things that show real care, not generic praise.

Rules:
- Quote actual lines from the diff below. Do NOT fabricate code.
- If the diff is trivial, say so and stop — do not invent concerns.
- Do not summarize the PR description back to me. Add value beyond it.
- Output markdown only. No preamble, no sign-off.

=== BEGIN PR BUNDLE ===

PROMPT_HEAD
  cat "$PR_BUNDLE"
  cat <<'PROMPT_TAIL'

=== END PR BUNDLE ===

Begin your review now.
PROMPT_TAIL
} > "$PROMPT_FILE"

# ─── invoke copilot in isolated cwd ─────────────────────
RAW_OUT="$ISO_DIR/copilot.jsonl"

# CRITICAL: cd into the isolated dir. Do NOT run copilot from the calling cwd.
(
  cd "$ISO_DIR"
  "$COPILOT_BIN" \
    --model "$MODEL" \
    --no-custom-instructions \
    --disable-builtin-mcps \
    --no-ask-user \
    --silent \
    --output-format json \
    --allow-all-tools \
    --allow-all-paths \
    -p "$(cat ./prompt.md)" \
    > "$RAW_OUT" 2>&1
) || {
  status=$?
  echo "copilot exited with status $status. Last 20 lines of output:" >&2
  tail -20 "$RAW_OUT" >&2
  if grep -q '"error"' "$RAW_OUT" 2>/dev/null; then
    if grep -qi 'auth' "$RAW_OUT"; then
      echo "" >&2
      echo "Hint: copilot auth may be expired. Try: copilot login" >&2
    fi
  fi
  exit 5
}

# ─── parse JSONL → final markdown ───────────────────────
# IMPORTANT: if no assistant.message is present (quota exhausted, rate
# limit, copilot returned only an error event, malformed JSONL, etc.) we
# MUST exit non-zero. A successful exit with a placeholder string would
# let callers (butler, CI, humans) treat a failed review as if it had
# succeeded — the entire point of this skill is the verdict, so a missing
# verdict is a hard failure.
set +e
REVIEW_MD="$(python3 - "$RAW_OUT" <<'PY'
import json, sys
path = sys.argv[1]
last_msg = None
usage = None
errors = []
with open(path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = obj.get("type", "")
        if t == "assistant.message":
            content = obj.get("data", {}).get("content")
            if content:
                last_msg = content
        elif t == "result":
            usage = obj.get("usage", {})
        elif "error" in t.lower() or obj.get("data", {}).get("error"):
            errors.append(obj)

if not last_msg:
    sys.stderr.write("cross-llm-review: copilot returned no assistant message\n")
    if errors:
        sys.stderr.write("--- copilot error events ---\n")
        for e in errors[:5]:
            sys.stderr.write(json.dumps(e)[:500] + "\n")
    else:
        sys.stderr.write("(no error events in JSONL either — likely quota exhausted, rate limited, or malformed output)\n")
    sys.exit(6)

print(last_msg.rstrip())
print()
print("---")
if usage:
    pr = usage.get("premiumRequests", "?")
    api_ms = usage.get("totalApiDurationMs", 0)
    sess_ms = usage.get("sessionDurationMs", 0)
    print(f"_cross-llm-review · model: see invocation · premiumRequests: {pr} · api: {api_ms}ms · session: {sess_ms}ms_")
PY
)"
PARSE_STATUS=$?
set -e

if [[ $PARSE_STATUS -ne 0 ]]; then
  echo "$REVIEW_MD" >&2
  echo "" >&2
  echo "Raw JSONL kept for debugging: re-run with --keep-iso to inspect $ISO_DIR/copilot.jsonl" >&2
  exit "$PARSE_STATUS"
fi

if [[ -n "$OUT_FILE" ]]; then
  printf '%s\n' "$REVIEW_MD" > "$OUT_FILE"
fi
printf '%s\n' "$REVIEW_MD"
