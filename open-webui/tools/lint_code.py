"""
title: Lint & Fix Code
description: Lint code for issues, auto-fix problems, and format. Supports Python, JavaScript, TypeScript, Bash.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional


class Tools:
    def __init__(self):
        self.sandbox_url = "http://sandbox:8080"

    def lint_code(
        self,
        code: str,
        language: str = "python",
        fix: bool = True,
        __event_emitter__=None,
    ) -> str:
        """
        Lint code for errors, style issues, and potential bugs. Optionally auto-fix.

        :param code: The source code to lint.
        :param language: Programming language (python, javascript, typescript, bash).
        :param fix: If true, auto-fix issues and return corrected code (default: true).
        :return: Lint warnings/errors and optionally the fixed code.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": f"Linting {language} code...", "done": False}}
            )

        try:
            response = requests.post(
                f"{self.sandbox_url}/lint",
                json={"code": code, "language": language, "fix": fix},
                timeout=20,
            )
            result = response.json()

            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": "Lint complete", "done": True}}
                )

            output = []

            # Lint results
            if "lint" in result:
                lint = result["lint"]
                if lint.get("exit_code") == 0:
                    output.append("**Lint: No issues found!**")
                else:
                    stderr = lint.get("stderr", "")
                    stdout = lint.get("stdout", "")
                    issues = stdout or stderr
                    if issues:
                        output.append(f"**Lint Issues:**\n```\n{issues}\n```")

            # Fixed code
            if "fixed_code" in result:
                output.append(f"**Fixed Code:**\n```{language}\n{result['fixed_code']}\n```")

            return "\n\n".join(output) if output else "No lint output available."

        except Exception as e:
            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Lint error: {str(e)}", "done": True}}
                )
            return f"Error connecting to sandbox: {str(e)}"
