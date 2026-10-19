#!/usr/bin/env bash
# ============================================================================
# deploy_plugin.sh - push l4d2_director.smx and its config to the L4D2 server,
#                    restart it, and show the newest SourceMod error log.
#
# Adapted from the invasion repo's deploy/deploy_plugin.sh.
#
# Run from the REPO ROOT:
#     ./deploy/deploy_plugin.sh
#
# Environment:
#     L4D2_HOST   ssh target        (default: l4d2-director-deploy, the ~/.ssh/config
#                 alias for steam@192.168.1.55 = CT 107. NOT the invasion server.)
#     L4D2_PATH   game dir on host  (default: /home/steam/l4d2/left4dead2)
#
# Requires: ssh and scp locally (rsync is used when present; without it, e.g. in
# Git Bash on Windows, files are copied with scp instead), key-based ssh to
# L4D2_HOST, and passwordless sudo on the host for `systemctl restart l4d2`.
# ============================================================================
set -euo pipefail

L4D2_HOST="${L4D2_HOST:-l4d2-director-deploy}"
L4D2_PATH="${L4D2_PATH:-/home/steam/l4d2/left4dead2}"

readonly SM_PATH="${L4D2_PATH}/addons/sourcemod"
readonly LOG_DIR="${SM_PATH}/logs"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly REPO_ROOT
readonly SMX="${REPO_ROOT}/plugins/l4d2_director.smx"
readonly CFG="${REPO_ROOT}/configs/l4d2_director.cfg"

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m!!  WARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m!!  FATAL: %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v ssh >/dev/null 2>&1 || die "ssh is not installed locally."

if command -v rsync >/dev/null 2>&1; then
    HAVE_RSYNC=1
else
    HAVE_RSYNC=0
    command -v scp >/dev/null 2>&1 || die "neither rsync nor scp is installed locally."
    warn "rsync not found - copying with scp (every file is sent, not just changed ones)"
fi

# push SRC... DEST - copy local files to a remote path.
push() {
    if ((HAVE_RSYNC)); then
        rsync -av --checksum "$@"
    else
        local f
        for f in "${@:1:$#-1}"; do info "$(basename "$f")"; done
        scp -q "$@"
    fi
}

[[ -f "${SMX}" ]] || die "plugins/l4d2_director.smx not found.
    Compile it first:   ./build.sh"
[[ -f "${CFG}" ]] || die "configs/l4d2_director.cfg not found."

log "Deploying to ${L4D2_HOST}:${L4D2_PATH}"

ssh -o BatchMode=yes "${L4D2_HOST}" "test -d '${SM_PATH}/plugins' && test -d '${SM_PATH}/configs'" \
    || die "cannot reach ${L4D2_HOST} or ${SM_PATH}/plugins|configs does not exist.
    Check ssh keys, L4D2_HOST and L4D2_PATH."

# ---------------------------------------------------------------------------
# Plugin and config
# ---------------------------------------------------------------------------
log "copy l4d2_director.smx -> addons/sourcemod/plugins/"
push "${SMX}" "${L4D2_HOST}:${SM_PATH}/plugins/"

log "copy l4d2_director.cfg -> addons/sourcemod/configs/"
push "${CFG}" "${L4D2_HOST}:${SM_PATH}/configs/"

# ---------------------------------------------------------------------------
# Restart
# ---------------------------------------------------------------------------
log "Restarting the l4d2 service"
RESTART_OK=1
if ssh -o BatchMode=yes "${L4D2_HOST}" "sudo -n systemctl restart l4d2"; then
    info "restart issued"
else
    RESTART_OK=0
    warn "could not restart l4d2 over ssh (passwordless sudo missing, or the unit failed).
    Run on the host:   sudo systemctl restart l4d2 && systemctl status l4d2"
fi

if ((RESTART_OK)); then
    # Give srcds a moment to load Metamod/SourceMod before reading the log.
    sleep 8
    ssh -o BatchMode=yes "${L4D2_HOST}" "systemctl is-active l4d2" \
        && info "unit is active" \
        || warn "unit is not active - check: journalctl -u l4d2 -n 100"
fi

# ---------------------------------------------------------------------------
# Newest SourceMod error log
# ---------------------------------------------------------------------------
log "Last 50 lines of the newest SourceMod error log"
ssh -o BatchMode=yes "${L4D2_HOST}" "LOG_DIR='${LOG_DIR}' bash -s" <<'REMOTE'
set -uo pipefail
newest="$(ls -1t "$LOG_DIR"/errors_*.log 2>/dev/null | head -n 1 || true)"
if [ -z "$newest" ]; then
    echo "    no error log - clean"
    exit 0
fi
echo "    $newest"
echo "    ----------------------------------------------------------------"
tail -n 50 "$newest" | sed 's/^/    /'
REMOTE

log "Deploy finished"
if ((RESTART_OK)); then
    info "Verify in the server console or via rcon:   sm plugins list"
    info "Config edits alone only need:                 sm_director_reload"
else
    info "Restart the service by hand, then run:      sm plugins list"
    exit 1
fi
