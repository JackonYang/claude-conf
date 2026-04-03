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
- `github.com` → GitHub, use `gh`
- anything else → GitLab, use `glab api`

#### GitLab

```bash
PROJECT_PATH=$(echo "$REMOTE_URL" | sed -E 's|.*[:/](.*)\.git$|\1|')
PROJECT_ENC=$(echo "$PROJECT_PATH" | sed 's|/|%2F|g')
# Find MR
glab api "projects/$PROJECT_ENC/merge_requests?source_branch=$BRANCH&state=opened&per_page=1"
```

#### GitHub

```bash
REPO=$(echo "$REMOTE_URL" | sed -E 's|.*[:/](.*)\.git$|\1|')
# Find PR
gh pr view "$BRANCH" --json number,url
```

No MR/PR → stop.

### Step 1. Get latest pipeline/check status

#### GitLab
```bash
glab api "projects/$PROJECT_ENC/merge_requests/$MR_IID/pipelines?per_page=1"
```

#### GitHub
```bash
# Get check suite for HEAD commit
SHA=$(git rev-parse HEAD)
gh api "repos/$REPO/commits/$SHA/check-runs" --jq '.check_runs[] | {id,name,status,conclusion}'
# Or get workflow runs
gh run list --branch "$BRANCH" --limit 1 --json databaseId,status,conclusion
```

No pipeline/checks → push to trigger, wait 15s, retry.

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

Write to `~/.shepherd/receipts/<dispatch_id>.yaml`:

```yaml
receipt_id: r-<uuid-short>
dispatch_id: <from dispatch>
status: green
updated_at: <timestamp>
payload:
  mr_iid: <N>
  mr_url: <MR/PR web URL>
  pipeline_id: <id>
  pipeline_url: <url>
  fix_rounds: <N>
  commits:
    - hash: <sha>
      message: <summary>
  duration: <total time>
```

### Step 7. Emit BLOCKED receipt

Write to `~/.shepherd/receipts/<dispatch_id>.yaml`:

```yaml
receipt_id: r-<uuid-short>
dispatch_id: <from dispatch>
status: blocked
updated_at: <timestamp>
payload:
  mr_iid: <N>
  mr_url: <MR/PR web URL>
  pipeline_id: <id>
  pipeline_url: <url>
  failed_job: <name>
  failure_type: <build | test | environment | infrastructure | flaky_repeated>
  error: <message>
  attempts_total: <N>
  attempts_same_error: <M>
  reason: <why>
  suggested_next_action: <what owner should do>
```
