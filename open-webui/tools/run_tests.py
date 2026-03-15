"""
title: Run Tests
description: Run test suites in the sandbox. Write code + tests, get results with coverage.
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

    def run_tests(
        self,
        files: str,
        language: str = "python",
        test_command: str = "",
        __event_emitter__=None,
    ) -> str:
        """
        Run a test suite in the sandbox. Provide source code and test files together.

        For Python, provide files as JSON: {"module.py": "code...", "test_module.py": "test code..."}
        For JavaScript: {"index.js": "code...", "index.test.js": "test code..."}

        :param files: JSON string mapping filenames to their contents. Include both source and test files.
        :param language: Programming language (default: python).
        :param test_command: Optional custom test command (e.g., "pytest -v --tb=long").
        :return: Test results with pass/fail counts and details.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": f"Running {language} tests...", "done": False}}
            )

        try:
            parsed_files = json.loads(files) if isinstance(files, str) else files
        except json.JSONDecodeError as e:
            return f"Error parsing files JSON: {e}\n\nExpected format: {{\"filename.py\": \"code...\", \"test_filename.py\": \"test code...\"}}"

        try:
            payload = {
                "files": parsed_files,
                "language": language,
                "timeout": 60,
            }
            if test_command:
                payload["test_command"] = test_command

            response = requests.post(
                f"{self.sandbox_url}/test",
                json=payload,
                timeout=65,
            )
            result = response.json()

            if __event_emitter__:
                status = "passed" if result.get("exit_code") == 0 else "failed"
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Tests {status}", "done": True}}
                )

            output = []
            if result.get("stdout"):
                output.append(f"**Test Output:**\n```\n{result['stdout']}\n```")
            if result.get("stderr"):
                output.append(f"**Errors:**\n```\n{result['stderr']}\n```")

            exit_code = result.get("exit_code", -1)
            if exit_code == 0:
                output.append("**Result: ALL TESTS PASSED**")
            else:
                output.append(f"**Result: TESTS FAILED** (exit code {exit_code})")

            output.append(f"**Duration:** {result.get('duration_ms', 0)}ms")

            return "\n\n".join(output)

        except Exception as e:
            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": f"Test error: {str(e)}", "done": True}}
                )
            return f"Error connecting to sandbox: {str(e)}"
