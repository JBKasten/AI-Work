"""
title: Git Operations
description: Clone repos, view diffs, check logs, create branches — integrated with Gitea.
author: AI Stack
version: 1.0.0
"""

import json
import requests
from typing import Optional


class Tools:
    def __init__(self):
        self.sandbox_url = "http://sandbox:8080"
        self.gitea_url = "http://gitea:3000"

    def git_clone_and_run(
        self,
        repo_url: str,
        command: str,
        branch: str = "",
        __event_emitter__=None,
    ) -> str:
        """
        Clone a git repository and run a command in it (e.g., tests, build, lint).

        :param repo_url: Git repository URL to clone.
        :param command: Shell command to run after cloning (e.g., "pytest -v", "npm test").
        :param branch: Optional branch to checkout.
        :return: Command output.
        """
        if __event_emitter__:
            __event_emitter__(
                {"type": "status", "data": {"description": f"Cloning and running...", "done": False}}
            )

        clone_cmd = f"git clone --depth 1"
        if branch:
            clone_cmd += f" -b {branch}"
        clone_cmd += f" {repo_url} /home/sandbox/workspace/repo"

        script = f"""
{clone_cmd} 2>&1
cd /home/sandbox/workspace/repo
echo "---CLONE DONE---"
{command} 2>&1
"""

        try:
            response = requests.post(
                f"{self.sandbox_url}/execute",
                json={"code": script, "language": "bash", "timeout": 120},
                timeout=125,
            )
            result = response.json()

            if __event_emitter__:
                __event_emitter__(
                    {"type": "status", "data": {"description": "Done", "done": True}}
                )

            output = []
            if result.get("stdout"):
                output.append(f"**Output:**\n```\n{result['stdout']}\n```")
            if result.get("stderr"):
                output.append(f"**Errors:**\n```\n{result['stderr']}\n```")
            output.append(f"**Exit code:** {result.get('exit_code', -1)}")

            return "\n\n".join(output)

        except Exception as e:
            return f"Error: {str(e)}"

    def list_gitea_repos(self, __event_emitter__=None) -> str:
        """
        List all repositories on the local Gitea server.

        :return: List of repositories with URLs.
        """
        try:
            response = requests.get(
                f"{self.gitea_url}/api/v1/repos/search?limit=50",
                timeout=10,
            )
            repos = response.json().get("data", [])

            if not repos:
                return "No repositories found on Gitea. Create one at /git/"

            lines = []
            for repo in repos:
                name = repo.get("full_name", "?")
                desc = repo.get("description", "")
                url = repo.get("clone_url", "")
                stars = repo.get("stars_count", 0)
                lines.append(f"- **{name}** — {desc}\n  Clone: `{url}`")

            return "**Gitea Repositories:**\n\n" + "\n".join(lines)

        except Exception as e:
            return f"Error connecting to Gitea: {str(e)}"
