# Claude Code Setup — New SSH Session Quickstart

Every time you start a new Databricks serverless SSH session, the home directory is wiped. Claude Code, its credentials, and your memory files must be restored. Everything is already cached on Workspace — you just need to run one command.

> **Note (Apr 2026):** Databricks serverless compute switched to aarch64 (ARM64). The setup script handles this automatically — no change to the workflow below.

---

## Step 1: Restore Claude Code (required every session)

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

This takes ~0.9 seconds and does the following:
- Detects your identity from `/Workspace/.proc/self/git/config`
- Detects CPU architecture (`x86_64` or `aarch64`) and restores the right binary:
  - **x86_64**: copies the standalone ELF binary to `~/.local/share/claude/`
  - **aarch64**: copies the ARM64 Node.js binary to `/tmp/` and extracts the claude-code package, then writes a wrapper script at `~/.local/bin/claude`
- **Restores** your OAuth credentials from `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/.credentials.json` → `~/.claude/.credentials.json`, with an expiry check:
  - If the access token is **expired**: a warning is printed, but the file is still copied — Claude Code will use the refresh token to get a new access token automatically on first API call
  - If the access token expires **within 1 hour**: a note is logged
  - The access token lifetime is ~24 hours; the refresh token is much longer-lived
- The `claude` command is a **wrapper script** (not the raw binary) that:
  - Spawns a background watcher polling `~/.claude/.credentials.json` every 3 seconds
  - Syncs any changes (e.g. token refreshes) back to persistent storage immediately
  - Forces a final sync on exit via an EXIT trap
  - This means credentials auto-save on first auth and on every token refresh — **no manual `save` needed**
- Restores your settings files
- **Symlinks** `~/.claude/plugins/` → `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/plugins/` (plugins persist automatically)
- Symlinks Claude Code memory to the persistent directory at `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/memory/`
- Adds `~/.local/bin` to your `PATH`

## Step 2: Run Claude Code

```bash
claude
```

That's it. You're authenticated and ready.

---

## If something goes wrong

### "Exec format error" when running claude

The cached binary is the wrong architecture for this machine (e.g. an x86_64 binary on an arm64 node). Run:

```bash
source /Workspace/Shared/.claude-code/setup.sh install
source /Workspace/Shared/.claude-code/setup.sh save
```

This triggers a fresh install using the right architecture and updates the shared cache.

### "No cached version found"

The shared cache is missing. Trigger a fresh install:

```bash
source /Workspace/Shared/.claude-code/setup.sh install
source /Workspace/Shared/.claude-code/setup.sh save
```

### Claude starts but asks you to authenticate

This should now be rare. The wrapper's background watcher syncs token refreshes every 3 seconds and forces a final sync on exit, so credentials persist automatically across sessions.

Common causes if it does happen:
- **Killed session** (e.g. `kill -9`) — the EXIT trap didn't fire, so the last token refresh wasn't synced back
- **Refresh token expired** — after a long period of inactivity (weeks/months), even the refresh token becomes invalid

In either case, just authenticate when prompted — credentials will auto-save on exit:

```bash
claude   # authenticate in browser, then exit normally
```

If you killed the session and want to force-save immediately after re-auth:

```bash
source /Workspace/Shared/.claude-code/setup.sh save
```

### "command not found: claude" after running setup.sh

Your shell didn't pick up the PATH change. Either:

```bash
# Option A: source it (updates PATH in current shell)
source /Workspace/Shared/.claude-code/setup.sh

# Option B: if you ran it without source, manually add to PATH
export PATH="$HOME/.local/bin:$PATH"
```

Note: you must use `source` (or `.`), not just run the script directly, because it needs to modify your current shell's `PATH`.

### Claude Code needs updating

```bash
source /Workspace/Shared/.claude-code/setup.sh update
```

This installs the latest version via npm and updates the shared cache so all users get it.

### Check status

```bash
source /Workspace/Shared/.claude-code/setup.sh status
```

Shows the cached version, whether your credentials are saved, and whether Claude is available locally.

---

## What's stored where

| What | Path | Shared? |
|---|---|---|
| Setup script | `/Workspace/Shared/.claude-code/setup.sh` | Yes — all users |
| x86_64 binary cache | `/Workspace/Shared/.claude-code/versions/2.1.112` | Yes — all users |
| arm64 Node.js binary | `/Workspace/Shared/.claude-code/arm64/node` | Yes — all users |
| arm64 claude-code package | `/Workspace/Shared/.claude-code/arm64/versions/2.1.112.tar.gz` | Yes — all users |
| Your OAuth credentials | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/.credentials.json` | No — private |
| Your settings | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/settings*.json` | No — private |
| Claude Code plugins | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/plugins/` | No — private |
| Claude Code memory | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/memory/` | No — private |
| CLAUDE.md (project context) | `/Workspace/Users/tanishq.maheshwari@databricks.com/CLAUDE.md` | No — private |

---

## MCP Servers

MCP server configuration lives in `~/.claude.json`, which is wiped every session. Use `setup-extensions.py` to reapply it each time.

### First-time setup

Copy the script to your persistent Workspace directory and edit the `MCP_SERVERS` dict:

```bash
cp /path/to/remote-development-setup/setup-extensions.py \
   /Workspace/Users/<your-email>/setup-extensions.py
```

The script ships with the Databricks SQL MCP pre-configured. It auto-detects your workspace URL and session token from `$DATABRICKS_HOST` and `$DATABRICKS_TOKEN`, so no hardcoding needed.

### Each session

Run it after `setup.sh`:

```bash
source /Workspace/Shared/.claude-code/setup.sh
python3 /Workspace/Users/<your-email>/setup-extensions.py
```

Then restart Claude Code if any MC