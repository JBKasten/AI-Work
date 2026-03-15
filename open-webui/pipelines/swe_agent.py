"""
title: SWE Agent
description: Fully autonomous software engineer. Give it a task — it writes code, writes tests, runs them, fixes failures, and delivers working software.
author: AI Stack
version: 1.0.0
"""

import json
import sys
import os
from typing import Generator
from pydantic import BaseModel, Field

# Import from agent_framework (lives in same directory)
sys.path.insert(0, os.path.dirname(__file__))
from agent_framework import ToolRegistry, AgentLoop


SYSTEM_PROMPT = """You are an elite autonomous software engineer agent. You solve coding problems end-to-end with zero hand-holding.

YOUR WORKFLOW:
1. UNDERSTAND: Break down the task. Identify what needs to be built.
2. PLAN: Outline your approach in 2-3 sentences.
3. IMPLEMENT: Write the code using write_file.
4. TEST: Write comprehensive tests and run them using run_tests.
5. FIX: If tests fail, analyze failures and fix the code. Repeat until green.
6. VERIFY: Run the final code to make sure it works.
7. FINISH: Use the finish tool with a summary of what you built.

RULES:
- ALWAYS write tests. No exceptions. Test edge cases.
- ALWAYS run tests before declaring done.
- If tests fail, FIX the code (not the tests) unless the tests are wrong.
- Write clean, production-quality code. No shortcuts.
- Handle errors properly. Validate inputs at boundaries.
- Use type hints (Python), types (TypeScript), or equivalent.
- One tool call per response. Think first, then act.
- After EVERY tool call, analyze the result and decide the next step.

TOOL CALLING FORMAT:
When you want to use a tool, output EXACTLY one JSON block:
```json
{"tool": "tool_name", "param": "value"}
```

{tools}

IMPORTANT: You must call a tool in every response. Think step by step, then call exactly one tool."""


class Pipeline:
    class Valves(BaseModel):
        sandbox_url: str = Field(default="http://sandbox:8080")
        gitea_url: str = Field(default="http://gitea:3000")
        litellm_url: str = Field(default="http://litellm:4000")
        litellm_key: str = Field(default="")
        model: str = Field(default="code", description="LLM model for code generation")
        max_steps: int = Field(default=20, description="Max agent steps before stopping")

    def __init__(self):
        self.name = "SWE Agent"
        self.valves = self.Valves()

    def pipe(self, body: dict) -> Generator[str, None, None]:
        messages = body.get("messages", [])
        if not messages:
            yield "No task provided."
            return

        user_msg = messages[-1].get("content", "")

        yield "## SWE Agent Activated\n\n"
        yield f"**Task:** {user_msg[:200]}{'...' if len(user_msg) > 200 else ''}\n\n"

        tools = ToolRegistry(
            sandbox_url=self.valves.sandbox_url,
            gitea_url=self.valves.gitea_url,
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

        # Pass prior conversation for context
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        yield from agent.run(
            system_prompt=system,
            user_message=user_msg,
            conversation=prior,
        )
