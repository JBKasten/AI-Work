"""
title: QA Agent
description: Autonomous testing agent. Give it code — it writes comprehensive tests, runs them, finds bugs, and reports results.
author: AI Stack
version: 1.1.0
"""

import sys
import os
from typing import Generator
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_framework import ToolRegistry, AgentLoop, QA_SYSTEM_PROMPT


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

        system = QA_SYSTEM_PROMPT.format(tools=tools.get_tool_descriptions())
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        yield from agent.run(
            system_prompt=system,
            user_message=f"QA task: {user_msg}",
            conversation=prior,
        )
