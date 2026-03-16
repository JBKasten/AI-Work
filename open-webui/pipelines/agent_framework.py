"""
title: Agent Framework
description: Base framework for autonomous AI agents with ReAct loop, tool calling, and streaming output.
author: AI Stack
version: 1.1.0
"""

import base64
import json
import re
import requests
import time
from typing import Dict, Generator, List, Optional
from pydantic import BaseModel, Field


# ─────────────────────────────────────────────────────────────────────────────
#  System Prompts — shared by agents and orchestrator
# ─────────────────────────────────────────────────────────────────────────────

SWE_SYSTEM_PROMPT = """You are an elite autonomous software engineer agent. You solve coding problems end-to-end with zero hand-holding.

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
{{"tool": "tool_name", "param": "value"}}
```

{tools}

IMPORTANT: You must call a tool in every response. Think step by step, then call exactly one tool."""


QA_SYSTEM_PROMPT = """You are an elite QA engineer agent. Your job is to find bugs, write tests, and ensure code quality.

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


REVIEW_SYSTEM_PROMPT = """You are an elite code review agent. You perform thorough, rigorous code reviews like a senior engineer at a top tech company.

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
            dispatch = {
                "execute_code": self._execute_code,
                "run_tests": self._run_tests,
                "lint_code": self._lint_code,
                "analyze_code": self._analyze_code,
                "read_file": self._read_file,
                "write_file": self._write_file,
                "list_files": self._list_files,
                "shell": self._shell,
                "git_clone": self._git_clone,
                "search_code": self._search_code,
            }

            if tool == "finish":
                return {"status": "finished", "summary": tool_call.get("summary", "")}
            elif tool in dispatch:
                return dispatch[tool](tool_call)
            else:
                return {"error": f"Unknown tool: {tool}"}
        except requests.ConnectionError as e:
            return {"error": f"Service unavailable ({tool}): cannot reach backend. Is the sandbox running?"}
        except requests.Timeout:
            return {"error": f"Timeout: {tool} took too long to respond."}
        except Exception as e:
            return {"error": f"Tool execution failed: {str(e)}"}

    def _sandbox_post(self, endpoint: str, payload: dict, timeout: int = 35) -> dict:
        """POST to sandbox with error handling."""
        resp = requests.post(
            f"{self.sandbox_url}/{endpoint}",
            json=payload,
            timeout=timeout,
        )
        resp.raise_for_status()
        return resp.json()

    def _execute_code(self, call: dict) -> dict:
        return self._sandbox_post("execute", {
            "code": call.get("code", ""),
            "language": call.get("language", "python"),
            "stdin": call.get("stdin", ""),
            "timeout": call.get("timeout", 30),
        }, timeout=35)

    def _run_tests(self, call: dict) -> dict:
        return self._sandbox_post("test", {
            "files": call.get("files", {}),
            "language": call.get("language", "python"),
            "test_command": call.get("test_command", ""),
            "timeout": 60,
        }, timeout=65)

    def _lint_code(self, call: dict) -> dict:
        return self._sandbox_post("lint", {
            "code": call.get("code", ""),
            "language": call.get("language", "python"),
            "fix": call.get("fix", True),
        }, timeout=20)

    def _analyze_code(self, call: dict) -> dict:
        return self._sandbox_post("analyze", {
            "code": call.get("code", ""),
            "language": "python",
            "checks": call.get("checks", ["complexity", "security", "dead_code"]),
        }, timeout=30)

    def _read_file(self, call: dict) -> dict:
        """Read a file via execute_code to avoid shell injection."""
        path = call.get("path", "")
        # Use Python to read files safely — no shell injection possible
        code = f"import sys\ntry:\n    print(open({path!r}).read())\nexcept Exception as e:\n    print(f'Error: {{e}}', file=sys.stderr)"
        result = self._sandbox_post("execute", {
            "code": code, "language": "python", "timeout": 5,
        }, timeout=10)
        return {"content": result.get("stdout", ""), "error": result.get("stderr", "")}

    def _write_file(self, call: dict) -> dict:
        """Write a file via execute_code to avoid shell injection."""
        path = call.get("path", "")
        content = call.get("content", "")
        # Use Python to write files safely — base64 to avoid any escaping issues
        b64 = base64.b64encode(content.encode()).decode()
        code = (
            f"import base64, os, sys\n"
            f"path = {path!r}\n"
            f"data = base64.b64decode({b64!r})\n"
            f"os.makedirs(os.path.dirname(path) or '.', exist_ok=True)\n"
            f"with open(path, 'wb') as f:\n"
            f"    f.write(data)\n"
            f"print(f'Wrote {{len(data)}} bytes to {{path}}')"
        )
        result = self._sandbox_post("execute", {
            "code": code, "language": "python", "timeout": 5,
        }, timeout=10)
        exit_code = result.get("exit_code", -1)
        return {"written": path, "exit_code": exit_code, "stdout": result.get("stdout", ""), "stderr": result.get("stderr", "")}

    def _list_files(self, call: dict) -> dict:
        """List files via Python os.walk — no shell injection."""
        path = call.get("path", ".")
        code = (
            f"import os\n"
            f"for root, dirs, files in os.walk({path!r}):\n"
            f"    for f in sorted(files)[:200]:\n"
            f"        print(os.path.join(root, f))\n"
        )
        result = self._sandbox_post("execute", {
            "code": code, "language": "python", "timeout": 5,
        }, timeout=10)
        stdout = result.get("stdout", "").strip()
        return {"files": stdout.split("\n") if stdout else []}

    def _shell(self, call: dict) -> dict:
        """Execute a shell command in the sandbox."""
        cmd = call.get("command", "")
        return self._sandbox_post("execute", {
            "code": cmd, "language": "bash", "timeout": call.get("timeout", 30),
        }, timeout=call.get("timeout", 30) + 5)

    def _git_clone(self, call: dict) -> dict:
        url = call.get("url", "")
        branch = call.get("branch", "")
        dest = call.get("dest", "repo")
        # Use Python subprocess to avoid shell injection
        code = (
            f"import subprocess, sys\n"
            f"cmd = ['git', 'clone', '--depth', '1']\n"
            f"branch = {branch!r}\n"
            f"if branch:\n"
            f"    cmd += ['-b', branch]\n"
            f"cmd += [{url!r}, {dest!r}]\n"
            f"r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)\n"
            f"print(r.stdout)\n"
            f"if r.stderr:\n"
            f"    print(r.stderr, file=sys.stderr)\n"
            f"sys.exit(r.returncode)"
        )
        return self._sandbox_post("execute", {
            "code": code, "language": "python", "timeout": 120,
        }, timeout=125)

    def _search_code(self, call: dict) -> dict:
        """Search files using Python — no shell injection."""
        pattern = call.get("pattern", "")
        path = call.get("path", ".")
        code = (
            f"import os, re\n"
            f"pattern = re.compile({pattern!r})\n"
            f"exts = {{'.py', '.js', '.ts', '.go', '.rs', '.jsx', '.tsx'}}\n"
            f"count = 0\n"
            f"for root, dirs, files in os.walk({path!r}):\n"
            f"    for fname in sorted(files):\n"
            f"        if os.path.splitext(fname)[1] in exts:\n"
            f"            fpath = os.path.join(root, fname)\n"
            f"            try:\n"
            f"                for i, line in enumerate(open(fpath), 1):\n"
            f"                    if pattern.search(line):\n"
            f"                        print(f'{{fpath}}:{{i}}: {{line.rstrip()}}')\n"
            f"                        count += 1\n"
            f"                        if count >= 50:\n"
            f"                            raise SystemExit\n"
            f"            except (UnicodeDecodeError, PermissionError):\n"
            f"                pass\n"
        )
        result = self._sandbox_post("execute", {
            "code": code, "language": "python", "timeout": 10,
        }, timeout=15)
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

        try:
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
            resp.raise_for_status()
            data = resp.json()
            return data["choices"][0]["message"]["content"]
        except requests.ConnectionError:
            return '{"tool": "finish", "summary": "ERROR: Cannot reach LLM service. Is LiteLLM running?"}'
        except requests.Timeout:
            return '{"tool": "finish", "summary": "ERROR: LLM request timed out after 120s."}'
        except (KeyError, IndexError) as e:
            return f'{{"tool": "finish", "summary": "ERROR: Unexpected LLM response: {e}"}}'

    def run(self, system_prompt: str, user_message: str,
            conversation: Optional[list] = None) -> Generator[str, None, None]:
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

            # ACT & OBSERVE: Execute first tool call
            tc = tool_calls[0]
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

        yield "\n### Max steps reached. Agent stopping.\n"

    def _extract_tool_calls(self, text: str) -> List[dict]:
        """Extract JSON tool calls from model response."""
        calls = []

        # Pattern 1: ```json blocks — use a balanced-braces approach
        json_blocks = re.findall(r'```(?:json)?\s*\n?((?:\{(?:[^{}]|\{(?:[^{}]|\{[^{}]*\})*\})*\}))\s*\n?```', text, re.DOTALL)
        for block in json_blocks:
            try:
                parsed = json.loads(block)
                if "tool" in parsed:
                    calls.append(parsed)
            except json.JSONDecodeError:
                continue

        # Pattern 2: Try to find any JSON object with "tool" key
        if not calls:
            # Find potential JSON by looking for balanced braces
            for match in re.finditer(r'\{', text):
                start = match.start()
                depth = 0
                end = start
                for i in range(start, min(start + 10000, len(text))):
                    if text[i] == '{':
                        depth += 1
                    elif text[i] == '}':
                        depth -= 1
                        if depth == 0:
                            end = i + 1
                            break
                if end > start:
                    candidate = text[start:end]
                    try:
                        parsed = json.loads(candidate)
                        if isinstance(parsed, dict) and "tool" in parsed:
                            calls.append(parsed)
                            break  # Take first valid match
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
            parts.append("\n".join(str(f) for f in result["files"][:50]))
        if result.get("written"):
            parts.append(f"Wrote: {result['written']}")
        if result.get("status") == "finished":
            parts.append(f"FINISHED: {result.get('summary', '')}")

        # Fallback: dump the dict
        if not parts:
            return json.dumps(result, indent=2)[:3000]

        return "\n".join(parts)
