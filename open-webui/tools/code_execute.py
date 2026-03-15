"""
title: Code Execute
description: Execute code in a sandboxed environment. Supports Python, JavaScript, TypeScript, Go, Rust, and Bash.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional
from pydantic import BaseModel, Field


class Tools:
    def __init__(self):
        self.sandbox_url = "http://sandbox:8080"

    def execute_code(
        self,
        code: str,
        language: str = "python",
        stdin: str = "",
        __event_emitter__=None,
    ) -> str:
        """
        Execute code in a secure sandbox. Returns stdout, stderr, and exit code.

        Supported languages: python, javascript, typescript, go, rust, bash.

        :param code: The source code to execute.
        :param language: Programming language (default: python).
        :param stdin: Optional standard input to feed to the program.
        :return: Execution result with stdout, stderr, exit code, and duration.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": f"Running {language} code...", "done": False}}
            )

        try:
            response = requests.post(
                f"{self.sandbox_url}/execute",
                json={"code": code, "language": language, "stdin": stdin, "timeout": 30},
                timeout=35,
            )
            result = response.json()

            if __event_emitter__:
                status = "completed" if result.get("exit_code") == 0 else "failed"
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Code {status} ({result.get('duration_ms', 0)}ms)", "done": True}}
                )

            output = []
            if result.get("stdout"):
                output.append(f"**stdout:**\n```\n{result['stdout']}\n```")
            if result.get("stderr"):
                output.append(f"**stderr:**\n```\n{result['stderr']}\n```")
            output.append(f"**Exit code:** {result.get('exit_code', -1)} | **Duration:** {result.get('duration_ms', 0)}ms")

            if result.get("timed_out"):
                output.append("**Warning:** Execution timed out!")

            return "\n\n".join(output)

        except Exception as e:
            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Execution error: {str(e)}", "done": True}}
                )
            return f"Error connecting to sandbox: {str(e)}"
