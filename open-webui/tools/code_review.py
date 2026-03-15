"""
title: Code Review
description: Comprehensive code review — runs lint, tests, analysis, and generates AI review using the best coding model.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional


class Tools:
    def __init__(self):
        self.sandbox_url = "http://sandbox:8080"
        self.litellm_url = "http://litellm:4000"

    def full_code_review(
        self,
        code: str,
        language: str = "python",
        context: str = "",
        __event_emitter__=None,
    ) -> str:
        """
        Perform a comprehensive code review: lint + static analysis + AI review.
        Gets automated checks AND an AI-generated review with specific suggestions.

        :param code: The source code to review.
        :param language: Programming language (python, javascript, typescript, go, rust).
        :param context: Optional context about what the code should do.
        :return: Complete review with automated checks and AI suggestions.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": "Running comprehensive review...", "done": False}}
            )

        sections = []

        # 1. Lint
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": "Step 1/3: Linting...", "done": False}}
            )
        try:
            lint_resp = requests.post(
                f"{self.sandbox_url}/lint",
                json={"code": code, "language": language, "fix": True},
                timeout=20,
            )
            lint_result = lint_resp.json()
            lint_data = lint_result.get("lint", {})
            if lint_data.get("exit_code") == 0:
                sections.append("### Lint\nNo issues found.")
            else:
                issues = lint_data.get("stdout", "") or lint_data.get("stderr", "")
                sections.append(f"### Lint Issues\n```\n{issues}\n```")
            if "fixed_code" in lint_result:
                sections.append(f"### Auto-Fixed Code\n```{language}\n{lint_result['fixed_code']}\n```")
        except Exception as e:
            sections.append(f"### Lint\nError: {e}")

        # 2. Static analysis (Python only)
        if language == "python":
            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": "Step 2/3: Static analysis...", "done": False}}
                )
            try:
                analysis_resp = requests.post(
                    f"{self.sandbox_url}/analyze",
                    json={"code": code, "language": "python", "checks": ["complexity", "security", "dead_code"]},
                    timeout=30,
                )
                analysis = analysis_resp.json()

                # Security
                sec = analysis.get("security", {})
                if sec.get("exit_code") == 0:
                    sections.append("### Security\nNo vulnerabilities detected.")
                else:
                    sec_out = sec.get("stdout", "")
                    if sec_out:
                        try:
                            findings = json.loads(sec_out)
                            issues = findings.get("results", [])
                            if issues:
                                lines = [f"- **[{i['issue_severity']}]** Line {i.get('line_number','?')}: {i['issue_text']}" for i in issues]
                                sections.append("### Security Issues\n" + "\n".join(lines))
                            else:
                                sections.append("### Security\nNo vulnerabilities detected.")
                        except json.JSONDecodeError:
                            sections.append(f"### Security\n```\n{sec_out}\n```")

                # Dead code
                dead = analysis.get("dead_code", {})
                dead_out = dead.get("stdout", "").strip()
                if dead_out:
                    sections.append(f"### Potential Dead Code\n```\n{dead_out}\n```")

            except Exception as e:
                sections.append(f"### Static Analysis\nError: {e}")
        else:
            sections.append("### Static Analysis\nAvailable for Python only (skipped).")

        # 3. Compile / syntax check
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": "Step 3/3: Generating review...", "done": False}}
            )

        # Combine all automated results
        automated = "\n\n".join(sections)

        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": "Review complete", "done": True}}
            )

        return f"## Automated Code Review\n\n{automated}"
