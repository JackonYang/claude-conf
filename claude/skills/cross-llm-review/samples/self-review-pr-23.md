## Summary

This PR introduces a new skill, `cross-llm-review`, which wraps the GitHub Copilot CLI to provide an isolated, independent second-opinion PR review using GPT-4.1. It ensures hard isolation from local context (e.g., CLAUDE.md/AGENTS.md) and disables cross-repo pollution, with clear documentation and a sample review included.

## Concerns

### `claude/skills/cross-llm-review/bin/cross-llm-review.sh`
> ```diff
> +  "$COPILOT_BIN" \
> +    --model "$MODEL" \
> +    --no-custom-instructions \
> +    --disable-builtin-mcps \
> +    --no-ask-user \
> +    --silent \
> +    --output-format json \
> +    --allow-all-tools \
> +    --allow-all-paths \
> +    -p "$(cat ./prompt.md)" \
> +    > "$RAW_OUT" 2>&1
> ```

- **Risk:** The script passes the entire prompt via `-p "$(cat ./prompt.md)"`. If the PR bundle is very large, this could hit shell or copilot CLI argument length limits, potentially truncating the prompt and causing incomplete reviews. There is no explicit check or warning for prompt size.

> ```diff
> +if ! gh pr view "$PR_NUM" "${GH_REPO_FLAG[@]}" \
> +       --json number,title,body,author,baseRefName,headRefName,state,url,additions,deletions,changedFiles \
> +       > "$PR_META_JSON" 2>/dev/null; then
> +  echo "failed to fetch PR metadata for $PR_REF" >&2
> +  exit 4
> +fi
> ```

- **Risk:** The script suppresses all `gh` CLI errors (`2>/dev/null`), which could make debugging harder if the underlying issue is authentication, network, or permissions. The user only sees a generic failure message.

> ```diff
> +trap cleanup EXIT
> +...
> +if ! $KEEP_ISO; then
> +  rm -rf "$ISO_DIR"
> +else
> +  echo "[cross-llm-review] kept isolation dir: $ISO_DIR" >&2
> +fi
> ```

- **Risk:** If the script is interrupted (e.g., with SIGKILL), the isolation directory may not be cleaned up, leading to orphaned `/tmp/cross-llm-review/*` directories over time. This is a minor resource leak.

### `claude/skills/cross-llm-review/SKILL.md`
> ```diff
> +- `--no-custom-instructions` — blocks AGENTS.md / CLAUDE.md auto-load. Without
> +  it, copilot picks up whatever instruction file lives in cwd and answers as
> +  that project's agent rather than as a neutral reviewer.
> +...
> +- `--disable-builtin-mcps` — disables `github-mcp-server`. Without it, copilot
> +  has cross-repo write access and has been observed making real changes
> +  (writing to dispatches.yaml in waypoint cwd) just to satisfy a probe prompt.
> +...
> +Per-machine prerequisite: `copilot` CLI installed and authenticated.
> ```

- **Risk:** The documentation is clear about the need for isolation, but the script does not check for or warn about a running `github-mcp-server` process outside the isolated environment, which could still pose a risk if the Copilot CLI changes its behavior in future versions.

## Questions for the author

1. Have you observed any prompt truncation or failures when reviewing very large PRs? If so, is there a mitigation plan?
2. Is there a reason for suppressing all `gh` CLI error output, rather than surfacing it to the user for debugging?
3. Should there be a periodic cleanup mechanism for `/tmp/cross-llm-review/` in case of orphaned directories from interrupted runs?
4. Have you tested with Copilot CLI versions beyond the current one to ensure the isolation flags remain effective?

## What looks good

- The isolation contract is well-documented and strictly enforced in the script.
- The prompt inlining approach is justified with real-world evidence, avoiding hallucinated reviews.
- The sample review demonstrates grounded, high-signal output, quoting real diff lines and surfacing nuanced risks.
- The script is defensive about tool presence and provides actionable error hints (e.g., for Copilot auth).

---
_cross-llm-review · model: see invocation · premiumRequests: 0 · api: 56464ms · session: 58664ms_
