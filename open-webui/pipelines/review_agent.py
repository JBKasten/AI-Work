"""
title: Code Review Agent
description: Autonomous code reviewer. Performs deep automated analysis — lint, security, complexity, dead code — then gives expert-level feedback.
author: AI Stack
version: 1.1.0
"""

import sys
import os
from typing import Generator
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_framework import ToolRegistry, AgentLoop, REVIEW_SYSTEM_PROMPT


class Pipeline:
    class Valves(BaseModel):
        sandbox_url: str = Field(default="http://sandbox:8080")
        litellm_url: str = Field(default="http://litellm:4000")
        litellm_key: str = Field(default="")
        model: str = Field(default="code-review", description="Model for code review")
        max_steps: int = Field(default=12, description="Max review steps")

    def __init__(self):
        self.name = "Code Review Agent"
        self.valves = self.Valves()

    def pipe(self, body: dict) -> Generator[str, None, None]:
        messages = body.get("messages", [])
        if not messages:
            yield "No code provided for review."
            return

        user_msg = messages[-1].get("content", "")

        yield "## Code Review Agent Activated\n\n"
        yield "**Performing:** Lint -> Security -> Complexity -> Expert Review\n\n"

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

        system = REVIEW_SYSTEM_PROMPT.format(tools=tools.get_tool_descriptions())
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        yield from agent.run(
            system_prompt=system,
            user_message=f"Review this code:\n\n{user_msg}",
            conversation=prior,
        )
