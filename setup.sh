#!/bin/bash
# =============================================================================
# Claude Code for Databricks — Multi-User Setup
# =============================================================================
#
# Persists Claude Code across ephemeral Databricks serverless SSH sessions.
# Works for any user in the workspace — no per-user configuration needed.
# Supports both x86_64 and aarch64 (arm64) compute.
#
# Architecture:
#   /Workspace/Shared/.claude-code/          — shared binary cache (one copy)
#     versions/<version>                     — x86_64 standalone binary
#     arm64/node                             — aarch64 Node.js binary
#     arm64/current_version                  — current arm64 claude version
#     arm64/versions/<version>.tar.gz        — aarch64 claude-code package
#   /Workspace/Users/<email>/.claude-persist/ — per-user credentials (private)
#
# Usage:
#   source /Workspace/Shared/.claude-code/setup.sh
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------
SHARED_DIR="/Workspace/Shared/.claude-code"
CLAUDE_LOCAL_DIR="${HOME}/.local/share/claude"
CLAUDE_BIN_DIR="${HOME}/.local/bin"
CLAUDE_CONFIG_DIR="${HOME}/.claude"
ARCH=$(uname -m)   # x86_64 or aarch64

# Node.js version to download when no cache exists (arm64 only)
NODE_VERSION="22.14.0"
NODE_URL="https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz"

# arm64 runtime paths (ephemeral /tmp — fast, no FUSE issues)
ARM64_CACHE="${SHARED_DIR}/arm64"
ARM64_NODE_CACHE="${ARM64_CACHE}/node"
ARM64_TMP_NODE="/tmp/claude-arm64-node"
ARM64_TMP_PKG="/tmp/claude-arm64-pkg"

# --- Helpers -----------------------------------------------------------------
log()  { echo "[claude] $*"; }
warn() { echo "[claude] WARNING: $*" >&2; }
die()  { echo "[claude] ERROR: $*" >&2; return 1; }

# --- Detect current user's email ---------------------------------------------
get_user_email() {
    local email
    email=$(grep -m1 'email' /Workspace/.proc/self/git/config 2>/dev/null | awk '{print $3}')
    if [ -n "$email" ]; then
        echo "$email"; return
    fi

    if [ -n "${DATABRICKS_CLI_PATH:-}" ]; then
        email=$($DATABRICKS_CLI_PATH current-user me 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('emails', []):
    if e.get('primary'):
        print(e['value'])
        break
" 2>/dev/null)
        [ -n "$email" ] && { echo "$email"; return; }
    fi

    if [ -n "${DATABRICKS_HOST:-}" ] && [ -n "${DATABRICKS_TOKEN:-}" ]; then
        email=$(curl -sf -H "Authorization: Bearer ${DATABRICKS_TOKEN}" \
            "${DATABRICKS_HOST}/api/2.0/preview/scim/v2/Me" 2>/dev/null | \
            python3 -c "
import sys, json
data = json.load(sys.stdin)
for e in data.get('emails', []):
    if e.get('primary'):
        print(e['value'])
        break
" 2>/dev/null)
        [ -n "$email" ] && { echo "$email"; return; }
    fi

    die "Could not determine user email. Are you on a Databricks cluster?"
}

get_user_persist_dir() { echo "/Workspace/Users/${1}/.claude-persist"; }

ensure_path() {
    if [[ ":$PATH:" != *":${CLAUDE_BIN_DIR}:"* ]]; then
        export PATH="${CLAUDE_BIN_DIR}:${PATH}"
    fi
}

# --- Credentials + settings (arch-independent) ------------------------------
restore_credentials() {
    local user_dir="$1"
    mkdir -p "${CLAUDE_CONFIG_DIR}"

    # Symlink credentials so token refreshes by Claude Code write through to
    # persistent storage automatically — no manual re-save needed.
    local persist_creds="${user_dir}/.credentials.json"
    if [ -f "$persist_creds" ]; then
        log "Linking credentials to persistent storage..."
        rm -f "${CLAUDE_CONFIG_DIR}/.credentials.json"
        ln -sf "$persist_creds" "${CLAUDE_CONFIG_DIR}/.credentials.json"
    else
        warn "No saved credentials. Run 'claude' to authenticate, then:"
        warn "  source /Workspace/Shared/.claude-code/setup.sh save"
    fi

    for f in settings.json settings.local.json; do
        [ -f "${user_dir}/${f}" ] && cp "${user_dir}/${f}" "${CLAUDE_CONFIG_DIR}/${f}"
    done
}

link_plugins() {
    local email="$1"
    local ws_plugins_dir="/Workspace/Users/${email}/.claude/plugins"
    mkdir -p "$ws_plugins_dir"
    if [ ! -L "${CLAUDE_CONFIG_DIR}/plugins" ]; then
        rm -rf "${CLAUDE_CONFIG_DIR}/plugins" 2>/dev/null
        ln -sf "$ws_plugins_dir" "${CLAUDE_CONFIG_DIR}/plugins"
        log "Plugins linked to persistent storage."
    fi
}

link_memory() {
    local email="$1"
    local ws_memory_dir="/Workspace/Users/${email}/.claude/memory"
    [ -d "$ws_memory_dir" ] || return 0
    local encoded project_dir
    encoded=$(echo "/Workspace/Users/${email}" | sed 's/[/@.]/-/g')
    project_dir="${CLAUDE_CONFIG_DIR}/projects/${encoded}"
    mkdir -p "$project_dir"
    if [ ! -L "$project_dir/memory" ]; then
        rm -rf "$project_dir/memory" 2>/dev/null
        ln -sf "$ws_memory_dir" "$project_dir/memory"
        log "Memory linked to persistent storage."
    fi
}

save_credentials() {
    local user_dir="$1"
    mkdir -p "${user_dir}"
    if [ -f "${CLAUDE_CONFIG_DIR}/.credentials.json" ]; then
        log "Saving credentials..."
        cp "${CLAUDE_CONFIG_DIR}/.credentials.json" "${user_dir}/.credentials.json"
    else
        warn "No credentials found — authenticate first."
    fi
    for f in settings.json settings.local.json; do
        [ -f "${CLAUDE_CONFIG_DIR}/${f}" ] && cp "${CLAUDE_CONFIG_DIR}/${f}" "${user_dir}/${f}"
    done
}

# =============================================================================
# x86_64 path: standalone binary restore
# =============================================================================

restore_x86() {
    local version="" binary_source=""

    if [ -f "${SHARED_DIR}/current_version" ]; then
        version=$(cat "${SHARED_DIR}/current_version")
        [ -f "${SHARED_DIR}/versions/${version}" ] && binary_source="${SHARED_DIR}/versions/${version}"
    fi

    if [ -z "$binary_source" ]; then
        log "No cached x86_64 binary found. Installing fresh..."
        install_fresh_x86; return
    fi

    log "Restoring binary v${version}..."
    mkdir -p "${CLAUDE_LOCAL_DIR}/versions" "${CLAUDE_BIN_DIR}"
    cp "$binary_source" "${CLAUDE_LOCAL_DIR}/versions/${version}"
    chmod +x "${CLAUDE_LOCAL_DIR}/versions/${version}"
    ln -sf "${CLAUDE_LOCAL_DIR}/versions/${version}" "${CLAUDE_BIN_DIR}/claude"
    ensure_path
    log "Ready! Claude Code v${version}"
}

install_fresh_x86() {
    log "Installing Claude Code via npm..."
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -5
    ensure_path
    log "Installed! Authenticate, then: source /Workspace/Shared/.claude-code/setup.sh save"
}

save_x86() {
    local binary_link="${CLAUDE_BIN_DIR}/claude"
    [ -f "$binary_link" ] || [ -L "$binary_link" ] || die "Claude not found at ${binary_link}."
    local binary_target version
    binary_target=$(readlink -f "$binary_link")
    version=$(basename "$binary_target")

    log "Caching x86_64 binary v${version}..."
    mkdir -p "${SHARED_DIR}/versions"
    [ -f "${SHARED_DIR}/versions/${version}" ] || cp "$binary_target" "${SHARED_DIR}/versions/${version}"
    echo "$version" > "${SHARED_DIR}/current_version"
    log "Shared x86_64 cache updated (v${version})."
}

# =============================================================================
# arm64 path: node binary + claude-code package
# =============================================================================
#
# Cache layout:
#   arm64/node                        — ARM64 Node.js binary (~110MB)
#   arm64/current_version             — current claude version
#   arm64/versions/<ver>.tar.gz       — claude-code package contents
#
# Runtime layout (/tmp — not FUSE):
#   /tmp/claude-arm64-node            — node binary
#   /tmp/claude-arm64-pkg/            — claude-code package (cli.js lives here)
#   ~/.local/bin/claude               — wrapper: exec node pkg/cli.js "$@"

restore_arm64() {
    local version=""
    [ -f "${ARM64_CACHE}/current_version" ] && version=$(cat "${ARM64_CACHE}/current_version")

    if [ -z "$version" ] || \
       [ ! -f "${ARM64_CACHE}/versions/${version}.tar.gz" ] || \
       [ ! -f "${ARM64_NODE_CACHE}" ]; then
        log "No arm64 cache found. Installing fresh (~2 min first time)..."
        install_fresh_arm64; return
    fi

    log "Restoring arm64 v${version}..."

    # Restore node to /tmp (fast local copy)
    cp "${ARM64_NODE_CACHE}" "${ARM64_TMP_NODE}"
    chmod +x "${ARM64_TMP_NODE}"

    # Extract claude-code package to /tmp (tar.gz contains package contents, not directory)
    rm -rf "${ARM64_TMP_PKG}"
    mkdir -p "${ARM64_TMP_PKG}"
    tar -xzf "${ARM64_CACHE}/versions/${version}.tar.gz" -C "${ARM64_TMP_PKG}"

    write_arm64_wrapper "${ARM64_TMP_NODE}" "${ARM64_TMP_PKG}/cli.js"
    ensure_path
    log "Ready! Claude Code v${version} (arm64)"
}

install_fresh_arm64() {
    local tmp_install
    tmp_install=$(mktemp -d /tmp/claude-arm64-install-XXXXXX)

    # Download Node.js ARM64 tarball
    if [ -f "${ARM64_NODE_CACHE}" ]; then
        log "Using cached arm64 Node.js..."
        cp "${ARM64_NODE_CACHE}" "${ARM64_TMP_NODE}"
        chmod +x "${ARM64_TMP_NODE}"
        # Still need full node install for npm
        log "Downloading Node.js v${NODE_VERSION} for npm (needed for install)..."
        curl -fsSL "${NODE_URL}" -o "${tmp_install}/node.tar.gz"
        tar -xzf "${tmp_install}/node.tar.gz" -C "${tmp_install}" --strip-components=1
    else
        log "Downloading Node.js v${NODE_VERSION} for arm64..."
        curl -fsSL "${NODE_URL}" -o "${tmp_install}/node.tar.gz"
        tar -xzf "${tmp_install}/node.tar.gz" -C "${tmp_install}" --strip-components=1
        cp "${tmp_install}/bin/node" "${ARM64_TMP_NODE}"
        chmod +x "${ARM64_TMP_NODE}"
    fi
    rm -f "${tmp_install}/node.tar.gz"

    # Use the full node install (with npm) to install claude-code
    log "Installing @anthropic-ai/claude-code..."
    local npm_cli="${tmp_install}/lib/node_modules/npm/bin/npm-cli.js"
    PATH="${tmp_install}/bin:$PATH" \
        "${tmp_install}/bin/node" "$npm_cli" \
        install --prefix "${tmp_install}/pkg" -g @anthropic-ai/claude-code 2>&1 | tail -5

    # Copy just the claude-code package to the permanent /tmp location
    rm -rf "${ARM64_TMP_PKG}"
    cp -r "${tmp_install}/pkg/lib/node_modules/@anthropic-ai/claude-code" "${ARM64_TMP_PKG}"

    # Clean up full node install (only keep the binary)
    rm -rf "${tmp_install}"

    write_arm64_wrapper "${ARM64_TMP_NODE}" "${ARM64_TMP_PKG}/cli.js"
    ensure_path
    log ""
    log "Installed! Authenticate with 'claude', then save for next session:"
    log "  source /Workspace/Shared/.claude-code/setup.sh save"
}

write_arm64_wrapper() {
    local node_path="$1" cli_path="$2"
    mkdir -p "${CLAUDE_BIN_DIR}"
    # Overwrite atomically by writing to a temp file first (avoids "text file busy")
    local tmp_wrapper
    tmp_wrapper=$(mktemp "${CLAUDE_BIN_DIR}/.claude-XXXXXX")
    cat > "$tmp_wrapper" << EOF
#!/bin/bash
exec "${node_path}" "${cli_path}" "\$@"
EOF
    chmod +x "$tmp_wrapper"
    mv -f "$tmp_wrapper" "${CLAUDE_BIN_DIR}/claude"
}

save_arm64() {
    # Verify runtime state exists
    [ -f "${ARM64_TMP_NODE}" ] || die "${ARM64_TMP_NODE} not found. Run setup first."
    [ -f "${ARM64_TMP_PKG}/cli.js" ] || die "${ARM64_TMP_PKG}/cli.js not found. Run setup first."

    # Get version from package.json (reliable, no exec needed)
    local version
    version=$(python3 -c "import json,sys; print(json.load(open('${ARM64_TMP_PKG}/package.json'))['version'])" 2>/dev/null) || \
    version=$(grep '"version"' "${ARM64_TMP_PKG}/package.json" | head -1 | grep -o '[0-9][0-9.]*')
    [ -n "$version" ] || die "Could not determine claude-code version."

    mkdir -p "${ARM64_CACHE}/versions"

    log "Caching arm64 Node.js binary..."
    cp "${ARM64_TMP_NODE}" "${ARM64_NODE_CACHE}"

    log "Caching arm64 claude-code v${version}..."
    # Save package contents (not the directory itself) so restore can extract directly into ARM64_TMP_PKG
    tar -czf "${ARM64_CACHE}/versions/${version}.tar.gz" -C "${ARM64_TMP_PKG}" .
    echo "$version" > "${ARM64_CACHE}/current_version"

    log "arm64 cache updated (v${version})."
}

# =============================================================================
# Top-level commands
# =============================================================================

do_restore() {
    local email user_dir
    email=$(get_user_email) || return 1
    user_dir=$(get_user_persist_dir "$email")

    log "Setting up Claude Code for ${email} (${ARCH})..."
    mkdir -p "${CLAUDE_BIN_DIR}" "${CLAUDE_LOCAL_DIR}"

    if [ "$ARCH" = "aarch64" ]; then
        restore_arm64
    else
        restore_x86
    fi

    restore_credentials "$user_dir"
    link_plugins "$email"
    link_memory "$email"
}

do_fresh_install() {
    if [ "$ARCH" = "aarch64" ]; then install_fresh_arm64
    else install_fresh_x86; fi
}

do_save() {
    local email user_dir
    email=$(get_user_email) || return 1
    user_dir=$(get_user_persist_dir "$email")

    if [ "$ARCH" = "aarch64" ]; then save_arm64
    else save_x86; fi

    save_credentials "$user_dir"
    log "Saved! Next session: source /Workspace/Shared/.claude-code/setup.sh"
}

do_update() {
    log "Updating Claude Code (${ARCH})..."
    if [ "$ARCH" = "aarch64" ]; then
        rm -f "${ARM64_CACHE}/current_version" 2>/dev/null || true
        install_fresh_arm64
    else
        npm install -g @anthropic-ai/claude-code@latest 2>&1 | tail -5
    fi
    do_save
    log "Update complete. All users get the new version next session."
}

do_status() {
    local email user_dir
    email=$(get_user_email) || return 1
    user_dir=$(get_user_persist_dir "$email")

    echo "=== Claude Code Status ==="
    echo "User: ${email}"
    echo "Arch: ${ARCH}"
    echo ""

    if [ "$ARCH" = "aarch64" ]; then
        echo "Shared arm64 cache (${ARM64_CACHE}):"
        if [ -f "${ARM64_CACHE}/current_version" ]; then
            echo "  Version : $(cat "${ARM64_CACHE}/current_version")"
            echo "  Node    : $([ -f "${ARM64_NODE_CACHE}" ] && echo "cached" || echo "missing")"
        else
            echo "  Not cached yet"
        fi
    else
        echo "Shared x86_64 cache (${SHARED_DIR}/versions):"
        if [ -f "${SHARED_DIR}/current_version" ]; then
            echo "  Version: $(cat "${SHARED_DIR}/current_version")"
        else
            echo "  Not cached yet"
        fi
    fi
    echo ""
    echo "Your credentials: $([ -f "${user_dir}/.credentials.json" ] && echo "saved" || echo "not saved")"
    echo ""
    echo "Local install:"
    if command -v claude &>/dev/null; then
        echo "  $(claude --version 2>/dev/null || echo 'version unknown')"
    else
        echo "  not found"
    fi
}

# --- Main --------------------------------------------------------------------
case "${1:-setup}" in
    setup)   do_restore ;;
    save)    do_save ;;
    update)  do_update ;;
    status)  do_status ;;
    install) do_fresh_install ;;
    *)
        echo "Claude Code for Databricks"
        echo ""
        echo "Usage: source /Workspace/Shared/.claude-code/setup.sh [command]"
        echo ""
        echo "Commands:"
        echo "  setup    Restore Claude Code for this session (default)"
        echo "  save     Cache binary + credentials after install/auth"
        echo "  update   Update to latest version and refresh cache"
        echo "  status   Show cache and install status"
        echo "  install  Force fresh install via npm"
        ;;
esac
