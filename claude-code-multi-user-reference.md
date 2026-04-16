# Claude Code for Databricks — Shared Setup

This directory contains the multi-user Claude Code persistence layer for Databricks serverless SSH sessions.

## Problem

Databricks serverless compute is ephemeral. The home directory (`/home/spark-*`) is an overlay filesystem wiped on every restart. Claude Code (~224MB binary), its OAuth credentials, and settings must be reinstalled and re-authenticated each session.

## Solution

Cache the binary in a shared Workspace location and credentials in each user's private Workspace directory. Restore takes ~0.6 seconds with no internet required.

## Directory structure

```
/Workspace/Shared/.claude-code/          # THIS DIRECTORY — shared, all users
├── CLAUDE.md                            # This file
├── setup.sh                             # The setup script
├── current_version                      # e.g., "2.1.110"
└── versions/
    └── <version>                        # ELF binary (~224MB)

/Workspace/Users/<email>/.claude-persist/  # Per-user, private
├── .credentials.json                      # OAuth access + refresh tokens
├── settings.json                          # Claude Code settings
└── settings.local.json                    # Local overrides
```

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
