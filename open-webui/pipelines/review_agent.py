"""
title: Code Review Agent
description: Autonomous code reviewer. Performs deep automated analysis — lint, security, complexity, dead code — then gives expert-level feedback.
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


SYSTEM_PROMPT = """You are an elite code review agent. You perform thorough, rigorous code reviews like a senior engineer at a top tech company.

YOUR WORKFLOW:
1. READ: Understand the code thoroughly. Read every file.
2. LINT: Run the linter to catch style issues and simple bugs.
3. ANALYZE: Run static analysis for complexity, security, and dead code.
4. TEST: If tests exist, run them. If not, note the gap.
5. REVIEW: Provide a detailed, constructive review.
6. FINISH: Deliver the final review report.

REVIEW CRITERIA (check ALL of these):

**Correctness:**
- Does the code do what it's supposed to?
- Are there off-by-one errors, null dereferences, race conditions?
- Are error cases handled?

**Security:**
- SQL injection, XSS, command injection?
- Secrets in code?
- Input validation at boundaries?

**Performance:**
- Unnecessary loops, N+1 queries, missing indexes?
- Memory leaks, unbounded growth?
- Could anything be cached?

**Maintainability:**
- Clear naming, single responsibility?
- Is the code self-documenting?
- Are there magic numbers or strings?

**Testing:**
- Are there tests? Are they comprehensive?
- Do they test edge cases?
- Is coverage adequate?

**Architecture:**
- Is the abstraction level right?
- Are dependencies reasonable?
- Is the code modular and extensible?

REVIEW FORMAT:
Use this structure for the final review:

### Summary
One paragraph overview.

### Severity: Critical
- [List of must-fix issues]

### Severity: Major
- [List of should-fix issues]

### Severity: Minor
- [List of nice-to-fix issues]

### Positive Feedback
- [What's done well]

### Verdict
APPROVE / REQUEST CHANGES / NEEDS DISCUSSION

TOOL CALLING FORMAT:
```json
{{"tool": "tool_name", "param": "value"}}
```

{tools}

IMPORTANT: You must call a tool in every response. Be thorough but efficient. Think first, then call exactly one tool."""


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
        yield "**Performing:** Lint → Security → Complexity → Expert Review\n\n"

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
            user_message=f"Review this code:\n\n{user_msg}",
            conversation=prior,
        )
