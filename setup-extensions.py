#!/usr/bin/env python3
"""
Apply Claude Code MCP servers to ~/.claude.json.

MCP server config lives in ~/.claude.json, which is ephemeral on Databricks
serverless SSH. Run this script each session (after setup.sh) to reapply your
MCP config without losing it on restart.

Usage:
    python3 setup-extensions.py

Edit the MCP_SERVERS dict below to add or remove servers. Changes take effect
after restarting Claude Code.
"""

import json
import os
import subprocess
import sys


# =============================================================================
# CONFIG — edit this section
# =============================================================================

def _detect_project_dir() -> str:
    """Auto-detect the Workspace user directory from Databricks git config."""
    try:
        line = subprocess.check_output(
            ["grep", "-m1", "email", "/Workspace/.proc/self/git/config"],
            text=True, stderr=subprocess.DEVNULL,
        ).strip()
        email = line.split()[-1]
        return f"/Workspace/Users/{email}"
    except Exception:
        return ""


# Your Workspace project directory. Auto-detected on Databricks; override if needed.
PROJECT_DIR = _detect_project_dir() or "/Workspace/Users/your.email@databricks.com"

# DATABRICKS_TOKEN and DATABRICKS_HOST are always set in Databricks serverless
# SSH sessions, so tokens stay current without hardcoding.
_token = os.environ.get("DATABRICKS_TOKEN", "")
_host  = os.environ.get("DATABRICKS_HOST", "").rstrip("/")

MCP_SERVERS = {
    "databricks-sql": {
        "type": "stdio",
        "command": "npx",
        "args": [
            "mcp-remote",
            f"{_host}/api/2.0/mcp/sql",
            "--header",
            f"Authorization: Bearer {_token}",
        ],
        "env": {},
    },
    # ── Add more MCP servers below ────────────────────────────────────────────
    #
    # Remote MCP via mcp-remote proxy:
    # "my-remote-mcp": {
    #     "type": "stdio",
    #     "command": "npx",
    #     "args": [
    #         "mcp-remote",
    #         "https://my-service.example.com/api/mcp",
    #         "--header", "Authorization: Bearer <token>",
    #     ],
    #     "env": {},
    # },
    #
    # Local Python MCP server:
    # "my-local-mcp": {
    #     "type": "stdio",
    #     "command": "python3",
    #     "args": ["/Workspace/Users/you@company.com/my-mcp/server.py"],
    #     "env": {"MY_VAR": "value"},
    # },
}

# =============================================================================


def main() -> None:
    if not PROJECT_DIR or PROJECT_DIR.endswith("your.email@databricks.com"):
        print("ERROR: Could not detect project directory. Set PROJECT_DIR manually.", file=sys.stderr)
        sys.exit(1)

    path = os.path.expanduser("~/.claude.json")
    if not os.path.exists(path):
        print(f"ERROR: {path} not found — is Claude Code installed?", file=sys.stderr)
        sys.exit(1)

    with open(path) as f:
        config = json.load(f)

    servers = (config
               .setdefault("projects", {})
               .setdefault(PROJECT_DIR, {})
               .setdefault("mcpServers", {}))

    added, updated, skipped = [], [], []
    for name, cfg in MCP_SERVERS.items():
        if name not in servers:
            added.append(name)
        elif servers[name] != cfg:
            updated.append(name)
        else:
            skipped.append(name)
        servers[name] = cfg

    with open(path, "w") as f:
        json.dump(config, f, indent=2)

    for name in added:
        print(f"[+] MCP added:     {name}")
    for name in updated:
        print(f"[~] MCP updated:   {name}")
    for name in skipped:
        print(f"[=] MCP unchanged: {name}")

    if added or updated:
        print("\nRestart Claude Code for changes to take effect.")


if __name__ == "__main__":
    main()
