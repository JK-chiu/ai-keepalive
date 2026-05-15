#!/usr/bin/env bash
# setup.sh — one-shot Linux installer for session-trigger (idempotent)
#
# Usage:
#   bash setup.sh
#
# What it does:
#   1. Creates ~/.session-trigger/ directory
#   2. Copies session-trigger.mjs and run.sh from this script's directory
#   3. Creates ~/.session-trigger/.claude symlink (shared OAuth credentials)
#   4. Creates empty ~/.session-trigger/CLAUDE.md (prevents loading user CLAUDE.md)
#   5. Installs crontab entry: 07:00, 12:00, 17:00 on weekdays

set -euo pipefail

TRIGGER_HOME="${HOME}/.session-trigger"
REAL_CLAUDE="${HOME}/.claude"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info() { printf '\033[0;32m[setup]\033[0m %s\n' "$1"; }
warn() { printf '\033[0;33m[setup] WARN:\033[0m %s\n' "$1"; }
err()  { printf '\033[0;31m[setup] ERROR:\033[0m %s\n' "$1" >&2; exit 1; }

# ── 1. Create directory ──────────────────────────────────────────────────────
mkdir -p "${TRIGGER_HOME}"
info "directory: ${TRIGGER_HOME}"

# ── 2. Copy scripts ──────────────────────────────────────────────────────────
info "Installing scripts from ${SRC}..."
for f in session-trigger.mjs run.sh; do
  [ -f "${SRC}/${f}" ] || err "Source file not found: ${SRC}/${f}"
  if [ "${SRC}/${f}" -ef "${TRIGGER_HOME}/${f}" ]; then
    info "  already in place: ${f}"
  else
    cp -f "${SRC}/${f}" "${TRIGGER_HOME}/${f}"
    info "  installed: ${f}"
  fi
done
chmod 755 "${TRIGGER_HOME}/run.sh"
chmod 644 "${TRIGGER_HOME}/session-trigger.mjs"

# ── 3. .claude symlink (shared credentials) ──────────────────────────────────
FAKE_CLAUDE="${TRIGGER_HOME}/.claude"
if [ -L "${FAKE_CLAUDE}" ]; then
  info ".claude symlink already exists, skipping"
elif [ -e "${FAKE_CLAUDE}" ]; then
  warn ".claude exists but is not a symlink — leaving as-is"
else
  if [ ! -d "${REAL_CLAUDE}" ]; then
    warn "Real .claude dir not found at ${REAL_CLAUDE}"
    warn "Claude may not authenticate. Run 'claude' interactively first."
    mkdir -p "${FAKE_CLAUDE}"
  else
    ln -s "${REAL_CLAUDE}" "${FAKE_CLAUDE}"
    info ".claude -> ${REAL_CLAUDE}"
  fi
fi

# ── 4. Empty CLAUDE.md (prevents user CLAUDE.md from loading) ────────────────
CLAUDE_MD="${TRIGGER_HOME}/CLAUDE.md"
if [ ! -f "${CLAUDE_MD}" ]; then
  touch "${CLAUDE_MD}"
  info "CLAUDE.md created (empty)"
else
  info "CLAUDE.md already exists, skipping"
fi

# ── 5. Crontab (idempotent) ───────────────────────────────────────────────────
MARKER="# session-trigger"
CRON_LINE="0 7,12,17 * * 1-5 ${TRIGGER_HOME}/run.sh >> ${TRIGGER_HOME}/cron.log 2>&1 ${MARKER}"

EXISTING=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "${EXISTING}" | grep -qF "${MARKER}"; then
  info "crontab entry already exists, skipping"
else
  if [ -z "${EXISTING}" ]; then
    printf '%s\n' "${CRON_LINE}" | crontab -
  else
    printf '%s\n%s\n' "${EXISTING}" "${CRON_LINE}" | crontab -
  fi
  info "crontab installed: 07:00, 12:00, 17:00 (weekdays)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
info ""
info "Setup complete!"
info ""
info "Directory structure:"
ls -la "${TRIGGER_HOME}"
info ""
info "Crontab:"
crontab -l 2>/dev/null | grep -E "session-trigger" || warn "No entry found"
info ""
info "To test manually:"
info "  ${TRIGGER_HOME}/run.sh"
info ""
info "Log files:"
info "  ${TRIGGER_HOME}/session-trigger.log"
info "  ${TRIGGER_HOME}/cron.log"
