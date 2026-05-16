#!/usr/bin/env bash
# install.sh — one-shot Linux installer for ai-keepalive (idempotent)
#
# Usage:
#   bash install.sh
#
# What it does:
#   0. Pre-flight: checks NVM, Node.js, Claude Code login, Codex login
#   1. Creates ~/.ai-keepalive/ directory
#   2. Copies keepalive.mjs and start.sh
#   3. Creates ~/.ai-keepalive/.claude symlink (shared OAuth credentials)
#   4. Creates empty ~/.ai-keepalive/CLAUDE.md (prevents loading user CLAUDE.md)
#   5. Installs crontab entry: 07:00, 12:00, 17:00 on weekdays (UTC)

set -euo pipefail

TRIGGER_HOME="${HOME}/.ai-keepalive"
REAL_CLAUDE="${HOME}/.claude"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Color helpers ─────────────────────────────────────────────────────────────
info()    { printf '\033[0;32m[setup]\033[0m  %s\n' "$1"; }
warn()    { printf '\033[0;33m[setup]\033[0m  WARN: %s\n' "$1"; }
err()     { printf '\033[0;31m[setup]\033[0m  ERROR: %s\n' "$1" >&2; }
ok()      { printf '\033[0;32m  ✔\033[0m  %s\n' "$1"; }
fail()    { printf '\033[0;31m  ✘\033[0m  %s\n' "$1"; }
pending() { printf '\033[0;33m  ?\033[0m  %s\n' "$1"; }

PREFLIGHT_ERRORS=0

# ── 0. Pre-flight checks ──────────────────────────────────────────────────────
printf '\n\033[1m[Pre-flight checks]\033[0m\n'

# NVM
if [ -s "${HOME}/.nvm/nvm.sh" ]; then
  ok "NVM found at ~/.nvm"
else
  fail "NVM not found — install from https://github.com/nvm-sh/nvm"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# Node.js (via NVM)
if [ -s "${HOME}/.nvm/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "${HOME}/.nvm/nvm.sh" --no-use
  if NODE_PATH=$(nvm which default 2>/dev/null) && [ -n "$NODE_PATH" ]; then
    NODE_VERSION=$("$NODE_PATH" --version 2>/dev/null || echo "unknown")
    ok "Node.js ${NODE_VERSION} ($(dirname "$NODE_PATH"))"
  else
    fail "Node.js not found via NVM — run: nvm install 20"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi
else
  pending "Node.js check skipped (NVM not available)"
fi

# Claude Code — installed?
CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
if [ -z "$CLAUDE_BIN" ]; then
  # Try common paths
  for p in "${HOME}/.local/bin/claude" "/usr/local/bin/claude"; do
    [ -x "$p" ] && CLAUDE_BIN="$p" && break
  done
fi

if [ -n "$CLAUDE_BIN" ]; then
  CLAUDE_VER=$("$CLAUDE_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  ok "Claude Code installed: ${CLAUDE_VER} (${CLAUDE_BIN})"
else
  fail "Claude Code not installed — install from https://claude.ai/code"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# Claude Code — logged in?
CLAUDE_CREDS="${REAL_CLAUDE}/.credentials.json"
if [ -f "$CLAUDE_CREDS" ]; then
  if python3 -c "import json; d=json.load(open('${CLAUDE_CREDS}')); exit(0 if 'claudeAiOauth' in d else 1)" 2>/dev/null; then
    ok "Claude Code: logged in (OAuth credentials found)"
  else
    warn "Claude Code: credentials file exists but may be incomplete — run: claude"
  fi
else
  fail "Claude Code: not logged in — run: claude   (will open browser for login)"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# Codex CLI — installed?
CODEX_BIN=$(command -v codex 2>/dev/null || true)
if [ -z "$CODEX_BIN" ] && [ -s "${HOME}/.nvm/nvm.sh" ]; then
  # Try via NVM path
  if NODE_BIN_DIR=$(dirname "$(nvm which default 2>/dev/null)" 2>/dev/null); then
    [ -x "${NODE_BIN_DIR}/codex" ] && CODEX_BIN="${NODE_BIN_DIR}/codex"
  fi
fi

if [ -n "$CODEX_BIN" ]; then
  CODEX_VER=$("$CODEX_BIN" --version 2>/dev/null | head -1 || echo "unknown")
  ok "Codex CLI installed: ${CODEX_VER} (${CODEX_BIN})"
else
  fail "Codex CLI not installed — run: npm install -g @openai/codex"
  PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
fi

# Codex CLI — logged in?
if [ -n "$CODEX_BIN" ]; then
  CODEX_STATUS=$("$CODEX_BIN" login status 2>&1 || true)
  if echo "$CODEX_STATUS" | grep -qi "logged in"; then
    ok "Codex CLI: ${CODEX_STATUS}"
  else
    fail "Codex CLI: not logged in — run: codex login   (will open browser for ChatGPT login)"
    PREFLIGHT_ERRORS=$((PREFLIGHT_ERRORS + 1))
  fi
else
  pending "Codex login check skipped (not installed)"
fi

# Abort if critical errors
if [ "$PREFLIGHT_ERRORS" -gt 0 ]; then
  printf '\n\033[0;31m[setup] %d pre-flight check(s) failed. Fix the above issues and re-run install.sh.\033[0m\n\n' "$PREFLIGHT_ERRORS"
  exit 1
fi

printf '\n\033[1m[Installing]\033[0m\n'

# ── 1. Create directory ───────────────────────────────────────────────────────
mkdir -p "${TRIGGER_HOME}"
info "directory: ${TRIGGER_HOME}"

# ── 2. Copy scripts ───────────────────────────────────────────────────────────
info "Installing scripts from ${SRC}..."
for f in keepalive.mjs start.sh; do
  [ -f "${SRC}/${f}" ] || { err "Source file not found: ${SRC}/${f}"; exit 1; }
  if [ "${SRC}/${f}" -ef "${TRIGGER_HOME}/${f}" ]; then
    info "  already in place: ${f}"
  else
    cp -f "${SRC}/${f}" "${TRIGGER_HOME}/${f}"
    info "  installed: ${f}"
  fi
done
chmod 755 "${TRIGGER_HOME}/start.sh"
chmod 644 "${TRIGGER_HOME}/keepalive.mjs"

# ── 3. .claude symlink (shared OAuth credentials) ─────────────────────────────
FAKE_CLAUDE="${TRIGGER_HOME}/.claude"
if [ -L "${FAKE_CLAUDE}" ]; then
  info ".claude symlink already exists, skipping"
elif [ -e "${FAKE_CLAUDE}" ]; then
  warn ".claude exists but is not a symlink — leaving as-is"
else
  ln -s "${REAL_CLAUDE}" "${FAKE_CLAUDE}"
  info ".claude -> ${REAL_CLAUDE}"
fi

# ── 4. Empty CLAUDE.md ────────────────────────────────────────────────────────
CLAUDE_MD="${TRIGGER_HOME}/CLAUDE.md"
if [ ! -f "${CLAUDE_MD}" ]; then
  touch "${CLAUDE_MD}"
  info "CLAUDE.md created (empty)"
else
  info "CLAUDE.md already exists, skipping"
fi

# ── 5. Crontab ────────────────────────────────────────────────────────────────
MARKER="# ai-keepalive"
CRON_LINE="0 7,12,17 * * 1-7 ${TRIGGER_HOME}/start.sh >> ${TRIGGER_HOME}/cron.log 2>&1 ${MARKER}"

EXISTING=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "${EXISTING}" | grep -qF "${MARKER}"; then
  info "crontab entry already exists, skipping"
else
  if [ -z "${EXISTING}" ]; then
    printf '%s\n' "${CRON_LINE}" | crontab -
  else
    printf '%s\n%s\n' "${EXISTING}" "${CRON_LINE}" | crontab -
  fi
  info "crontab installed: 07:00, 12:00, 17:00 UTC (weekdays)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf '\n\033[1m[Summary]\033[0m\n'
info "Directory:"
ls -la "${TRIGGER_HOME}" | grep -v "^total"
printf '\n'
info "Crontab:"
crontab -l 2>/dev/null | grep "ai-keepalive" || warn "No crontab entry found"
printf '\n'
printf '\033[0;32m[setup] Installation complete!\033[0m\n\n'
info "Test now:  ${TRIGGER_HOME}/start.sh"
info "Main log:  ${TRIGGER_HOME}/keepalive.log"
info "Cron log:  ${TRIGGER_HOME}/cron.log"
printf '\n'
