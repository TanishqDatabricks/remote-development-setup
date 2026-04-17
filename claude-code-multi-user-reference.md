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
├── .credentials.json                        # OAuth access + refresh tokens
├── settings.json                            # Claude Code settings
└── settings.local.json                      # Local overrides
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

## Security notes

- OAuth credentials (access + refresh tokens) are stored in each user's private Workspace directory at `/Workspace/Users/<email>/.claude-persist/.credentials.json`
- File permissions are set to 600 on restore to the ephemeral home
- Workspace file permissions follow Databricks workspace ACLs
- The shared binary is just the Claude Code ELF executable — no secrets

## Updating

When a new Claude Code version is released, any user can run:

```bash
source /Workspace/Shared/.claude-code/setup.sh update
```

This updates the shared binary cache. All users get the new version on their next `setup.sh` invocation.
