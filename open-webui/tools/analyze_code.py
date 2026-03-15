"""
title: Analyze Code
description: Deep code analysis — complexity, security vulnerabilities, dead code, type checking.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional


class Tools:
    def __init__(self):
        self.sandbox_url = "http://sandbox:8080"

    def analyze_code(
        self,
        code: str,
        checks: str = "complexity,security,dead_code",
        __event_emitter__=None,
    ) -> str:
        """
        Perform deep static analysis on Python code. Checks for complexity,
        security vulnerabilities, dead code, and type errors.

        :param code: The Python source code to analyze.
        :param checks: Comma-separated list of checks: complexity, security, dead_code, types.
        :return: Analysis results with actionable findings.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": "Analyzing code...", "done": False}}
            )

        check_list = [c.strip() for c in checks.split(",")]

        try:
            response = requests.post(
                f"{self.sandbox_url}/analyze",
                json={"code": code, "language": "python", "checks": check_list},
                timeout=30,
            )
            result = response.json()

            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": "Analysis complete", "done": True}}
                )

            output = []

            # Complexity
            if "complexity" in result:
                r = result["complexity"]
                stdout = r.get("stdout", "")
                if stdout and stdout.strip() != "{}":
                    output.append(f"**Cyclomatic Complexity:**\n```json\n{stdout}\n```")
                else:
                    output.append("**Cyclomatic Complexity:** Low (good!)")

            if "maintainability" in result:
                r = result["maintainability"]
                stdout = r.get("stdout", "")
                if stdout and stdout.strip() != "{}":
                    output.append(f"**Maintainability Index:**\n```json\n{stdout}\n```")

            # Security
            if "security" in result:
                r = result["security"]
                stdout = r.get("stdout", "")
                if r.get("exit_code") == 0:
                    output.append("**Security: No issues found!**")
                elif stdout:
                    try:
                        findings = json.loads(stdout)
                        issues = findings.get("results", [])
                        if issues:
                            lines = []
                            for issue in issues:
                                sev = issue.get("issue_severity", "?")
                                conf = issue.get("issue_confidence", "?")
                                text = issue.get("issue_text", "?")
                                line = issue.get("line_number", "?")
                                lines.append(f"  - **[{sev}/{conf}]** Line {line}: {text}")
                            output.append("**Security Issues:**\n" + "\n".join(lines))
                        else:
                            output.append("**Security: No issues found!**")
                    except json.JSONDecodeError:
                        output.append(f"**Security:**\n```\n{stdout}\n```")

            # Dead code
            if "dead_code" in result:
                r = result["dead_code"]
                stdout = r.get("stdout", "")
                if r.get("exit_code") == 0 and not stdout.strip():
                    output.append("**Dead Code: None detected!**")
                elif stdout:
                    output.append(f"**Potential Dead Code:**\n```\n{stdout}\n```")

            # Type checking
            if "type_check" in result:
                r = result["type_check"]
                if r.get("exit_code") == 0:
                    output.append("**Type Check: All types valid!**")
                else:
                    stdout = r.get("stdout", "")
                    if stdout:
                        output.append(f"**Type Errors:**\n```\n{stdout}\n```")

            return "\n\n".join(output) if output else "Analysis produced no output."

        except Exception as e:
            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Analysis error: {str(e)}", "done": True}}
                )
            return f"Error connecting to sandbox: {str(e)}"
