"""
title: Agent Orchestrator
description: Multi-agent coordinator. Routes tasks to the right specialist agent (SWE, QA, Review) and can chain agents together for complex workflows.
author: AI Stack
version: 1.1.0
"""

import json
import re
import sys
import os
import requests
from typing import Generator
from pydantic import BaseModel, Field

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from agent_framework import (
    ToolRegistry, AgentLoop,
    SWE_SYSTEM_PROMPT, QA_SYSTEM_PROMPT, REVIEW_SYSTEM_PROMPT,
)


ROUTER_PROMPT = """You are an AI project manager that routes tasks to specialist agents.

Available agents:
1. **SWE Agent** — Writes code, implements features, fixes bugs. Use for: "build X", "implement Y", "fix Z", "create a function that..."
2. **QA Agent** — Writes tests, finds bugs, ensures quality. Use for: "test X", "find bugs in Y", "write tests for Z", "is this code correct?"
3. **Review Agent** — Reviews code quality, security, performance. Use for: "review X", "is this secure?", "check quality of Y"
4. **Full Pipeline** — Chains: SWE builds -> QA tests -> Review checks. Use for: "build and test X", "complete implementation of Y", complex multi-step tasks.

Analyze the user's request and respond with EXACTLY one JSON block:
```json
{"route": "swe|qa|review|full", "task": "refined task description", "language": "python"}
```

Examples:
- "Write a binary search" -> {"route": "swe", "task": "Implement binary search with edge case handling", "language": "python"}
- "Test this sort function" -> {"route": "qa", "task": "Write comprehensive tests for the sort function", "language": "python"}
- "Review my API code" -> {"route": "review", "task": "Review this API code for security, performance, and correctness", "language": "python"}
- "Build a REST API with tests" -> {"route": "full", "task": "Build a REST API with full test coverage", "language": "python"}
"""


class Pipeline:
    class Valves(BaseModel):
        sandbox_url: str = Field(default="http://sandbox:8080")
        gitea_url: str = Field(default="http://gitea:3000")
        litellm_url: str = Field(default="http://litellm:4000")
        litellm_key: str = Field(default="")
        router_model: str = Field(default="code-fast", description="Fast model for routing decisions")
        swe_model: str = Field(default="code", description="Model for SWE agent")
        qa_model: str = Field(default="code", description="Model for QA agent")
        review_model: str = Field(default="code-review", description="Model for Review agent")
        max_steps_per_agent: int = Field(default=15, description="Max steps per agent")

    def __init__(self):
        self.name = "Agent Orchestrator"
        self.valves = self.Valves()

    def _call_llm(self, messages: list, model: str) -> str:
        headers = {"Content-Type": "application/json"}
        if self.valves.litellm_key:
            headers["Authorization"] = f"Bearer {self.valves.litellm_key}"

        try:
            resp = requests.post(
                f"{self.valves.litellm_url}/v1/chat/completions",
                headers=headers,
                json={"model": model, "messages": messages, "temperature": 0.0, "max_tokens": 500},
                timeout=30,
            )
            resp.raise_for_status()
            return resp.json()["choices"][0]["message"]["content"]
        except Exception as e:
            return f'{{"route": "swe", "task": "Error routing: {e}", "language": "python"}}'

    def _route_task(self, user_msg: str) -> dict:
        """Use a fast model to decide which agent handles this."""
        response = self._call_llm(
            [
                {"role": "system", "content": ROUTER_PROMPT},
                {"role": "user", "content": user_msg},
            ],
            model=self.valves.router_model,
        )

        # Extract JSON
        match = re.search(r'\{[^{}]*"route"[^{}]*\}', response, re.DOTALL)
        if match:
            try:
                return json.loads(match.group())
            except json.JSONDecodeError:
                pass

        # Default to SWE for ambiguous tasks
        return {"route": "swe", "task": user_msg, "language": "python"}

    def _run_agent(self, agent_name: str, model: str, system_prompt: str,
                   task: str, tools: ToolRegistry,
                   conversation: list) -> Generator[str, None, None]:
        """Run a single agent."""
        agent = AgentLoop(
            tools=tools,
            litellm_url=self.valves.litellm_url,
            litellm_key=self.valves.litellm_key,
            model=model,
            max_steps=self.valves.max_steps_per_agent,
        )

        yield from agent.run(
            system_prompt=system_prompt,
            user_message=task,
            conversation=conversation,
        )

    def pipe(self, body: dict) -> Generator[str, None, None]:
        messages = body.get("messages", [])
        if not messages:
            yield "No task provided."
            return

        user_msg = messages[-1].get("content", "")
        prior = [m for m in messages[:-1]] if len(messages) > 1 else []

        # Route the task
        yield "## Agent Orchestrator\n\n"
        yield "**Analyzing task and selecting best agent...**\n\n"

        route = self._route_task(user_msg)
        agent_type = route.get("route", "swe")
        task = route.get("task", user_msg)

        tools = ToolRegistry(
            sandbox_url=self.valves.sandbox_url,
            gitea_url=self.valves.gitea_url,
            litellm_url=self.valves.litellm_url,
            litellm_key=self.valves.litellm_key,
        )
        tool_desc = tools.get_tool_descriptions()

        if agent_type == "swe":
            yield f"**Routing to:** SWE Agent ({self.valves.swe_model})\n"
            yield f"**Task:** {task}\n\n"
            yield "---\n\n## SWE Agent\n\n"
            yield from self._run_agent(
                "SWE", self.valves.swe_model,
                SWE_SYSTEM_PROMPT.format(tools=tool_desc),
                task, tools, prior,
            )

        elif agent_type == "qa":
            yield f"**Routing to:** QA Agent ({self.valves.qa_model})\n"
            yield f"**Task:** {task}\n\n"
            yield "---\n\n## QA Agent\n\n"
            yield from self._run_agent(
                "QA", self.valves.qa_model,
                QA_SYSTEM_PROMPT.format(tools=tool_desc),
                task, tools, prior,
            )

        elif agent_type == "review":
            yield f"**Routing to:** Code Review Agent ({self.valves.review_model})\n"
            yield f"**Task:** {task}\n\n"
            yield "---\n\n## Code Review Agent\n\n"
            yield from self._run_agent(
                "Review", self.valves.review_model,
                REVIEW_SYSTEM_PROMPT.format(tools=tool_desc),
                task, tools, prior,
            )

        elif agent_type == "full":
            yield f"**Running full pipeline:** SWE -> QA -> Review\n"
            yield f"**Task:** {task}\n\n"

            # Phase 1: SWE builds it
            yield "---\n\n## Phase 1: SWE Agent -- Build\n\n"
            swe_output = []
            for chunk in self._run_agent(
                "SWE", self.valves.swe_model,
                SWE_SYSTEM_PROMPT.format(tools=tool_desc),
                task, tools, prior,
            ):
                swe_output.append(chunk)
                yield chunk

            # Phase 2: QA tests it
            yield "\n\n---\n\n## Phase 2: QA Agent -- Test\n\n"
            qa_context = [{
                "role": "assistant",
                "content": "".join(swe_output),
            }]
            for chunk in self._run_agent(
                "QA", self.valves.qa_model,
                QA_SYSTEM_PROMPT.format(tools=tool_desc),
                f"The SWE agent just built the following. Test it thoroughly and find any bugs:\n\n{task}",
                tools, qa_context,
            ):
                yield chunk

            # Phase 3: Review checks it
            yield "\n\n---\n\n## Phase 3: Code Review Agent -- Review\n\n"
            for chunk in self._run_agent(
                "Review", self.valves.review_model,
                REVIEW_SYSTEM_PROMPT.format(tools=tool_desc),
                f"Review the code that was just built and tested for the task: {task}\nList the files and review them.",
                tools, [],
            ):
                yield chunk

            yield "\n\n---\n\n## Pipeline Complete\n\n"
            yield "All three phases (Build -> Test -> Review) are done.\n"

        else:
            yield f"**Defaulting to:** SWE Agent\n\n"
            yield from self._run_agent(
                "SWE", self.valves.swe_model,
                SWE_SYSTEM_PROMPT.format(tools=tool_desc),
                task, tools, prior,
            )
