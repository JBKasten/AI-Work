"""
title: Agent Framework
description: Base framework for autonomous AI agents with ReAct loop, tool calling, and streaming output.
author: AI Stack
version: 1.0.0
"""

import json
import re
import requests
import time
from typing import Generator, Optional
from pydantic import BaseModel, Field


# ─────────────────────────────────────────────────────────────────────────────
#  Tool Registry — all tools available to agents
# ─────────────────────────────────────────────────────────────────────────────

class ToolRegistry:
    """Unified interface to all AI Stack services."""

    def __init__(self, sandbox_url: str = "http://sandbox:8080",
                 gitea_url: str = "http://gitea:3000",
                 litellm_url: str = "http://litellm:4000",
                 litellm_key: str = ""):
        self.sandbox_url = sandbox_url
        self.gitea_url = gitea_url
        self.litellm_url = litellm_url
        self.litellm_key = litellm_key

    def get_tool_descriptions(self) -> str:
        """Return tool descriptions for the system prompt."""
        return """Available tools (use EXACTLY this JSON format to call them):

1. execute_code: Run code in a sandbox
   {"tool": "execute_code", "language": "python", "code": "print('hello')"}
   Languages: python, javascript, typescript, go, rust, bash

2. run_tests: Write files and run tests
   {"tool": "run_tests", "language": "python", "files": {"solution.py": "...", "test_solution.py": "..."}}

3. lint_code: Lint and auto-fix code
   {"tool": "lint_code", "language": "python", "code": "...", "fix": true}

4. analyze_code: Static analysis (Python)
   {"tool": "analyze_code", "code": "...", "checks": ["complexity", "security", "dead_code", "types"]}

5. read_file: Read a file from workspace
   {"tool": "read_file", "path": "solution.py"}

6. write_file: Write a file to workspace
   {"tool": "write_file", "path": "solution.py", "content": "..."}

7. list_files: List files in workspace
   {"tool": "list_files", "path": "."}

8. shell: Run a shell command
   {"tool": "shell", "command": "ls -la"}

9. git_clone: Clone a repository
   {"tool": "git_clone", "url": "https://...", "branch": "main"}

10. search_code: Search for patterns in files
    {"tool": "search_code", "pattern": "def main", "path": "."}

11. finish: Signal that the task is complete
    {"tool": "finish", "summary": "Implemented feature X with tests passing."}"""

    def execute(self, tool_call: dict) -> dict:
        """Execute a tool call and return the result."""
        tool = tool_call.get("tool", "")

        try:
            if tool == "execute_code":
                return self._execute_code(tool_call)
            elif tool == "run_tests":
                return self._run_tests(tool_call)
            elif tool == "lint_code":
                return self._lint_code(tool_call)
            elif tool == "analyze_code":
                return self._analyze_code(tool_call)
            elif tool == "read_file":
                return self._read_file(tool_call)
            elif tool == "write_file":
                return self._write_file(tool_call)
            elif tool == "list_files":
                return self._list_files(tool_call)
            elif tool == "shell":
                return self._shell(tool_call)
            elif tool == "git_clone":
                return self._git_clone(tool_call)
            elif tool == "search_code":
                return self._search_code(tool_call)
            elif tool == "finish":
                return {"status": "finished", "summary": tool_call.get("summary", "")}
            else:
                return {"error": f"Unknown tool: {tool}"}
        except Exception as e:
            return {"error": f"Tool execution failed: {str(e)}"}

    def _sandbox_exec(self, code: str, language: str = "bash", timeout: int = 30) -> dict:
        resp = requests.post(
            f"{self.sandbox_url}/execute",
            json={"code": code, "language": language, "timeout": timeout},
            timeout=timeout + 5,
        )
        return resp.json()

    def _execute_code(self, call: dict) -> dict:
        resp = requests.post(
            f"{self.sandbox_url}/execute",
            json={
                "code": call.get("code", ""),
                "language": call.get("language", "python"),
                "stdin": call.get("stdin", ""),
                "timeout": call.get("timeout", 30),
            },
            timeout=35,
        )
        return resp.json()

    def _run_tests(self, call: dict) -> dict:
        resp = requests.post(
            f"{self.sandbox_url}/test",
            json={
                "files": call.get("files", {}),
                "language": call.get("language", "python"),
                "test_command": call.get("test_command", ""),
                "timeout": 60,
            },
            timeout=65,
        )
        return resp.json()

    def _lint_code(self, call: dict) -> dict:
        resp = requests.post(
            f"{self.sandbox_url}/lint",
            json={
                "code": call.get("code", ""),
                "language": call.get("language", "python"),
                "fix": call.get("fix", True),
            },
            timeout=20,
        )
        return resp.json()

    def _analyze_code(self, call: dict) -> dict:
        resp = requests.post(
            f"{self.sandbox_url}/analyze",
            json={
                "code": call.get("code", ""),
                "language": "python",
                "checks": call.get("checks", ["complexity", "security", "dead_code"]),
            },
            timeout=30,
        )
        return resp.json()

    def _read_file(self, call: dict) -> dict:
        path = call.get("path", "")
        result = self._sandbox_exec(f"cat '{path}' 2>&1", "bash", 5)
        return {"content": result.get("stdout", ""), "error": result.get("stderr", "")}

    def _write_file(self, call: dict) -> dict:
        path = call.get("path", "")
        content = call.get("content", "")
        # Use heredoc to safely write content
        script = f"mkdir -p \"$(dirname '{path}')\" && cat > '{path}' << 'AGENT_EOF'\n{content}\nAGENT_EOF"
        result = self._sandbox_exec(script, "bash", 5)
        return {"written": path, "exit_code": result.get("exit_code", -1)}

    def _list_files(self, call: dict) -> dict:
        path = call.get("path", ".")
        result = self._sandbox_exec(f"find '{path}' -type f | head -100", "bash", 5)
        return {"files": result.get("stdout", "").strip().split("\n")}

    def _shell(self, call: dict) -> dict:
        cmd = call.get("command", "")
        result = self._sandbox_exec(cmd, "bash", call.get("timeout", 30))
        return result

    def _git_clone(self, call: dict) -> dict:
        url = call.get("url", "")
        branch = call.get("branch", "")
        dest = call.get("dest", "repo")
        cmd = f"git clone --depth 1"
        if branch:
            cmd += f" -b '{branch}'"
        cmd += f" '{url}' '{dest}' 2>&1"
        result = self._sandbox_exec(cmd, "bash", 120)
        return result

    def _search_code(self, call: dict) -> dict:
        pattern = call.get("pattern", "")
        path = call.get("path", ".")
        result = self._sandbox_exec(
            f"grep -rn '{pattern}' '{path}' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.rs' 2>&1 | head -50",
            "bash", 10,
        )
        return {"matches": result.get("stdout", "")}


# ─────────────────────────────────────────────────────────────────────────────
#  ReAct Agent Loop
# ─────────────────────────────────────────────────────────────────────────────

class AgentLoop:
    """
    ReAct (Reason + Act) agent loop.

    Think → Act → Observe → repeat until finish or max steps.
    """

    def __init__(self, tools: ToolRegistry, litellm_url: str, litellm_key: str,
                 model: str = "code", max_steps: int = 15):
        self.tools = tools
        self.litellm_url = litellm_url
        self.litellm_key = litellm_key
        self.model = model
        self.max_steps = max_steps

    def call_llm(self, messages: list) -> str:
        headers = {"Content-Type": "application/json"}
        if self.litellm_key:
            headers["Authorization"] = f"Bearer {self.litellm_key}"

        resp = requests.post(
            f"{self.litellm_url}/v1/chat/completions",
            headers=headers,
            json={
                "model": self.model,
                "messages": messages,
                "temperature": 0.1,
                "max_tokens": 8192,
            },
            timeout=120,
        )
        data = resp.json()
        return data["choices"][0]["message"]["content"]

    def run(self, system_prompt: str, user_message: str,
            conversation: list = None) -> Generator[str, None, None]:
        """
        Run the agent loop. Yields markdown-formatted output for streaming.
        """
        messages = [{"role": "system", "content": system_prompt}]

        if conversation:
            messages.extend(conversation)

        messages.append({"role": "user", "content": user_message})

        for step in range(1, self.max_steps + 1):
            yield f"\n---\n### Step {step}/{self.max_steps}\n\n"

            # THINK: Ask the model what to do
            response = self.call_llm(messages)
            yield f"{response}\n\n"

            # Extract tool calls from response
            tool_calls = self._extract_tool_calls(response)

            if not tool_calls:
                # No tool call — model is done or confused
                yield "\n*No tool call detected. Agent stopping.*\n"
                return

            # ACT & OBSERVE: Execute each tool call
            for tc in tool_calls:
                tool_name = tc.get("tool", "unknown")

                if tool_name == "finish":
                    summary = tc.get("summary", "Task complete.")
                    yield f"\n### Agent Complete\n\n{summary}\n"
                    return

                yield f"**Executing:** `{tool_name}`\n\n"

                result = self.tools.execute(tc)
                result_str = self._format_result(result)

                yield f"**Result:**\n```\n{result_str}\n```\n\n"

                # Add to conversation for next iteration
                messages.append({"role": "assistant", "content": response})
                messages.append({
                    "role": "user",
                    "content": f"Tool result for {tool_name}:\n```\n{result_str}\n```\n\nContinue with the next step. If the task is complete, use the finish tool.",
                })

                # Only process first tool call per step to keep context clean
                break

        yield "\n### Max steps reached. Agent stopping.\n"

    def _extract_tool_calls(self, text: str) -> list[dict]:
        """Extract JSON tool calls from model response."""
        calls = []

        # Pattern 1: ```json blocks
        json_blocks = re.findall(r'```(?:json)?\s*\n?({.*?})\s*\n?```', text, re.DOTALL)
        for block in json_blocks:
            try:
                parsed = json.loads(block)
                if "tool" in parsed:
                    calls.append(parsed)
            except json.JSONDecodeError:
                continue

        # Pattern 2: Inline JSON with "tool" key
        if not calls:
            inline = re.findall(r'(\{[^{}]*"tool"\s*:[^{}]*\})', text, re.DOTALL)
            for match in inline:
                try:
                    parsed = json.loads(match)
                    if "tool" in parsed:
                        calls.append(parsed)
                except json.JSONDecodeError:
                    continue

        return calls

    def _format_result(self, result: dict) -> str:
        """Format a tool result for display."""
        if "error" in result and result["error"]:
            return f"ERROR: {result['error']}"

        parts = []
        if result.get("stdout"):
            parts.append(result["stdout"][:5000])
        if result.get("stderr"):
            parts.append(f"STDERR: {result['stderr'][:2000]}")
        if result.get("exit_code") is not None:
            parts.append(f"Exit code: {result['exit_code']}")
        if result.get("content"):
            parts.append(result["content"][:5000])
        if result.get("matches"):
            parts.append(result["matches"][:3000])
        if result.get("files"):
            parts.append("\n".join(result["files"][:50]))
        if result.get("written"):
            parts.append(f"Wrote: {result['written']}")
        if result.get("status") == "finished":
            parts.append(f"FINISHED: {result.get('summary', '')}")

        # Fallback: dump the dict
        if not parts:
            return json.dumps(result, indent=2)[:3000]

        return "\n".join(parts)
