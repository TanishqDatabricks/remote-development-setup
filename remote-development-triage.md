# Remote Development Triage: Databricks Serverless SSH

*Last updated: 2026-04-22*

---

## The Core Problem

Databricks serverless SSH connects to **ephemeral compute**. The home directory (`/home/spark-<uuid>/`) is wiped on every session restart. This creates a cascade of friction for remote development:

- The `spark-<uuid>` username regenerates each restart — paths that hardcode `$HOME` break
- No init script hook for serverless SSH — `.bashrc` is ephemeral, nothing runs automatically on connect
- No `sudo` or write access to `/etc/` — can't install system packages persistently
- FUSE mounts (`/Workspace/`, `/Volumes/`) survive restarts but have performance overhead and eventual-consistency quirks

**The one durable escape hatch:** `/Workspace/Users/<email>/` and `/Workspace/Shared/` persist across sessions and are writable.

---

## Problems & Fixes

### 1. Claude Code not persisting

**Problem:** Claude Code is a ~224MB binary installed under `$HOME`. Reinstalling via npm takes minutes and requires re-authentication every session.

**Fix:** Cache the binary to `/Workspace/Shared/.claude-code/versions/` once, copy it back to `$HOME` on each session restore. The wrapper script also watches for credential changes and syncs them back to `/Workspace/Users/<email>/.claude-persist/` on exit.

**Restore time:** ~0.6 seconds from cache (vs. 2–5 min fresh install).

**Script:** `/Workspace/Shared/.claude-code/setup.sh`

**Usage:**
```bash
source /Workspace/Shared/.claude-code/setup.sh          # every new session
source /Workspace/Shared/.claude-code/setup.sh save     # after auth or re-auth
source /Workspace/Shared/.claude-code/setup.sh update   # upgrade to latest version
source /Workspace/Shared/.claude-code/setup.sh status   # check cache state
```

---

### 2. `npm`/`npx` broken between sessions

**Problem:** On x86 serverless SSH, `/usr/local/bin/node` survives restarts but `/usr/local/lib/node_modules/npm` is wiped. `npm` and `npx` exist as broken symlinks, breaking MCP servers that use `npx mcp-remote`.

**Fix:** Cache an npm tarball in `/Workspace/Shared/.claude-code/npm/` keyed by `<node-version>-<arch>`. On each session restore, extract it to `/tmp/claude-npm/` and expose `npm`/`npx` shims via `~/.local/bin/`. Handled automatically by `setup.sh`.

---

### 3. `.databrickscfg` not found

**Problem:** The Databricks CLI and `bricks` hardcode `$HOME/.databrickscfg`. Since `$HOME` is ephemeral, any `.databrickscfg` stored there is lost on restart. Setting `DATABRICKS_CONFIG_FILE` is not sufficient — `bricks bundle deploy` ignores it and looks directly at `$HOME`.

**Error seen:**
```
cannot parse config file: open /home/spark-<uuid>/.databrickscfg: no such file or directory
```

**Fix:** Store the config file in the persistent Workspace (`/Workspace/Users/<email>/.databrickscfg`) and create a symlink from `$HOME/.databrickscfg` on each session restore. Also export `DATABRICKS_CONFIG_FILE` as belt-and-suspenders for tools that do respect it.

Added to `setup.sh` `do_restore()`:
```bash
ln -sf "/Workspace/Users/${email}/.databrickscfg" "${HOME}/.databrickscfg"
export DATABRICKS_CONFIG_FILE="/Workspace/Users/${email}/.databrickscfg"
```

**To fix the current session without re-sourcing:**
```bash
ln -sf /Workspace/Users/tanishq.maheshwari@databricks.com/.databrickscfg ~/.databrickscfg
```

---

### 4. Claude Code credentials expiring / not syncing back

**Problem:** Claude Code uses atomic rename when refreshing OAuth tokens, which breaks symlinks. The updated credentials end up in the ephemeral `$HOME/.claude/` and are lost when the session ends.

**Fix:** The `claude` wrapper script spawns a background watcher that polls `.credentials.json` every 3 seconds and copies any changes back to the persistent `.claude-persist/` directory. On `EXIT`, it does a final sync.

---

### 5. Claude memory and plugins not persisting

**Problem:** Claude Code stores project memory under `$HOME/.claude/projects/.../memory/`, which is ephemeral.

**Fix:** `setup.sh` symlinks `$HOME/.claude/projects/<encoded-path>/memory/` to `/Workspace/Users/<email>/.claude/memory/` and `$HOME/.claude/plugins/` to `/Workspace/Users/<email>/.claude/plugins/`. Both survive restarts.

---

## What Still Requires Manual Action Each Session

There is **no automatic init hook** for serverless SSH. You must run:

```bash
source /Workspace/Shared/.claude-code/setup.sh
```

once per terminal after connecting. This is a platform limitation — `.bashrc` is ephemeral and there is no equivalent of a cluster init script for serverless SSH sessions.

---

## Legacy Scripts (Superseded)

| File | Status |
|---|---|
| `~/.claude/init-claude.sh` | Superseded — thin wrapper around the old per-user script |
| `~/.claude-persist/setup-claude.sh` | Superseded — original per-user version, no multi-user or arm64 support |
| `~/remote-development-setup/setup.sh` | Superseded — earlier copy of the shared script, missing npm restore logic |

All functionality has been consolidated into `/Workspace/Shared/.claude-code/setup.sh`.

---

## Architecture Summary

```
/Workspace/Shared/.claude-code/
  setup.sh                        ← source this every session
  current_version                 ← x86_64 current version tag
  versions/<version>              ← x86_64 standalone binary
  arm64/node                      ← arm64 Node.js binary
  arm64/current_version           ← arm64 current version tag
  arm64/versions/<ver>.tar.gz     ← arm64 claude-code package
  npm/<node_ver>-<arch>.tar.gz    ← npm runtime cache

/Workspace/Users/<email>/
  .databrickscfg                  ← persistent Databricks CLI config
  .claude-persist/
    .credentials.json             ← Claude OAuth credentials (synced on exit)
    settings.json
    settings.local.json
  .claude/
    memory/                       ← symlinked from ephemeral $HOME/.claude/...
    plugins/                      ← symlinked from ephemeral $HOME/.claude/...
```
