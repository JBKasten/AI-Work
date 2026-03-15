"""
Code Sandbox API Server

Provides a REST API for safe code execution, testing, linting, and analysis.
Designed to be called by Open WebUI tools or LLM agents.

Endpoints:
    POST /execute    — Run code in any supported language
    POST /test       — Run test suite (pytest, jest, go test, cargo test)
    POST /lint       — Lint/format code (ruff, eslint, clippy)
    POST /analyze    — Static analysis (complexity, security, dead code)
    GET  /health     — Health check
    GET  /languages  — List supported languages and tools
"""

import asyncio
import json
import os
import shutil
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
import uvicorn

app = FastAPI(title="Code Sandbox", version="1.0.0")

WORKSPACE = Path("/home/sandbox/workspace")
TIMEOUT_DEFAULT = 30
TIMEOUT_MAX = 120


class ExecuteRequest(BaseModel):
    code: str
    language: str = "python"
    filename: Optional[str] = None
    stdin: Optional[str] = None
    timeout: int = Field(default=TIMEOUT_DEFAULT, le=TIMEOUT_MAX)
    args: list[str] = Field(default_factory=list)


class TestRequest(BaseModel):
    files: dict[str, str]  # filename -> content
    language: str = "python"
    test_command: Optional[str] = None
    timeout: int = Field(default=60, le=TIMEOUT_MAX)


class LintRequest(BaseModel):
    code: str
    language: str = "python"
    filename: Optional[str] = None
    fix: bool = False


class AnalyzeRequest(BaseModel):
    code: str
    language: str = "python"
    checks: list[str] = Field(
        default_factory=lambda: ["complexity", "security", "dead_code"]
    )


class ExecutionResult(BaseModel):
    stdout: str
    stderr: str
    exit_code: int
    duration_ms: int
    timed_out: bool = False


def _run(cmd: list[str], timeout: int, cwd: str, stdin: Optional[str] = None,
         env: Optional[dict] = None) -> ExecutionResult:
    """Run a command with timeout and resource limits."""
    start = time.monotonic()
    run_env = {**os.environ, **(env or {})}

    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            cwd=cwd,
            input=stdin,
            env=run_env,
        )
        duration = int((time.monotonic() - start) * 1000)
        return ExecutionResult(
            stdout=result.stdout[:50_000],
            stderr=result.stderr[:50_000],
            exit_code=result.returncode,
            duration_ms=duration,
        )
    except subprocess.TimeoutExpired:
        duration = int((time.monotonic() - start) * 1000)
        return ExecutionResult(
            stdout="",
            stderr=f"Execution timed out after {timeout}s",
            exit_code=124,
            duration_ms=duration,
            timed_out=True,
        )


LANGUAGE_CONFIG = {
    "python": {
        "ext": ".py",
        "run": ["python", "{file}"],
        "test": ["python", "-m", "pytest", "-v", "--tb=short", "--co", "-q"],
        "test_run": ["python", "-m", "pytest", "-v", "--tb=short"],
        "lint": ["ruff", "check", "--output-format=json", "{file}"],
        "fix": ["ruff", "check", "--fix", "{file}"],
        "format": ["ruff", "format", "{file}"],
    },
    "javascript": {
        "ext": ".js",
        "run": ["node", "{file}"],
        "test": ["npx", "jest", "--verbose"],
        "lint": ["npx", "eslint", "--format=json", "{file}"],
        "fix": ["npx", "eslint", "--fix", "{file}"],
    },
    "typescript": {
        "ext": ".ts",
        "run": ["npx", "ts-node", "{file}"],
        "test": ["npx", "jest", "--verbose"],
        "lint": ["npx", "eslint", "--format=json", "{file}"],
        "fix": ["npx", "eslint", "--fix", "{file}"],
    },
    "go": {
        "ext": ".go",
        "run": ["go", "run", "{file}"],
        "test": ["go", "test", "-v", "./..."],
        "lint": ["go", "vet", "./..."],
    },
    "rust": {
        "ext": ".rs",
        "compile": ["rustc", "-o", "{out}", "{file}"],
        "run_compiled": ["{out}"],
        "test": ["cargo", "test", "--", "--nocapture"],
        "lint": ["cargo", "clippy", "--message-format=json"],
    },
    "bash": {
        "ext": ".sh",
        "run": ["bash", "{file}"],
        "lint": ["shellcheck", "--format=json", "{file}"],
    },
}


@app.post("/execute", response_model=ExecutionResult)
async def execute(req: ExecuteRequest):
    """Execute code in any supported language."""
    lang = LANGUAGE_CONFIG.get(req.language)
    if not lang:
        raise HTTPException(400, f"Unsupported language: {req.language}")

    with tempfile.TemporaryDirectory(dir=str(WORKSPACE)) as tmpdir:
        filename = req.filename or f"main{lang['ext']}"
        filepath = Path(tmpdir) / filename
        filepath.write_text(req.code)

        if req.language == "rust" and "compile" in lang:
            out = Path(tmpdir) / "main"
            compile_cmd = [c.replace("{file}", str(filepath)).replace("{out}", str(out))
                          for c in lang["compile"]]
            compile_result = _run(compile_cmd, req.timeout, tmpdir)
            if compile_result.exit_code != 0:
                return compile_result
            run_cmd = [str(out)] + req.args
        else:
            run_cmd = [c.replace("{file}", str(filepath)) for c in lang["run"]]
            run_cmd += req.args

        return _run(run_cmd, req.timeout, tmpdir, stdin=req.stdin)


@app.post("/test", response_model=ExecutionResult)
async def run_tests(req: TestRequest):
    """Write files and run test suite."""
    lang = LANGUAGE_CONFIG.get(req.language)
    if not lang:
        raise HTTPException(400, f"Unsupported language: {req.language}")

    with tempfile.TemporaryDirectory(dir=str(WORKSPACE)) as tmpdir:
        # Write all files
        for name, content in req.files.items():
            fpath = Path(tmpdir) / name
            fpath.parent.mkdir(parents=True, exist_ok=True)
            fpath.write_text(content)

        # Determine test command
        if req.test_command:
            cmd = req.test_command.split()
        elif "test_run" in lang:
            cmd = lang["test_run"]
        elif "test" in lang:
            cmd = lang["test"]
        else:
            raise HTTPException(400, f"No test runner for {req.language}")

        # For Python, ensure pytest can find the files
        env = {}
        if req.language == "python":
            env["PYTHONPATH"] = tmpdir

        return _run(cmd, req.timeout, tmpdir, env=env)


@app.post("/lint")
async def lint(req: LintRequest):
    """Lint or format code."""
    lang = LANGUAGE_CONFIG.get(req.language)
    if not lang:
        raise HTTPException(400, f"Unsupported language: {req.language}")
    if "lint" not in lang and "fix" not in lang:
        raise HTTPException(400, f"No linter for {req.language}")

    with tempfile.TemporaryDirectory(dir=str(WORKSPACE)) as tmpdir:
        filename = req.filename or f"main{lang['ext']}"
        filepath = Path(tmpdir) / filename
        filepath.write_text(req.code)

        results = {}

        # Run linter
        if "lint" in lang:
            lint_cmd = [c.replace("{file}", str(filepath)) for c in lang["lint"]]
            results["lint"] = _run(lint_cmd, 15, tmpdir)

        # Auto-fix if requested
        if req.fix and "fix" in lang:
            fix_cmd = [c.replace("{file}", str(filepath)) for c in lang["fix"]]
            _run(fix_cmd, 15, tmpdir)

            if "format" in lang:
                fmt_cmd = [c.replace("{file}", str(filepath)) for c in lang["format"]]
                _run(fmt_cmd, 15, tmpdir)

            results["fixed_code"] = filepath.read_text()

        return results


@app.post("/analyze")
async def analyze(req: AnalyzeRequest):
    """Run static analysis: complexity, security, dead code."""
    if req.language != "python":
        raise HTTPException(400, "Analysis currently supports Python only")

    with tempfile.TemporaryDirectory(dir=str(WORKSPACE)) as tmpdir:
        filepath = Path(tmpdir) / "main.py"
        filepath.write_text(req.code)

        results = {}

        if "complexity" in req.checks:
            # Radon cyclomatic complexity
            r = _run(["radon", "cc", "-j", str(filepath)], 15, tmpdir)
            results["complexity"] = r

            # Radon maintainability index
            r = _run(["radon", "mi", "-j", str(filepath)], 15, tmpdir)
            results["maintainability"] = r

        if "security" in req.checks:
            r = _run(["bandit", "-f", "json", "-r", str(filepath)], 15, tmpdir)
            results["security"] = r

        if "dead_code" in req.checks:
            r = _run(["vulture", str(filepath)], 15, tmpdir)
            results["dead_code"] = r

        if "types" in req.checks:
            r = _run(["mypy", "--no-error-summary", str(filepath)], 15, tmpdir)
            results["type_check"] = r

        return results


@app.get("/health")
async def health():
    return {"status": "ok", "languages": list(LANGUAGE_CONFIG.keys())}


@app.get("/languages")
async def languages():
    """List supported languages and available tools."""
    info = {}
    for name, config in LANGUAGE_CONFIG.items():
        info[name] = {
            "extension": config["ext"],
            "can_execute": "run" in config or "compile" in config,
            "can_test": "test" in config,
            "can_lint": "lint" in config,
            "can_fix": "fix" in config,
        }
    return info


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8080, log_level="info")
