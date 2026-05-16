#!/usr/bin/env bash
# start.sh — cron wrapper for keepalive.mjs
# Solves: cron has no NVM in PATH, so node/claude/codex are not found

set -euo pipefail

TRIGGER_HOME="${HOME}/.ai-keepalive"
LOG_FILE="${TRIGGER_HOME}/keepalive.log"

_log() {
  printf '[%s] [start.sh] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" \
    >> "$LOG_FILE" 2>/dev/null || logger -t ai-keepalive "start.sh: $1"
}

mkdir -p "$TRIGGER_HOME"

# ── Resolve node via NVM (no hardcoded version number) ──────────────────────
export NVM_DIR="${HOME}/.nvm"

if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
  _log "FATAL: NVM not found at ${NVM_DIR}/nvm.sh"
  exit 1
fi

# --no-use avoids triggering .nvmrc auto-switch and speeds up load
# shellcheck source=/dev/null
. "${NVM_DIR}/nvm.sh" --no-use

NODE_PATH=$(nvm which default 2>/dev/null) || {
  _log "FATAL: nvm which default failed"
  exit 1
}
NODE_BIN_DIR=$(dirname "$NODE_PATH")

# ── Build PATH: NVM node + .local/bin (claude) + system ─────────────────────
export PATH="${NODE_BIN_DIR}:${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"

# ── Sanity-check binaries ────────────────────────────────────────────────────
for cmd in node claude codex; do
  if command -v "$cmd" >/dev/null 2>&1; then
    _log "OK: $cmd = $(command -v "$cmd")"
  else
    _log "WARN: $cmd not found in PATH=${PATH}"
  fi
done

_log "launching keepalive (node=$(node --version))"

# exec replaces this shell process so cron tracks the right PID
exec node "${TRIGGER_HOME}/keepalive.mjs"
