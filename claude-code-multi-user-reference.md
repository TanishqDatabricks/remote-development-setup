# Claude Code for Databricks — Shared Setup

This directory contains the multi-user Claude Code persistence layer for Databricks serverless SSH sessions.

## Problem

Databricks serverless compute is ephemeral. The home directory (`/home/spark-*`) is an overlay filesystem wiped on every restart. Claude Code, its OAuth credentials, and settings must be reinstalled and re-authenticated each session.

An additional complication: as of April 2026, Databricks serverless switched to **aarch64 (ARM64)** hardware. The pre-installed Node.js at `/usr/local/bin/node` and the pre-built Claude Code standalone binary are both x86_64, causing "Exec format error" on ARM64 nodes.

## Solution

Cache both x86_64 and arm64 artifacts in shared Workspace storage; credentials in each user's private Workspace directory. Restore takes ~0.9 seconds with no internet required on either architecture.

## Directory structure

```
/Workspace/Shared/.claude-code/              # Shared, all users
├── setup.sh                                 # The setup script
├── current_version                          # e.g., "2.1.112"  (x86_64)
├── versions/
│   └── <version>                            # x86_64 standalone ELF binary (~224MB)
└── arm64/
    ├── current_version                      # e.g., "2.1.112"  (arm64)
    ├── node                                 # ARM64 Node.js v22.14.0 binary (~110MB)
    └── versions/
        └── <version>.tar.gz                 # arm64 claude-code npm package (~27MB compressed)

/Workspace/Users/<email>/.claude-persist/    # Per-user, private
├── .credentials.json                        # OAuth access + refresh tokens (symlinked from ~/.claude/)
├── settings.json                            # Claude Code settings
└── settings.local.json                      # Local overrides

/Workspace/Users/<email>/.claude/            # Per-user, private
├── memory/                                  # Claude Code memory (symlinked from ~/.claude/projects/.../memory/)
└── plugins/                                 # Installed plugins (symlinked from ~/.claude/plugins/)
```

### Why arm64 uses a different approach

The Claude Code release binary is x86_64-only. On arm64, `@anthropic-ai/claude-code` is a Node.js package (JavaScript), so it requires a working Node.js to run. The pre-installed Node.js on Databricks is also x86_64. The setup script:

1. Caches an arm64 Node.js binary in shared storage (downloaded from nodejs.org once)
2. Caches the claude-code npm package as a tarball in shared storage
3. On restore: copies node to `/tmp/claude-arm64-node`, extracts the package to `/tmp/claude-arm64-pkg/`, and writes a wrapper at `~/.local/bin/claude`:

```bash
#!/bin/bash
exec "/tmp/claude-arm64-node" "/tmp/claude-arm64-pkg/cli.js" "$@"
```

Using `/tmp` (not Workspace FUSE) avoids symlink/permission issues with the FUSE filesystem during extraction.

## Usage

### Every session (all users)

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

Auto-detects the user via `/Workspace/.proc/self/git/config`, restores the shared binary, and loads user-specific credentials.

### First-time user

```bash
source /Workspace/Shared/.claude-code/setup.sh    # installs if no cache exists
claude                                              # authenticate in browser
source /Workspace/Shared/.claude-code/setup.sh save # save credentials for next time
```

### Commands

| Command | Description |
|---|---|
| `setup.sh` or `setup.sh setup` | Restore Claude Code (default) |
| `setup.sh save` | Cache binary + credentials after install or re-auth |
| `setup.sh update` | Install latest version via npm and update shared cache |
| `setup.sh status` | Show cache state and install info |
| `setup.sh install` | Force fresh npm install |
| `setup.sh help` | Show usage |

## How identity detection works

The script resolves the current user's email (needed to find their Workspace directory) using three methods in priority order:

1. Parse `/Workspace/.proc/self/git/config` (instant, no API call)
2. `databricks current-user me` via the Databricks CLI
3. SCIM API call to `$DATABRICKS_HOST/api/2.0/preview/scim/v2/Me`

## Credential persistence

Credentials are **symlinked** (not copied) from `~/.claude/.credentials.json` to the persistent Workspace path at `.claude-persist/.credentials.json`. This means OAuth token refreshes that Claude Code performs during a session write directly to persistent storage — no manual `save` step required between sessions. Re-authentication should only be needed if the refresh token itself expires (after a long period of inactivity).

Similarly, `~/.claude/plugins/` is symlinked to `/Workspace/Users/<email>/.claude/plugins/`, so installed plugins persist automatically.

## Security notes

- OAuth credentials (access + refresh tokens) are stored in each user's private Workspace directory at `/Workspace/Users/<email>/.claude-persist/.credentials.json`
- File permissions are set to 600 on the symlink target
- Workspace file permissions follow Databricks workspace ACLs
- The shared binary is just the Claude Code ELF executable — no secrets

## Updating

When a new Claude Code version is released, any user can run:

```bash
source /Workspace/Shared/.claude-code/setup.sh update
```

This updates the shared binary cache. All users get the new version on their next `setup.sh` invocation.

---

## Deploying to a new workspace

These steps bootstrap the entire system from scratch in a workspace that doesn't have it yet. You need SSH access and internet connectivity (or access to an existing workspace you can copy artifacts from).

### Step 1: Deploy the setup script

SSH into any session on the target workspace, then:

```bash
mkdir -p /Workspace/Shared/.claude-code
# Copy setup.sh from this repo, another workspace, or paste it directly
cp /path/to/setup.sh /Workspace/Shared/.claude-code/setup.sh
chmod +x /Workspace/Shared/.claude-code/setup.sh
```

### Step 2: Populate the shared binary cache

```bash
source /Workspace/Shared/.claude-code/setup.sh install
```

This installs Claude Code via npm (requires internet) and detects the architecture. Takes ~2 minutes on first run. Then save the binary to the shared cache:

```bash
source /Workspace/Shared/.claude-code/setup.sh save
```

The shared cache is now populated. Subsequent users on this workspace restore in ~0.9 seconds with no internet.

### Step 3: Authenticate (first user)

```bash
claude                                               # opens browser OAuth flow
source /Workspace/Shared/.claude-code/setup.sh save  # persist your credentials
```

### Step 4: Additional users

Each new user on the workspace runs the same one-liner:

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

If no credentials exist for them yet, Claude Code will prompt for authentication on first `claude` launch. They then run `save` once to persist their credentials. Every subsequent session is just the one-liner.

### Copying artifacts from an existing workspace (faster)

If you have access to a workspace where the cache is already populated, you can avoid the npm install entirely by copying the shared directory:

```bash
# On the source workspace — export
tar -czf /tmp/claude-code-cache.tar.gz -C /Workspace/Shared/.claude-code .

# Transfer to the target workspace (via UC volume, Workspace file upload, etc.)
# Then on the target workspace — import
mkdir -p /Workspace/Shared/.claude-code
tar -xzf /tmp/claude-code-cache.tar.gz -C /Workspace/Shared/.claude-code
```

---

## Productionizing: platform-level integration

The current setup requires users to manually run `source /Workspace/Shared/.claude-code/setup.sh` at the start of every session. Below are the platform changes that would remove that friction and make Claude Code a first-class part of the remote development experience.

### P0: SSH session init hook

The single highest-value change. If Databricks adds a per-workspace or per-user init hook for serverless SSH connections (analogous to cluster init scripts), `setup.sh` can run automatically on every connection — users just open a terminal and `claude` is already available.

**What it would look like:**
- Workspace admin sets an init script path in workspace settings (e.g., `/Workspace/Shared/.claude-code/setup.sh`)
- On every new serverless SSH session, the platform sources it before the user's shell is handed over
- Zero user steps required

This is the only change that fully eliminates the manual restore step.

### P1: Pre-deployed setup script

Rather than requiring a workspace admin to manually copy `setup.sh`, Databricks could bundle it as part of the remote development feature. When a workspace enables serverless SSH, `/Workspace/Shared/.claude-code/setup.sh` is already present.

The binary cache would still need to be populated on first use (requires network), but the script itself being pre-deployed means no bootstrap steps for admins.

### P2: Databricks identity as Claude auth

Currently each user needs a separate Anthropic/Claude.ai account and goes through a browser OAuth flow to authenticate Claude Code. A tighter integration would use the user's existing Databricks identity:

- Workspace admin configures an Anthropic API key or Claude for Work organization at the workspace level
- Claude Code is pre-authenticated for all users automatically
- No per-user OAuth flow, no credentials to persist

This would also allow workspace-level controls: usage policies, model selection, audit logging.

### P3: Workspace-level CLAUDE.md

A workspace admin could provide a shared `CLAUDE.md` injected into every user's Claude Code context — documenting workspace-specific details like catalog names, cluster policies, team conventions, internal tool paths. This is already partially addressed by the per-user `CLAUDE.md` at `/Workspace/Users/<email>/CLAUDE.md`, but a workspace-level layer (analogous to system prompts) would remove the burden from individual users.

### P4: Version lifecycle management

Currently any user can update the shared binary, which is convenient but uncontrolled. A production setup would:
- Pin the Claude Code version at the workspace level
- Route updates through an admin approval step (or automatic policy-gated rollout)
- Separate the shared binary cache from user-writable paths

This is mostly a process/permission question rather than a platform change, but workspace-level file ACLs on `/Workspace/Shared/` would enforce it.
