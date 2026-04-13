---
name: shepherd
description: Executor SOP for pipeline shepherd — autonomous poll-diagnose-fix-push loop until MR/PR pipeline is green or blocked.
---

# Pipeline Shepherd — Executor SOP

Autonomous fix loop for MR/PR pipelines. Supports both GitLab (glab) and GitHub (gh). This is the executor layer — it runs inside a Claude session on the target machine. Workflow contract and routing logic are defined in waypoint, not here.

## Hard Rules

1. Never force-push. Always create new commits.
2. Never modify test assertions to make tests pass — fix the code under test.
3. Never skip or disable failing tests.
4. Same failure signature + same fix approach 3 consecutive times → stop, emit BLOCKED receipt.
5. No hard cap on total iterations. Keep going as long as progress is being made.
6. Every fix commit must reference the pipeline/check and job that failed.

## Triggers

- "/shepherd", "跑到全绿", "pipeline 全过", "盯着 pipeline"
- "/shepherd !N" or "/shepherd #N" — shepherd a specific MR/PR by number

## Pre-checks

- On a feature branch with an open MR/PR (or number provided)
- Working tree clean, branch pushed

## SOP

### Step 0. Detect context and platform

```bash
BRANCH=$(git branch --show-current)
REMOTE_URL=$(git remote get-url origin)
```

Detect platform from remote URL:
- `github.com` in URL → GitHub, use `gh`
- `gitlab` in URL or hostname matches known GitLab instance → GitLab, use `glab api`
- ambiguous → check which CLI is authenticated (`gh auth status` / `glab auth status`)

#### GitLab

```bash
# Strip optional .git suffix, extract project path from SSH or HTTPS remote
PROJECT_PATH=$(echo "$REMOTE_URL" | sed -E 's|\.git$||' | sed -E 's|.*[:/](.*)|\1|')
PROJECT_ENC=$(echo "$PROJECT_PATH" | sed 's|/|%2F|g')

# Find MR and extract iid
MR_IID=$(glab api "projects/$PROJECT_ENC/merge_requests?source_branch=$BRANCH&state=opened&per_page=1" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['iid'] if d else '')")
```

#### GitHub

```bash
# Strip optional .git suffix, extract owner/repo
REPO=$(echo "$REMOTE_URL" | sed -E 's|\.git$||' | sed -E 's|.*[:/](.*)|\1|')

# Find PR and extract number
PR_NUMBER=$(gh pr view "$BRANCH" --json number --jq '.number')
```

No MR/PR (empty MR_IID or PR_NUMBER) → stop.

### Step 1. Get latest pipeline/check status

#### GitLab
```bash
PIPELINE_ID=$(glab api "projects/$PROJECT_ENC/merge_requests/$MR_IID/pipelines?per_page=1" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['id'] if d else '')")
```

#### GitHub
```bash
RUN_ID=$(gh run list --branch "$BRANCH" --limit 1 --json databaseId --jq '.[0].databaseId')
```

No pipeline/checks (empty PIPELINE_ID or RUN_ID) → push to trigger, wait 15s, retry.

### Step 2. Poll until complete

Poll every 90 seconds:

#### GitLab
```bash
glab api "projects/$PROJECT_ENC/pipelines/$PIPELINE_ID"
```

#### GitHub
```bash
gh run view $RUN_ID --json status,conclusion
```

Output each cycle:
```
[shepherd] pipeline #17602 running... (3m elapsed)
[shepherd] run 12345678 running... (3m elapsed)
```

### Step 3. Evaluate

- success/passed → Step 6
- canceled/cancelled → stop
- failed/failure → Step 4

### Step 4. Diagnose

#### GitLab
```bash
glab api "projects/$PROJECT_ENC/pipelines/$PIPELINE_ID/jobs?per_page=100"
# For each failed job:
glab api "projects/$PROJECT_ENC/jobs/$JOB_ID/trace"
```

#### GitHub
```bash
# List failed jobs
gh run view $RUN_ID --json jobs --jq '.jobs[] | select(.conclusion == "failure") | {name,conclusion}'
# Read job log
gh run view $RUN_ID --log-failed
```

Classify and act:
- Build error → fix code
- Test failure → fix code under test
- Environment error (bringup, SSH, QEMU) → diagnose root cause, attempt fix (check logs, config, scripts), retry
- Flaky (known patterns) → retry once
- Infrastructure error that executor genuinely cannot act on (runner offline, disk hardware fault, network outage) → emit BLOCKED receipt

Track failure signature: `job_name + error_category + key_message`.

### Step 5. Fix and push

a. Read relevant source, fix code.
b. Commit:
```
fix: <what was wrong> (#<issue>)

Pipeline/Run #<id> job <job_name> failed:
<1-line error summary>
```
c. `git push`
d. Wait 15s. Go to Step 1.

### Step 6. Emit GREEN receipt

Write to `~/.shepherd/receipts/<pipeline_id>.yaml` (pipeline_id is GitLab-
native, globally unique, and already known from Step 1):

```yaml
receipt_id: r-<uuid-short>
pipeline_id: <id>
status: green
updated_at: <timestamp>
payload:
  mr_iid: <N>
  mr_url: <MR/PR web URL>
  pipeline_url: <url>
  fix_rounds: <N>
  commits:
    - hash: <sha>
      message: <summary>
  duration: <total time>
```

### Step 7. Emit BLOCKED receipt

Write to `~/.shepherd/receipts/<pipeline_id>.yaml`:

```yaml
receipt_id: r-<uuid-short>
pipeline_id: <id>
status: blocked
updated_at: <timestamp>
payload:
  mr_iid: <N>
  mr_url: <MR/PR web URL>
  pipeline_url: <url>
  failed_job: <name>
  failure_type: <build | test | environment | infrastructure | flaky_repeated>
  error: <message>
  attempts_total: <N>
  attempts_same_error: <M>
  reason: <why>
  suggested_next_action: <what owner should do>
```

### Step 8. Notify dispatcher (if auto-spawned)

If `$CI_SHEPHERD_WINDOW` is set in the environment, this executor was
spawned by ci-shepherd and the dispatcher is waiting for a callback. After
writing the receipt (Step 6 or 7), send one line back via tmux.

**Do not send blindly** — per skill:tmux-cc-ops hard rule 4, confirm the
dispatcher window is idle (pane_title = ✳) before sending. If busy, wait
and retry up to 3 × 5s. If still busy after retries, give up the callback
— the receipt on disk remains authoritative and the dispatcher can
reconcile from it on next wake.

```bash
if [[ -n "${CI_SHEPHERD_WINDOW:-}" ]]; then
    for attempt in 1 2 3; do
        title=$(tmux display-message -p -t "$CI_SHEPHERD_WINDOW" "#{pane_title}")
        if [[ "$title" == ✳* ]]; then
            tmux send-keys -t "$CI_SHEPHERD_WINDOW" \
              "executor done: pipeline_id=${PIPELINE_ID} status=${STATUS} receipt=${RECEIPT_PATH}" \
              Enter
            break
        fi
        sleep 5
    done
fi
```

Where `STATUS` is `green` or `blocked` matching the receipt, and
`PIPELINE_ID` is the same one this executor shepherded (injected by
ci-shepherd or resolved via Step 1). This enables ci-shepherd to forward
the outcome to Discord and reclaim the executor window.

Omit the callback entirely when `CI_SHEPHERD_WINDOW` is unset (i.e. manual
invocation by owner). The receipt on disk is still the authoritative record.
