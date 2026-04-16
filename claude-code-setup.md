# Claude Code Setup — New SSH Session Quickstart

Every time you start a new Databricks serverless SSH session, the home directory is wiped. Claude Code, its credentials, and your memory files must be restored. Everything is already cached on Workspace from our previous session — you just need to run one command.

---

## Step 1: Restore Claude Code (required every session)

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

This takes ~0.6 seconds and does the following:
- Detects your identity from `/Workspace/.proc/self/git/config`
- Copies the Claude Code binary (v2.1.110, 224MB) from `/Workspace/Shared/.claude-code/versions/` to `~/.local/share/claude/`
- Restores your OAuth credentials from `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/.credentials.json`
- Restores your settings files
- Symlinks Claude Code memory to the persistent directory at `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/memory/`
- Adds `~/.local/bin` to your `PATH`

## Step 2: Run Claude Code

```bash
claude
```

That's it. You're authenticated and ready.

---

## If something goes wrong

### "No cached version found"

The shared binary cache is missing. Reinstall and re-cache:

```bash
npm install -g @anthropic-ai/claude-code
source /Workspace/Shared/.claude-code/setup.sh save
```

### Claude starts but asks you to authenticate

Your cached credentials have expired. Authenticate in the browser when prompted, then save the new credentials:

```bash
claude                                              # authenticate
source /Workspace/Shared/.claude-code/setup.sh save # cache new credentials
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
| Binary cache | `/Workspace/Shared/.claude-code/versions/2.1.110` | Yes — all users |
| Your OAuth credentials | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/.credentials.json` | No — private |
| Your settings | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude-persist/settings*.json` | No — private |
| Claude Code memory | `/Workspace/Users/tanishq.maheshwari@databricks.com/.claude/memory/` | No — private |
| CLAUDE.md (project context) | `/Workspace/Users/tanishq.maheshwari@databricks.com/CLAUDE.md` | No — private |

---

## Optional: combine with Python venv activation

If you have a persistent Python venv on Workspace (see `persisting-python-environments.md`), you can do both in one go:

```bash
source /Workspace/Shared/.claude-code/setup.sh
cd /Workspace/Users/tanishq.maheshwari@databricks.com/my-project
source .venv/bin/activate
claude
```

Or create a personal init script at `/Workspace/Users/tanishq.maheshwari@databricks.com/init.sh`:

```bash
#!/bin/bash
source /Workspace/Shared/.claude-code/setup.sh
export UV_LINK_MODE=copy

# Activate a project venv if you have one:
# cd /Workspace/Users/tanishq.maheshwari@databricks.com/my-project
# source .venv/bin/activate
```

Then every session is just:

```bash
source /Workspace/Users/tanishq.maheshwari@databricks.com/init.sh
```
