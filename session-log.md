# Claude Code on Databricks Serverless SSH: Persistence & Python Package Management

*Session date: 2026-04-16*
*Environment: Databricks serverless SSH (private preview), e2-dogfood staging*

---

## Table of Contents

1. [Problem Statement](#problem-statement)
2. [Environment Discovery](#environment-discovery)
3. [Part 1: Persisting Claude Code (Single User)](#part-1-persisting-claude-code-single-user)
4. [Part 2: Multi-User Solution](#part-2-multi-user-solution)
5. [Part 3: CLAUDE.md & Persistent Memory](#part-3-claudemd--persistent-memory)
6. [Part 4: Python Package Persistence with uv](#part-4-python-package-persistence-with-uv)
7. [Platform Recommendations](#platform-recommendations)

---

## Problem Statement

Databricks serverless SSH connects users to ephemeral compute. The home directory (`/home/spark-<uuid>/`) is an overlay filesystem that is **wiped on every restart**. This means:

- Claude Code (~224MB binary) must be reinstalled every session
- OAuth credentials must be re-authenticated every session
- Python packages installed via `pip`/`uv` are lost
- Node.js packages, CLI tools, and shell customizations vanish
- Even `.bashrc` is ephemeral — no automatic init on session start

The goal: make Claude Code, Python packages, and developer tooling persist across ephemeral sessions with minimal friction.

---

## Environment Discovery

### Storage Model

| Path | Filesystem | Persists? | Hardlinks? | Write Access? |
|---|---|---|---|---|
| `/home/spark-*` | overlay | **No** — wiped every restart | Yes | Yes |
| `/Workspace/Users/<email>/` | FUSE mount | **Yes** | **No** | Yes |
| `/Workspace/Shared/` | FUSE mount | **Yes** — all users | **No** | Yes |
| `/Volumes/<catalog>/<schema>/<vol>/` | FUSE mount | **Yes** — UC Volumes | **No** | Yes |
| `/local_disk0/` | local SSD | **No** | Yes | **No** (permission denied) |
| `/databricks/` | image | **No** — read-only | N/A | No |

### Key Environment Variables

```bash
DATABRICKS_HOST=https://e2-dogfood.staging.cloud.databricks.com
DATABRICKS_TOKEN=dkea...                              # session auth token
DATABRICKS_CLI_PATH=/Workspace/Users/.../.databricks/ssh-tunnel/.../databricks
VIRTUAL_ENV=/local_disk0/.ephemeral_nfs/cluster_libraries/python
```

### User Identity Resolution

The ephemeral username is `spark-<uuid>`, but the actual user email can be resolved:

```bash
# Method 1: Git config (instant, no API call)
grep email /Workspace/.proc/self/git/config | awk '{print $3}'

# Method 2: Databricks CLI
$DATABRICKS_CLI_PATH current-user me

# Method 3: SCIM API
curl -s -H "Authorization: Bearer $DATABRICKS_TOKEN" \
  "$DATABRICKS_HOST/api/2.0/preview/scim/v2/Me"
```

### Pre-installed Software

- Python 3.12.3 (~230 packages: pandas, numpy, scikit-learn, pyspark, mlflow, etc.)
- Node.js v22.9.0 at `/usr/local/bin/node`
- uv 0.7.20 at `/usr/local/bin/uv`
- Databricks CLI
- Git (configured via `/Workspace/.proc/self/git/config`)

---

## Part 1: Persisting Claude Code (Single User)

### How Claude Code Is Installed

Claude Code is a single 224MB ELF binary:

```
~/.local/bin/claude → ~/.local/share/claude/versions/2.1.110  (symlink)
~/.claude/.credentials.json                                    (OAuth tokens)
~/.claude/settings.json                                        (config)
```

All on the ephemeral overlay. The existing `init-claude.sh` ran `npm install -g` every session — slow and requires internet.

### Solution: Cache Binary + Credentials to Workspace

Created `/Workspace/Users/<email>/.claude-persist/setup-claude.sh`:

```bash
#!/bin/bash
# Usage:
#   setup-claude.sh save       # After fresh install + auth
#   setup-claude.sh restore    # Every subsequent session (~0.6s)
#   setup-claude.sh            # Auto-detect: restore or install
```

**What gets cached:**

| What | Where | Size |
|---|---|---|
| Claude Code binary | `.claude-persist/versions/2.1.110` | 224 MB |
| OAuth credentials | `.claude-persist/.credentials.json` | ~500 B |
| Settings | `.claude-persist/settings*.json` | ~500 B |

**Benchmark:**

```
Restore from Workspace cache:  0.580s (vs minutes for npm install)
```

### Workflow

```bash
# Every new session:
source /Workspace/Users/<email>/.claude-persist/setup-claude.sh

# After upgrading:
claude update
setup-claude.sh save
```

---

## Part 2: Multi-User Solution

### Architecture

```
/Workspace/Shared/.claude-code/            ← shared, all users
├── setup.sh                               ← the one script everyone runs
├── current_version                        ← "2.1.110"
└── versions/
    └── 2.1.110                            ← 224MB binary (shared)

/Workspace/Users/<email>/.claude-persist/  ← per-user, private
└── .credentials.json                      ← OAuth tokens
```

The binary is stored **once** in the shared Workspace. Each user's credentials stay in **their own** private directory. Identity is auto-detected from the git config.

### The Setup Script

Located at `/Workspace/Shared/.claude-code/setup.sh`:

| Command | Description |
|---|---|
| `setup.sh` or `setup.sh setup` | Restore Claude Code (default) |
| `setup.sh save` | Cache binary + credentials after install or re-auth |
| `setup.sh update` | Install latest version via npm and update shared cache |
| `setup.sh status` | Show cache state and install info |
| `setup.sh install` | Force fresh npm install |

### User Experience

**Any user, every session — one command:**

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

**First-time setup (one-time):**

```bash
source /Workspace/Shared/.claude-code/setup.sh    # installs fresh if no cache
claude                                              # authenticate in browser
source /Workspace/Shared/.claude-code/setup.sh save # save for next time
```

**Updating (admin action):**

```bash
source /Workspace/Shared/.claude-code/setup.sh update
# All users get the new version on their next session
```

### Identity Detection

The script resolves the current user's email (to find their Workspace directory) using three methods in priority order:

1. Parse `/Workspace/.proc/self/git/config` (instant, no API call)
2. `$DATABRICKS_CLI_PATH current-user me` (CLI call)
3. SCIM API call to `$DATABRICKS_HOST/api/2.0/preview/scim/v2/Me`

### Security Notes

- OAuth credentials (access + refresh tokens) stored in each user's private Workspace directory
- File permissions set to 600 on restore to ephemeral home
- Workspace file permissions follow Databricks workspace ACLs
- The shared binary is just an executable — no secrets

---

## Part 3: CLAUDE.md & Persistent Memory

### The Problem with Memory

Claude Code stores memory files at `$HOME/.claude/projects/<encoded-path>/memory/`. Since `$HOME` is ephemeral, all memory is lost on restart.

### Solution: Symlink Memory to Workspace

Memory files are stored persistently at:

```
/Workspace/Users/<email>/.claude/memory/
├── MEMORY.md                        ← index
├── user_databricks_pm.md            ← user profile
├── project_claude_persistence.md    ← project context
└── reference_databricks_env.md      ← environment reference
```

The setup script creates a symlink from the ephemeral path to the persistent one:

```
$HOME/.claude/projects/-Workspace-Users-...-databricks-com/memory/
  → /Workspace/Users/<email>/.claude/memory/
```

The path encoding replaces `/`, `@`, and `.` with `-`.

### CLAUDE.md Files Created

Two CLAUDE.md files were created on persistent Workspace storage:

1. **`/Workspace/Users/<email>/CLAUDE.md`** — project-level context: environment details, storage model, constraints, session startup instructions
2. **`/Workspace/Shared/.claude-code/CLAUDE.md`** — documentation for the multi-user setup: directory structure, usage, identity detection, update process

---

## Part 4: Python Package Persistence with uv

### Current Python Environment

```
Python:              3.12.3
Active venv:         /local_disk0/.ephemeral_nfs/cluster_libraries/python
                     (read-only site-packages, ephemeral)
Pre-installed:       ~230 packages (1.4 GB at /databricks/python/)
uv:                  0.7.20 (pre-installed at /usr/local/bin/uv)
User site:           disabled (ENABLE_USER_SITE = False)
```

### The Core Tension

uv's speed comes from **hardlinking** packages from its cache into the venv — a near-zero-cost operation. But **Workspace FUSE doesn't support hardlinks**, so uv falls back to full file copies, losing its primary advantage.

```bash
# Hardlink tests:
local → local:         OK
local → Workspace:     FAILED (cross-device)
Workspace → Workspace: FAILED (not implemented)
Workspace symlinks:    OK
```

### Benchmarks

Test workload: httpx + polars + duckdb (~232MB installed)

| Approach | First Session | Subsequent Sessions | Import Speed |
|---|---|---|---|
| **A. `uv sync`, venv on Workspace** | ~9.7s (copy mode) | **0s** (persists) | ~1.0s |
| **B. `uv sync`, local venv + local cache** | ~1.7s (hardlinks) | ~38ms (hardlinks) | ~0.67s |
| **C. `uv sync`, Workspace cache + local venv** | ~32s (FUSE slow) | ~32s | ~0.67s |
| **D. `pip --target` on Workspace + PYTHONPATH** | ~14s (one-time) | **0s** (persists) | ~1.8s |
| **E. Cold `uv sync` from network** | ~9s | ~9s | depends |

Key findings:

- **Option A** (venv on Workspace) is simplest — zero work on subsequent sessions, ~0.3s import penalty from FUSE
- **Option B** (local venv + hardlinks) is fastest per-session but everything is ephemeral
- **Option C** (Workspace cache) is **counterproductive** — FUSE read latency makes cache hits slower than re-downloading
- **Option D** (pip --target) is dead simple but offers no lockfile/reproducibility

### Recommended Approaches

#### For lightweight deps (< ~500MB)

**Option A — Persistent venv on Workspace.** Zero subsequent-session cost.

```bash
cd /Workspace/Users/<email>/my-project
UV_LINK_MODE=copy uv sync    # first time only
source .venv/bin/activate      # every session
```

#### For heavy deps (torch, transformers — multi-GB)

**Option B — `uv sync` to local venv each session** with `pyproject.toml` + `uv.lock` on Workspace for reproducibility.

```bash
# Project structure (on Workspace, persistent):
/Workspace/Users/<email>/my-ml-project/
├── pyproject.toml     # deps declared here
├── uv.lock            # pinned versions
└── src/               # your code

# Each session (~9s for small, 30-60s for large ML stacks):
cd /Workspace/Users/<email>/my-ml-project
uv sync
```

### Limitations of uv on Serverless

1. **No hardlinks on Workspace FUSE** — uv's biggest speed advantage doesn't work. Falls back to copy mode (100-500x slower install step).

2. **Ephemeral cache** — uv's cache at `~/.cache/uv` is lost on restart. Putting the cache on Workspace (`UV_CACHE_DIR`) is counterproductive — FUSE read latency makes cache hits slower than downloading from PyPI (~32s vs ~9s).

3. **No persistent local storage** — `/local_disk0/` is permission-denied. `$HOME` supports hardlinks but is ephemeral. No writable local storage that is both hardlink-capable and persistent.

4. **`VIRTUAL_ENV` conflict** — Databricks sets `VIRTUAL_ENV` to its cluster venv. uv warns on every `uv sync`. Harmless but noisy.

5. **Read-only site-packages** — Can't add `.pth` files or install into the Databricks venv directly. Must use a separate venv or `--target`.

6. **`include-system-site-packages = false`** — Creating your own uv venv loses access to pre-installed packages (pandas, numpy, pyspark, etc.) unless you reinstall them or set the flag.

---

## Platform Recommendations

### What Databricks Could Build

These are ranked by impact and feasibility:

#### 1. Serverless SSH Session Init Hook *(highest impact, lowest effort)*

Allow users to specify a script (e.g., `/Workspace/Users/<email>/.databricks/init.sh`) that runs automatically on session start. This would make the `source setup.sh` step invisible.

- Solves Claude Code persistence, Python env setup, shell customizations, and any other tooling
- Equivalent to cluster init scripts but for serverless SSH

#### 2. Persistent `.bashrc` / Shell Profile

Even just sourcing a Workspace-based profile file would let users add `source /Workspace/Shared/.claude-code/setup.sh` once and forget about it. The ephemeral `.bashrc` is arguably the root cause of all these workarounds.

#### 3. Writable Persistent Local Volume

A persistent, hardlink-capable mount (e.g., `/local_disk0/persistent/`) would let uv's cache and hardlinks work at full speed across sessions. This is the single biggest improvement for non-Python tooling too.

#### 4. Pre-warmed uv Cache in the Serverless Image

Ship popular PyPI packages pre-cached. `uv sync` from a local cache with hardlinks takes **38ms** vs **9s** from network.

#### 5. Environment Templates

Admin-configurable lists of non-Python tools to pre-install on serverless images (or restore from cache on attach). Think: `claude-code`, `gh`, `terraform`, `uv` (already done), etc.

#### 6. `UV_CACHE_DIR` / `UV_LINK_MODE` as Cluster/Workspace Config

Let admins configure these at the workspace or cluster policy level so users don't need to set env vars manually.

---

## Files Created

| File | Location | Purpose |
|---|---|---|
| `setup-claude.sh` | `/Workspace/Users/<email>/.claude-persist/` | Per-user Claude Code persistence (original) |
| `setup.sh` | `/Workspace/Shared/.claude-code/` | Multi-user Claude Code persistence |
| `CLAUDE.md` | `/Workspace/Users/<email>/` | Project-level Claude Code context |
| `CLAUDE.md` | `/Workspace/Shared/.claude-code/` | Multi-user setup documentation |
| `MEMORY.md` + memory files | `/Workspace/Users/<email>/.claude/memory/` | Persistent Claude Code memory |
| `init-claude.sh` | `/Workspace/Users/<email>/.claude/` | Updated wrapper (delegates to shared script) |
