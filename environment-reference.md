# Claude Code on Databricks Serverless SSH

## Environment

This is a Databricks Workspace accessed via serverless SSH tunnel (private preview).
The user is tanishq.maheshwari@databricks.com, a Databricks PM.

### Storage model

| Path | Filesystem | Persists across sessions? |
|---|---|---|
| `/home/spark-*` | overlay (ephemeral) | No — wiped every restart |
| `/Workspace/Users/<email>/` | FUSE (workspace) | Yes |
| `/Workspace/Shared/` | FUSE (workspace) | Yes — shared across all users |
| `/Volumes/<catalog>/<schema>/<volume>/` | FUSE (UC volumes) | Yes |
| `/local_disk0/` | local SSD | No |

The home directory path changes every session (the `spark-<uuid>` username is regenerated).
Anything installed via `apt`, `npm install -g`, `pip install`, or written to `$HOME` is lost on restart.

### What's pre-installed

- Python 3 (Databricks runtime)
- Node.js v22.9.0 at `/usr/local/bin/node` — **x86_64 only**; unusable on arm64 nodes
- Databricks CLI at `$DATABRICKS_CLI_PATH`
- Git (configured via `/Workspace/.proc/self/git/config`)
- Spark, Java, conda, mlflow

> **arm64 note (Apr 2026):** Serverless compute switched to aarch64. The pre-installed Node.js and Claude Code binary are both x86_64 and will fail with "Exec format error". Use `source /Workspace/Shared/.claude-code/setup.sh` which handles this automatically. A working arm64 Node.js v22.14.0 is cached at `/Workspace/Shared/.claude-code/arm64/node`.

### Available environment variables

- `DATABRICKS_HOST` — workspace URL (e.g., `https://e2-dogfood.staging.cloud.databricks.com`)
- `DATABRICKS_TOKEN` — session auth token
- `DATABRICKS_CLI_PATH` — path to Databricks CLI binary
- User email: `grep email /Workspace/.proc/self/git/config | awk '{print $3}'`

### Constraints

- No `sudo` or write access to `/etc/`
- No init script hook for serverless SSH (unlike dedicated clusters)
- `.bashrc` is ephemeral — shell customizations don't survive restarts
- Non-Python packages must be reinstalled or restored from persistent storage each session

## Claude Code persistence setup

Claude Code and its auth credentials are persisted across ephemeral sessions using a caching mechanism.

### Shared (all users)

- **Script**: `/Workspace/Shared/.claude-code/setup.sh`
- **x86_64 binary cache**: `/Workspace/Shared/.claude-code/versions/<version>`
- **arm64 Node.js binary**: `/Workspace/Shared/.claude-code/arm64/node`
- **arm64 package cache**: `/Workspace/Shared/.claude-code/arm64/versions/<version>.tar.gz`
- Restore time: ~0.9 seconds (both architectures)

### Per-user (your private data)

- **Credentials**: `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/.credentials.json`
- **Settings**: `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/settings*.json`

### Session startup

Run this at the start of every new SSH session:

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

### After updating Claude Code

```bash
source /Workspace/Shared/.claude-code/setup.sh update
```

### After re-authenticating

```bash
source /Workspace/Shared/.claude-code/setup.sh save
```

## Working with this repo

This is a Workspace user directory, not a git repository. Files here are personal workspace files — notebooks, dashboards, DABs projects, etc. There is no git history or branch structure at this level.

## Memory

Claude Code memory files are stored persistently in `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/memory/`. The setup script (`/Workspace/Shared/.claude-code/setup.sh`) symlinks the ephemeral `$HOME/.claude/projects/.../memory/` path to this persistent location, so memory survives session restarts.

If memory is missing after a restart, ensure you ran `source /Workspace/Shared/.claude-code/setup.sh` — it recreates the symlink.
