"""
title: Coding Pipeline
description: Solve → Test → Fix → Finish loop. Writes code, runs tests, fixes failures, repeats until green.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional, Generator
from pydantic import BaseModel, Field


class Pipeline:
    """
    A pipeline that implements the solve → test → fix → finish loop.

    When a user asks to solve a coding problem, this pipeline:
    1. Generates a solution using the best coding model
    2. Writes tests for the solution
    3. Runs the tests in the sandbox
    4. If tests fail, sends failures back to the model for fixing
    5. Repeats until all tests pass or max iterations reached

    Configure in Open WebUI → Admin → Pipelines.
    """

    class Valves(BaseModel):
        sandbox_url: str = Field(default="http://sandbox:8080", description="Code sandbox API URL")
        litellm_url: str = Field(default="http://litellm:4000", description="LiteLLM proxy URL")
        litellm_key: str = Field(default="", description="LiteLLM master key")
        model: str = Field(default="code", description="Model to use for code generation")
        max_fix_iterations: int = Field(default=3, description="Max fix attempts before giving up")
        language: str = Field(default="python", description="Default language")

    def __init__(self):
        self.name = "Coding Pipeline"
        self.valves = self.Valves()

    def _run_in_sandbox(self, endpoint: str, payload: dict) -> dict:
        """Call the sandbox API."""
        try:
            resp = requests.post(
                f"{self.valves.sandbox_url}/{endpoint}",
                json=payload,
                timeout=65,
            )
            return resp.json()
        except Exception as e:
            return {"error": str(e), "exit_code": -1}

    def _call_llm(self, messages: list, stream: bool = False):
        """Call LiteLLM for code generation."""
        headers = {"Content-Type": "application/json"}
        if self.valves.litellm_key:
            headers["Authorization"] = f"Bearer {self.valves.litellm_key}"

        resp = requests.post(
            f"{self.valves.litellm_url}/v1/chat/completions",
            headers=headers,
            json={
                "model": self.valves.model,
                "messages": messages,
                "temperature": 0.1,
                "stream": stream,
            },
            timeout=120,
        )
        data = resp.json()
        return data["choices"][0]["message"]["content"]

    def pipe(self, body: dict) -> Generator[str, None, None]:
        """
        Main pipeline: solve → test → fix → finish.
        """
        messages = body.get("messages", [])
        if not messages:
            yield "No messages provided."
            return

        user_msg = messages[-1].get("content", "")

        # Step 1: Generate solution + tests
        yield "## Step 1: Generating Solution\n\n"

        solve_prompt = [
            {
                "role": "system",
                "content": (
                    f"You are an expert {self.valves.language} developer. "
                    "When given a coding task:\n"
                    "1. Write the solution code\n"
                    "2. Write comprehensive tests (pytest for Python, jest for JS)\n"
                    "3. Return EXACTLY two code blocks:\n"
                    "   - First block labeled `solution` with the implementation\n"
                    "   - Second block labeled `tests` with the test file\n"
                    "Make the solution correct, clean, and well-tested.\n"
                    "Include edge cases in tests."
                ),
            },
            *messages,
        ]

        solution_response = self._call_llm(solve_prompt)
        yield solution_response + "\n\n"

        # Extract code blocks
        code_blocks = self._extract_code_blocks(solution_response)
        if len(code_blocks) < 2:
            yield "\n\n*Could not extract separate solution and test blocks. Showing raw response.*\n"
            return

        solution_code = code_blocks[0]
        test_code = code_blocks[1]

        # Step 2: Run tests
        iteration = 0
        while iteration < self.valves.max_fix_iterations:
            iteration += 1
            yield f"\n\n## Step {iteration + 1}: Running Tests (attempt {iteration}/{self.valves.max_fix_iterations})\n\n"

            if self.valves.language == "python":
                files = {"solution.py": solution_code, "test_solution.py": test_code}
            elif self.valves.language in ("javascript", "typescript"):
                ext = "js" if self.valves.language == "javascript" else "ts"
                files = {f"solution.{ext}": solution_code, f"solution.test.{ext}": test_code}
            else:
                files = {"solution.py": solution_code, "test_solution.py": test_code}

            result = self._run_in_sandbox("test", {
                "files": files,
                "language": self.valves.language,
                "timeout": 60,
            })

            stdout = result.get("stdout", "")
            stderr = result.get("stderr", "")
            exit_code = result.get("exit_code", -1)

            if exit_code == 0:
                yield f"```\n{stdout}\n```\n\n"
                yield "## ALL TESTS PASSED!\n\n"
                yield f"### Final Solution\n\n```{self.valves.language}\n{solution_code}\n```\n"
                return

            # Tests failed — show output
            yield f"```\n{stdout}\n{stderr}\n```\n\n"

            if iteration >= self.valves.max_fix_iterations:
                yield f"\n\n## Max iterations reached ({self.valves.max_fix_iterations}). Tests still failing.\n"
                yield f"\n### Current Solution\n\n```{self.valves.language}\n{solution_code}\n```\n"
                return

            # Step 3: Fix
            yield f"\n\n## Fixing (attempt {iteration})...\n\n"

            fix_prompt = [
                {
                    "role": "system",
                    "content": (
                        f"You are an expert {self.valves.language} developer fixing failing tests. "
                        "Analyze the test failures and fix the solution code. "
                        "Return EXACTLY two code blocks:\n"
                        "   - First block: the fixed solution\n"
                        "   - Second block: the tests (fix if needed, but prefer fixing the solution)\n"
                        "Do NOT explain — just return the two code blocks."
                    ),
                },
                {
                    "role": "user",
                    "content": (
                        f"The tests failed. Fix the code.\n\n"
                        f"**Solution:**\n```\n{solution_code}\n```\n\n"
                        f"**Tests:**\n```\n{test_code}\n```\n\n"
                        f"**Test output:**\n```\n{stdout}\n{stderr}\n```"
                    ),
                },
            ]

            fix_response = self._call_llm(fix_prompt)
            yield fix_response + "\n\n"

            new_blocks = self._extract_code_blocks(fix_response)
            if len(new_blocks) >= 2:
                solution_code = new_blocks[0]
                test_code = new_blocks[1]
            elif len(new_blocks) == 1:
                solution_code = new_blocks[0]

    def _extract_code_blocks(self, text: str) -> list[str]:
        """Extract code blocks from markdown."""
        blocks = []
        in_block = False
        current = []

        for line in text.split("\n"):
            if line.strip().startswith("```") and not in_block:
                in_block = True
                current = []
            elif line.strip() == "```" and in_block:
                in_block = False
                blocks.append("\n".join(current))
            elif in_block:
                current.append(line)

        return blocks
