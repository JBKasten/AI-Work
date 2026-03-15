"""
title: QA Agent
description: Autonomous testing agent. Give it code — it writes comprehensive tests, runs them, finds bugs, and reports results.
author: AI Stack
version: 1.0.0
"""

import json
import sys
import os
from typing import Generator
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(__file__))
from agent_framework import ToolRegistry, AgentLoop


SYSTEM_PROMPT = """You are an elite QA engineer agent. Your job is to find bugs, write tests, and ensure code quality.

YOUR WORKFLOW:
1. ANALYZE: Read and understand the code being tested.
2. IDENTIFY: Find potential bugs, edge cases, error conditions, and untested paths.
3. WRITE TESTS: Create comprehensive test suites covering:
   - Happy path (normal usage)
   - Edge cases (empty inputs, large inputs, boundary values)
   - Error handling (invalid inputs, exceptions)
   - Type checking (wrong types, None/null)
   - Concurrency issues (if applicable)
   - Security (injection, overflow, if applicable)
4. RUN TESTS: Execute the test suite and analyze results.
5. REPORT: If tests fail, identify whether the bug is in the code or the test.
6. FIX: Suggest or implement fixes for discovered bugs.
7. VERIFY: Re-run tests after fixes.
8. FINISH: Provide a QA report with coverage summary.

TEST QUALITY STANDARDS:
- Minimum 10 test cases per function/class
- Test both success AND failure paths
- Use descriptive test names: test_function_should_behavior_when_condition
- Use parameterized tests where appropriate
- Include setup/teardown if needed
- Assert specific values, not just truthiness
- Test return types and structure

REPORTING FORMAT:
When done, provide:
- Total tests: X
- Passed: X
- Failed: X
- Bugs found: [list of bugs]
- Coverage areas: [list of what was tested]
- Recommendations: [list of improvements]

TOOL CALLING FORMAT:
```json
{{"tool": "tool_name", "param": "value"}}
```

{tools}

IMPORTANT: You must call a tool in every response. Think first, then call exactly one tool."""


class Pipeline:
    class Valves(BaseModel):
        sandbox_url: str = Field(default="http://sandbox:8080")
        litellm_url: str = Field(default="http://litellm:4000")
        litellm_key: str = Field(default="")
        model: str = Field(default="code", description="LLM model for test generation")
        max_steps: int = Field(default=15, description="Max agent steps")

    def __init__(self):
        self.name = "QA Agent"
        self.valves = self.Valves()

    def pipe(self, body: dict) -> Generator[str, None, None]:
        messages = body.get("messages", [])
        if not messages:
            yield "No code provided for testing."
            return

        user_msg = messages[-1].get("content", "")

        yield "## QA Agent Activated\n\n"
        yield "**Mission:** Find bugs. Write tests. Break things. Make it bulletproof.\n\n"

        tools = ToolRegistry(
            sandbox_url=self.valves.sandbox_url,
            litellm_url=self.valves.litellm_url,
            litellm_key=self.valves.litellm_key,
        )

        agent = AgentLoop(
            tools=tools,
            litellm_url=self.valves.litellm_url,
            litellm_key=self.valves.litellm_key,
            model=self.valves.model,
            max_steps=self.valves.max_steps,
        )

        system = SYSTEM_PROMPT.format(tools=tools.get_tool_descriptions())
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        yield from agent.run(
            system_prompt=system,
            user_message=f"QA task: {user_msg}",
            conversation=prior,
        )
