"""
title: SWE Agent
description: Fully autonomous software engineer. Give it a task — it writes code, writes tests, runs them, fixes failures, and delivers working software.
author: AI Stack
version: 1.1.0
"""

import sys
import os
from typing import Generator
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_framework import ToolRegistry, AgentLoop, SWE_SYSTEM_PROMPT


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

        system = SWE_SYSTEM_PROMPT.format(tools=tools.get_tool_descriptions())
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        yield from agent.run(
            system_prompt=system,
            user_message=user_msg,
            conversation=prior,
        )
