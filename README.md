# Remote Development Setup for Databricks Serverless SSH

Documentation and reference material for persisting developer environments across ephemeral Databricks serverless SSH sessions.

Created 2026-04-16.

## Files

| File | Description |
|---|---|
| [claude-code-setup.md](claude-code-setup.md) | **Start here.** Exact steps to get Claude Code running in a new SSH session. |
| [persisting-python-environments.md](persisting-python-environments.md) | Guide to persisting Python packages with `uv` and persistent Workspace venvs. Covers tradeoffs between approaches and uv limitations on serverless. |
| [claude-code-multi-user-reference.md](claude-code-multi-user-reference.md) | Reference doc for the shared multi-user Claude Code setup at `/Workspace/Shared/.claude-code/`. Covers architecture, identity detection, security, and update process. |
| [environment-reference.md](environment-reference.md) | CLAUDE.md project context — storage model, environment variables, constraints, and persistent memory setup. |
| [session-log.md](session-log.md) | Full log of the exploration session: environment discovery, benchmarks, all approaches tested, and platform recommendations. |

## Quick start (new session)

```bash
# 1. Restore Claude Code (~0.6s)
source /Workspace/Shared/.claude-code/setup.sh

# 2. (Optional) Activate a persistent Python venv
source /Workspace/Users/<your-email>/my-project/.venv/bin/activate

# 3. Work
claude
```
