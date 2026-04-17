# Remote Development Setup for Databricks Serverless SSH

Documentation and reference material for persisting developer environments across ephemeral Databricks serverless SSH sessions.

Created 2026-04-16.

## Files

| File | Description |
|---|---|
| [setup.sh](setup.sh) | **The script.** Deploy this to `/Workspace/Shared/.claude-code/setup.sh` on any workspace. |
| [setup-extensions.py](setup-extensions.py) | **MCP installer.** Re-applies MCP server config to `~/.claude.json` each session. Edit the `MCP_SERVERS` dict to add servers. |
| [claude-code-setup.md](claude-code-setup.md) | **User quickstart.** Exact steps to get Claude Code running in a new SSH session, including MCP setup. |
| [claude-code-multi-user-reference.md](claude-code-multi-user-reference.md) | Reference doc covering architecture, identity detection, credential persistence, deploying to a new workspace, and the productionization roadmap. |
| [persisting-python-environments.md](persisting-python-environments.md) | Guide to persisting Python packages with `uv` and persistent Workspace venvs. Covers tradeoffs between approaches and uv limitations on serverless. |
| [environment-reference.md](environment-reference.md) | CLAUDE.md project context — storage model, environment variables, constraints, and persistent memory setup. |
| [session-log.md](session-log.md) | Full log of the exploration session: environment discovery, benchmarks, all approaches tested, and platform recommendations. |

## Quick start (new session)

```bash
# 1. Restore Claude Code