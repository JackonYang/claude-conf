"""
Behavioral comparison test for CLAUDE.md rule changes.

Validates that stripped rules produce equivalent behavioral compliance
compared to the verbose version. Uses Claude API to run identical prompts
with before/after CLAUDE.md as system context.

Usage:
    python tests/test_rules_behavioral.py

Requires: ANTHROPIC_API_KEY environment variable
"""

import json
import os
import sys
from pathlib import Path

import anthropic

MODEL = "claude-sonnet-4-20250514"

# Probes: each targets a specific rule and has an expected behavioral signal
PROBES = [
    {
        "id": "rule1_verify_before_assert",
        "rule": "1. 先验证再断言",
        "prompt": "项目里有一个 utils.py，里面有 parse_config 函数。请告诉我它的函数签名。",
        "expect_signal": "需要先查看文件",
        "fail_signal": "def parse_config",
        "description": "Should refuse to guess function signature without reading file",
    },
    {
        "id": "rule3_autonomous_execution",
        "rule": "3. 自主执行",
        "prompt": "把 README.md 里的 v1.0 改成 v1.1",
        "expect_signal": "直接",
        "fail_signal": "是否确认|你确定|需要我",
        "description": "Should act directly without asking for confirmation",
    },
    {
        "id": "rule5_quality_gate",
        "rule": "5. 交付前先过质量门",
        "prompt": "我改了一个函数的返回类型，从 string 改成 int。改完了，可以提交了吗？",
        "expect_signal": "测试|验证|检查|调用方",
        "fail_signal": "可以提交",
        "description": "Should suggest verification before declaring done",
    },
    {
        "id": "rule4_options",
        "rule": "4. 给选项降低决策疲劳",
        "prompt": "API 响应太慢了，需要优化，你觉得怎么办？",
        "expect_signal": "方案|选项|路径|1\\.|2\\.",
        "fail_signal": None,
        "description": "Should offer 2-4 options, not a single recommendation",
    },
    {
        "id": "comm_chinese_default",
        "rule": "沟通: 默认中文",
        "prompt": "这段代码有什么问题？\n\ndef foo(x):\n    return x / 0",
        "expect_signal": "除以零|除零|ZeroDivision",
        "fail_signal": None,
        "description": "Should respond in Chinese by default",
    },
    {
        "id": "comm_no_fluff",
        "rule": "沟通: 结论先行",
        "prompt": "git rebase 和 git merge 哪个好？",
        "expect_signal": None,
        "fail_signal": "当然|好的|这是一个|让我来",
        "description": "Should lead with the answer, no preamble",
    },
]


def run_probe(client, system_prompt: str, probe: dict) -> dict:
    """Run a single behavioral probe and return the result."""
    response = client.messages.create(
        model=MODEL,
        max_tokens=512,
        system=system_prompt,
        messages=[{"role": "user", "content": probe["prompt"]}],
    )
    text = response.content[0].text
    return {
        "id": probe["id"],
        "rule": probe["rule"],
        "response": text,
        "input_tokens": response.usage.input_tokens,
        "output_tokens": response.usage.output_tokens,
    }


def check_signal(text: str, signal: str | None) -> bool:
    """Check if text matches a signal pattern (simple regex-like)."""
    if signal is None:
        return True  # no constraint
    import re
    return bool(re.search(signal, text))


def main():
    client = anthropic.Anthropic()

    before_path = Path(__file__).parent.parent / "tests" / "fixtures" / "claude-md-before.md"
    after_path = Path(__file__).parent.parent / "claude" / "CLAUDE.md"

    if not before_path.exists():
        # Fall back to tmp
        before_path = Path("/tmp/claude-md-before.md")

    before_md = before_path.read_text()
    after_md = after_path.read_text()

    print(f"Before: {len(before_md)} chars | After: {len(after_md)} chars | Delta: -{len(before_md) - len(after_md)} ({(len(before_md) - len(after_md)) / len(before_md) * 100:.1f}%)")
    print(f"Model: {MODEL}")
    print(f"Probes: {len(PROBES)}")
    print("=" * 72)

    results = {"before": [], "after": []}
    total_before_input = 0
    total_after_input = 0

    for probe in PROBES:
        print(f"\n--- {probe['id']}: {probe['description']} ---")

        result_before = run_probe(client, before_md, probe)
        result_after = run_probe(client, after_md, probe)

        results["before"].append(result_before)
        results["after"].append(result_after)

        total_before_input += result_before["input_tokens"]
        total_after_input += result_after["input_tokens"]

        # Check behavioral signals
        before_pass = check_signal(result_before["response"], probe["expect_signal"])
        after_pass = check_signal(result_after["response"], probe["expect_signal"])

        before_no_fail = not check_signal(result_before["response"], probe["fail_signal"]) if probe["fail_signal"] else True
        after_no_fail = not check_signal(result_after["response"], probe["fail_signal"]) if probe["fail_signal"] else True

        status_before = "PASS" if (before_pass and before_no_fail) else "FAIL"
        status_after = "PASS" if (after_pass and after_no_fail) else "FAIL"

        print(f"  Before: {status_before} | After: {status_after}")
        if status_before != status_after:
            print(f"  !! REGRESSION DETECTED")
        print(f"  Before tokens: {result_before['input_tokens']} | After tokens: {result_after['input_tokens']}")
        print(f"  Before response (first 120): {result_before['response'][:120]}...")
        print(f"  After  response (first 120): {result_after['response'][:120]}...")

    print("\n" + "=" * 72)
    print("SUMMARY")
    print(f"  Token savings per probe: ~{(total_before_input - total_after_input) / len(PROBES):.0f} input tokens")
    print(f"  Total before: {total_before_input} | Total after: {total_after_input}")

    # Write full results to JSON for review
    output_path = Path(__file__).parent / "results" / "rules-behavioral-results.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print(f"\n  Full results: {output_path}")


if __name__ == "__main__":
    main()
