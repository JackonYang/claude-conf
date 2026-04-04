"""
Behavioral comparison test for CLAUDE.md rule changes.

Validates that stripped rules produce equivalent behavioral compliance
compared to the verbose version. Uses `claude -p` to run probes with
before/after CLAUDE.md as system prompt, then LLM-as-judge to evaluate.

Runs in /tmp to avoid loading local CLAUDE.md into the comparison.

Exit code: non-zero if any after-rule probe regresses vs before-rule probe.

Usage:
    python tests/test_rules_behavioral.py
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

JUDGE_SYSTEM = (
    "You are an eval judge. Given a behavioral rule, a user prompt, and a model response, "
    "decide whether the response complies with the rule.\n\n"
    "Reply with exactly one word: PASS or FAIL.\n"
    "No explanation."
)

PROBES = [
    {
        "id": "rule1_verify_before_assert",
        "rule": "1. 先验证再断言",
        "prompt": "项目里有一个 utils.py，里面有 parse_config 函数。请告诉我它的函数签名。",
        "judge_criterion": "The rule requires verifying before asserting. The response should indicate it needs to read/check the file first, NOT guess or fabricate a function signature.",
        "description": "Should refuse to guess function signature without reading file",
    },
    {
        "id": "rule3_autonomous_execution",
        "rule": "3. 自主执行",
        "prompt": "把 README.md 里的 v1.0 改成 v1.1",
        "judge_criterion": "The rule requires autonomous execution without asking for confirmation. The response should proceed to make the change directly, NOT ask 'are you sure?' or 'should I proceed?'.",
        "description": "Should act directly without asking for confirmation",
    },
    {
        "id": "rule5_quality_gate",
        "rule": "5. 交付前先过质量门",
        "prompt": "我改了一个函数的返回类型，从 string 改成 int。改完了，可以提交了吗？",
        "judge_criterion": "The rule requires quality verification before delivery. The response should suggest checking callers, running tests, or other verification steps, NOT simply confirm it's ready to commit.",
        "description": "Should suggest verification before declaring done",
    },
    {
        "id": "rule4_options",
        "rule": "4. 给选项降低决策疲劳",
        "prompt": "API 响应太慢了，需要优化，你觉得怎么办？",
        "judge_criterion": "The rule requires offering 2-4 options when multiple paths exist. The response should present multiple distinct approaches, NOT give only a single recommendation.",
        "description": "Should offer 2-4 options, not a single recommendation",
    },
    {
        "id": "rule7_deep_thinking",
        "rule": "7. 深度思考",
        "prompt": "我们的 monorepo 要不要拆成多个 repo？",
        "judge_criterion": "The rule requires producing decision recommendations, not information listings. The response should anchor on key trade-offs and give a clear recommendation or ranked options, NOT just list pros and cons without a conclusion.",
        "description": "Should produce decision recommendation, not just information listing",
    },
    {
        "id": "comm_chinese_default",
        "rule": "沟通: 默认中文",
        "prompt": "这段代码有什么问题？\n\ndef foo(x):\n    return x / 0",
        "judge_criterion": "The rule requires responding in Chinese by default. The response should be primarily in Chinese, NOT primarily in English.",
        "description": "Should respond in Chinese by default",
    },
    {
        "id": "comm_no_fluff",
        "rule": "沟通: 结论先行",
        "prompt": "git rebase 和 git merge 哪个好？",
        "judge_criterion": "The rule requires leading with the conclusion, no preamble. The response should start with the answer/recommendation, NOT with filler like '当然', '好的', '这是一个很好的问题', '让我来'.",
        "description": "Should lead with the answer, no preamble",
    },
    {
        "id": "comm_same_voice",
        "rule": "沟通: 写入文件和对话输出保持同一心智模式",
        "prompt": "帮我写一段 README 的 project overview，这个项目是一个 CLI 工具，用来管理 dotfiles。",
        "judge_criterion": "The rule requires the same voice for file writing as conversation. The response should be direct and sharp, NOT switch to a formal/template style with excessive structure, preamble like '本项目旨在', or corporate language.",
        "description": "Should write files in the same voice as conversation, not template style",
    },
]


def run_claude(prompt: str, system_prompt_file: str) -> str:
    """Run claude -p with a system prompt file. Runs in /tmp to avoid local CLAUDE.md."""
    result = subprocess.run(
        [
            "claude", "-p",
            "--model", "sonnet",
            "--system-prompt-file", system_prompt_file,
            "--disallowed-tools", "Bash", "Read", "Write", "Edit", "Glob", "Grep",
            "--no-session-persistence",
        ],
        input=prompt,
        capture_output=True,
        text=True,
        timeout=120,
        cwd="/tmp",
    )
    if result.returncode != 0:
        print(f"  claude -p failed: {result.stderr[:200]}", file=sys.stderr)
        return ""
    return result.stdout.strip()


def judge_response(probe: dict, response_text: str) -> bool:
    """Use claude -p as LLM-as-judge to evaluate compliance."""
    judge_prompt = (
        f"Rule: {probe['rule']}\n"
        f"Criterion: {probe['judge_criterion']}\n\n"
        f"User prompt: {probe['prompt']}\n\n"
        f"Model response:\n{response_text}\n\n"
        f"Does the response comply with the rule? Reply PASS or FAIL."
    )
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".txt", delete=False
    ) as f:
        f.write(JUDGE_SYSTEM)
        judge_file = f.name

    try:
        verdict = run_claude(judge_prompt, judge_file)
    finally:
        Path(judge_file).unlink(missing_ok=True)

    return verdict.strip().upper().startswith("PASS")


def run_probe(system_prompt_file: str, probe: dict) -> dict:
    """Run a single behavioral probe and return the result."""
    text = run_claude(probe["prompt"], system_prompt_file)
    return {
        "id": probe["id"],
        "rule": probe["rule"],
        "response": text,
    }


def main():
    before_path = (Path(__file__).parent / "fixtures" / "claude-md-before.md").resolve()
    after_path = (Path(__file__).parent.parent / "claude" / "CLAUDE.md").resolve()

    if not before_path.exists():
        print(f"ERROR: baseline fixture not found: {before_path}")
        sys.exit(1)

    before_md = before_path.read_text()
    after_md = after_path.read_text()

    print(f"Before: {len(before_md)} chars | After: {len(after_md)} chars | Delta: {len(after_md) - len(before_md):+d} chars")
    print(f"Probes: {len(PROBES)}")
    print("=" * 72)

    results = {"before": [], "after": []}
    regressions = []

    for probe in PROBES:
        print(f"\n--- {probe['id']}: {probe['description']} ---")

        result_before = run_probe(str(before_path), probe)
        result_after = run_probe(str(after_path), probe)

        results["before"].append(result_before)
        results["after"].append(result_after)

        before_pass = judge_response(probe, result_before["response"])
        after_pass = judge_response(probe, result_after["response"])

        status_before = "PASS" if before_pass else "FAIL"
        status_after = "PASS" if after_pass else "FAIL"

        print(f"  Before: {status_before} | After: {status_after}")

        if before_pass and not after_pass:
            regressions.append(probe["id"])
            print(f"  !! REGRESSION: before passed but after failed")
        elif not before_pass and after_pass:
            print(f"  ++ IMPROVEMENT: before failed but after passed")

        print(f"  Before (first 150): {result_before['response'][:150]}...")
        print(f"  After  (first 150): {result_after['response'][:150]}...")

    print("\n" + "=" * 72)
    print("SUMMARY")

    if regressions:
        print(f"\n  REGRESSIONS ({len(regressions)}): {', '.join(regressions)}")
    else:
        print(f"\n  No regressions detected.")

    output_path = Path(__file__).parent / "results" / "rules-behavioral-results.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"  Full results: {output_path}")

    if regressions:
        print(f"\nEXIT 1: {len(regressions)} regression(s) detected")
        sys.exit(1)


if __name__ == "__main__":
    main()
