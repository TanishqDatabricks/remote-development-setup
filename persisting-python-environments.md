# Persisting Developer Environments on Databricks Serverless Compute

This guide covers how to persist Python packages, CLI tools, and developer tooling across ephemeral Databricks serverless sessions.

---

## Before you begin: which serverless experience are you using?

Databricks serverless compute comes in several forms, and dependency management works differently in each:

| Serverless compute type | Dependency management | Persistence |
|---|---|---|
| **Serverless notebooks** | Environment side panel (UI) | Automatic — Databricks caches your virtual environment across sessions |
| **Serverless jobs** | Job-level environment configuration | Automatic — configured per task |
| **Serverless SSH (terminal access)** | Manual — no built-in mechanism | **Not automatic** — this guide covers how to solve this |

### Serverless notebooks and jobs

If you're using serverless notebooks, use the **Environment side panel** to manage Python dependencies. Databricks automatically caches the notebook's virtual environment, so you generally don't need to reinstall packages when reopening an existing notebook, even after disconnection due to inactivity. See [Manage Python dependencies for serverless notebooks](https://docs.databricks.com/aws/en/compute/serverless/dependencies) for details.

### Serverless SSH (terminal access)

When you connect to serverless compute via SSH tunnel (using a local IDE like VS Code, Cursor, or a terminal), you get raw terminal access to ephemeral compute. The Environment side panel, automatic caching, and `%pip` magic commands are **not available** in this context.

The rest of this guide is for this scenario.

---

## Understanding the serverless SSH environment

### What's ephemeral vs. persistent

| Path | Persists across sessions? | Notes |
|---|---|---|
| `/home/spark-<uuid>/` | No | Home directory on overlay FS, wiped every restart. Username changes each session. |
| `/Workspace/Users/<your-email>/` | **Yes** | Your personal Workspace directory (FUSE mount). |
| `/Workspace/Shared/` | **Yes** | Shared Workspace, visible to all users in the workspace. |
| `/Volumes/<catalog>/<schema>/<volume>/` | **Yes** | Unity Catalog Volumes (FUSE mount). |
| `/local_disk0/` | No | Local SSD, ephemeral. May not be writable on serverless. |
| `~/.bashrc`, `~/.profile` | No | Shell configuration is ephemeral. |

**Anything installed via `pip`, `npm`, `apt`, or written to `$HOME` is lost on restart.**

### What's pre-installed

The serverless image includes:

- Python 3.12 with ~230 packages (pandas, numpy, scikit-learn, pyspark, mlflow, databricks-sdk, etc.)
- Node.js v22 at `/usr/local/bin/node`
- [uv](https://docs.astral.sh/uv/) (fast Python package manager) at `/usr/local/bin/uv`
- Databricks CLI at `$DATABRICKS_CLI_PATH`
- Git (configured for your Databricks identity)

### Identifying yourself at runtime

The ephemeral username is `spark-<uuid>`, not your email. To resolve your Databricks identity:

```bash
# Fast method — parses the Workspace git config (no API call):
grep email /Workspace/.proc/self/git/config | awk '{print $3}'
```

---

## Persisting Python packages

### Recommended approach: persistent venv on Workspace with uv

`uv` is pre-installed on serverless compute and is significantly faster than `pip`. The approach is:

1. Keep your project (`pyproject.toml`, `uv.lock`, `.venv`) on `/Workspace/` — it persists across sessions
2. The venv survives restarts with zero re-install time
3. Use `uv.lock` for reproducible environments

#### Initial setup (one time)

**Step 1.** Create a project directory on Workspace:

```bash
mkdir -p /Workspace/Users/<your-email>/my-project
cd /Workspace/Users/<your-email>/my-project
```

**Step 2.** Define your dependencies in `pyproject.toml`:

```toml
[project]
name = "my-project"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "httpx>=0.28",
    "polars>=1.0",
    "duckdb>=1.0",
]
```

**Step 3.** Lock and install:

```bash
uv lock                   # resolve and pin all versions
UV_LINK_MODE=copy uv sync # create .venv and install packages
```

> **Why `UV_LINK_MODE=copy`?** The Workspace filesystem (FUSE) does not support hardlinks. Without this flag, `uv` attempts hardlinks, they fail, and it falls back to copy mode with a warning. Setting `UV_LINK_MODE=copy` suppresses the warning.

> **Note:** You may see a warning about `VIRTUAL_ENV` not matching the project environment. This is harmless — Databricks sets `VIRTUAL_ENV` to its own cluster virtual environment, and `uv` is noting it's creating a separate one.

**Step 4.** Activate the venv:

```bash
source .venv/bin/activate
```

Your project directory now looks like:

```
/Workspace/Users/<your-email>/my-project/
├── pyproject.toml   # dependency declarations (persistent)
├── uv.lock          # pinned versions for reproducibility (persistent)
└── .venv/           # installed packages (persistent)
```

#### Every subsequent session

The venv already exists on Workspace. Just activate it:

```bash
cd /Workspace/Users/<your-email>/my-project
source .venv/bin/activate
```

No install step. No network required.

#### Adding or updating packages

```bash
uv add <package-name>        # adds to pyproject.toml, updates lock, installs
uv remove <package-name>     # removes
uv lock --upgrade             # update all packages to latest compatible versions
UV_LINK_MODE=copy uv sync     # re-sync after manual pyproject.toml edits
```

### Alternative: pip install --target with PYTHONPATH

If you prefer `pip` or don't need a lockfile, you can install packages to a persistent directory and add it to `PYTHONPATH`:

```bash
# One-time install:
pip install --target /Workspace/Users/<your-email>/.python-libs httpx polars duckdb

# Every session — add to Python's search path:
export PYTHONPATH="/Workspace/Users/<your-email>/.python-libs:$PYTHONPATH"
```

This is simpler but offers no version locking, no dependency resolution file, and no venv isolation.

### Tradeoffs and performance

| Approach | First session | Subsequent sessions | Runtime import overhead |
|---|---|---|---|
| **Persistent venv on Workspace (recommended)** | ~10s (downloads + copies) | **0s** (venv persists) | ~0.3s extra per import (FUSE I/O) |
| **`uv sync` each session (ephemeral venv)** | ~10s (downloads + installs) | ~10s (cache is also ephemeral) | Minimal (local I/O) |
| **`pip install --target` on Workspace** | ~15s (one-time) | **0s** (persists) | ~0.3s extra per import (FUSE I/O) |

The persistent venv approach is recommended for most workloads. The slight FUSE I/O overhead on imports (~0.3s) is negligible for interactive development and data/ML workflows.

### Important: accessing pre-installed Databricks packages

When you create your own venv with `uv`, it does **not** inherit the packages pre-installed on the serverless image (pandas, numpy, pyspark, etc.) by default. You have two options:

**Option A.** Add any needed packages to your `pyproject.toml`:

```toml
dependencies = [
    "pandas",
    "scikit-learn",
    "your-other-deps",
]
```

**Option B.** Create the venv with system site-packages access:

```bash
uv venv --system-site-packages .venv
```

This lets your venv see packages installed in the base image. However, this can lead to version conflicts if your dependencies require different versions than what's pre-installed.

---

## Persisting non-Python tools (Claude Code, CLI tools, etc.)

Non-Python tools installed via `npm`, `curl`, or other means are also lost on restart. The same principle applies: cache binaries on `/Workspace/` and restore them each session.

### Example: Claude Code

A multi-user setup script is available at `/Workspace/Shared/.claude-code/setup.sh` that:

- Stores the Claude Code binary (~224MB) once in `/Workspace/Shared/.claude-code/` (shared across all users)
- Stores each user's OAuth credentials in `/Workspace/Users/<email>/.claude-persist/` (private)
- Auto-detects the user's identity
- Restores everything in under 1 second

```bash
# Every session:
source /Workspace/Shared/.claude-code/setup.sh

# First-time setup:
source /Workspace/Shared/.claude-code/setup.sh    # installs if no cache
claude                                              # authenticate
source /Workspace/Shared/.claude-code/setup.sh save # cache for next time
```

See `/Workspace/Shared/.claude-code/CLAUDE.md` for full documentation.

### General pattern for any CLI tool

The pattern works for any binary tool:

```bash
TOOL_CACHE="/Workspace/Users/<your-email>/.tool-cache"
mkdir -p "$TOOL_CACHE"

# Save (after installing):
cp $(which <tool>) "$TOOL_CACHE/<tool>"

# Restore (each session):
mkdir -p ~/.local/bin
cp "$TOOL_CACHE/<tool>" ~/.local/bin/<tool>
chmod +x ~/.local/bin/<tool>
export PATH="$HOME/.local/bin:$PATH"
```

---

## Putting it all together: session startup script

Since `.bashrc` is ephemeral, you can't auto-run setup on login. But you can create a single startup script on Workspace that you source manually at the start of each session.

### Create a personal init script

Save this to `/Workspace/Users/<your-email>/init.sh`:

```bash
#!/bin/bash
# Personal session init script for Databricks serverless SSH
# Usage: source /Workspace/Users/<your-email>/init.sh

# Restore Claude Code (if using)
if [ -f /Workspace/Shared/.claude-code/setup.sh ]; then
    source /Workspace/Shared/.claude-code/setup.sh
fi

# Activate your Python project venv (adjust path as needed)
PROJECT_DIR="/Workspace/Users/<your-email>/my-project"
if [ -f "$PROJECT_DIR/.venv/bin/activate" ]; then
    cd "$PROJECT_DIR"
    source .venv/bin/activate
    echo "Python venv activated: $(python --version), $(which python)"
fi

# Suppress uv hardlink warnings on Workspace FUSE
export UV_LINK_MODE=copy

# Any other personal setup
# export MY_API_KEY="..."  # Consider using Databricks secrets instead
```

Then each session:

```bash
source /Workspace/Users/<your-email>/init.sh
```

---

## Limitations and known issues

### Workspace FUSE filesystem

- **No hardlink support.** `uv` and other tools that rely on hardlinks for performance must fall back to file copies. Set `UV_LINK_MODE=copy` to avoid warnings.
- **Slower I/O than local disk.** Imports and file reads from `/Workspace/` have slightly higher latency than local overlay storage. This is generally not noticeable for normal workflows.
- **File permissions.** All files on Workspace appear owned by `root` with `rwxrwxrwx` permissions. Workspace ACLs enforce access control at a higher level.

### uv-specific limitations on serverless

- **Ephemeral cache.** `uv`'s package cache at `~/.cache/uv` is lost on restart. Placing the cache on Workspace (`UV_CACHE_DIR=/Workspace/...`) is counterproductive — FUSE read latency makes cache hits slower than re-downloading from PyPI.
- **`VIRTUAL_ENV` conflict.** Databricks sets `VIRTUAL_ENV` to its cluster venv. `uv` warns about this on every `sync`. The warning is harmless.
- **No hardlinks between filesystems.** You cannot hardlink between the overlay (`$HOME`) and Workspace FUSE. This is a cross-device limitation.

### PySpark restriction

Do not install PySpark or any library that installs PySpark as a dependency in your environment. The serverless image already includes PySpark, and reinstalling it will stop your session and result in an error. If you need `pyspark` in your `pyproject.toml` for type checking or local development, mark it as optional or use a `[dev]` dependency group that you don't install on serverless.

### No automatic session init

There is currently no mechanism to run a script automatically when a serverless SSH session starts. You must manually source your init script. This differs from classic dedicated clusters, which support init scripts via the cluster configuration UI.

---

## Quick reference

| Task | Command |
|---|---|
| Create a new project | `mkdir -p /Workspace/Users/<email>/project && cd $_` |
| Define dependencies | Edit `pyproject.toml` |
| Lock versions | `uv lock` |
| Install to persistent venv | `UV_LINK_MODE=copy uv sync` |
| Activate venv (every session) | `source .venv/bin/activate` |
| Add a package | `uv add <package>` |
| Remove a package | `uv remove <package>` |
| Update all packages | `uv lock --upgrade && UV_LINK_MODE=copy uv sync` |
| Check what's installed | `uv pip list` |
