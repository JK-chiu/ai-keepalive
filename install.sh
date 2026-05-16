#!/usr/bin/env bash
# install.sh — one-shot installer for ai-keepalive (idempotent, safe to re-run)
#
# Usage:
#   bash install.sh
#
# Steps:
#   0. Pre-flight: verify NVM, Node.js ≥18, Claude Code login, Codex login
#   1. Create ~/.ai-keepalive/ directory
#   2. Copy keepalive.mjs and start.sh into place
#   3. Create ~/.ai-keepalive/.claude symlink  (shares your OAuth credentials)
#   4. Create empty ~/.ai-keepalive/CLAUDE.md  (prevents loading your personal config)
#   5. Install crontab: 07:00 / 12:00 / 17:00 Asia/Taipei, every day

set -euo pipefail

# ── Paths ─────────────────────────────────────────────────────────────────────
INSTALL_DIR="${HOME}/.ai-keepalive"         # where everything lives
CLAUDE_DIR="${HOME}/.claude"                # your real Claude credentials
KEEPALIVE_CLAUDE_DIR="${INSTALL_DIR}/.claude"  # symlink target inside install dir
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # directory this script lives in

# ── Output helpers ────────────────────────────────────────────────────────────
ok()      { printf '  \033[0;32m✔\033[0m  %s\n'      "$1"; }
fail()    { printf '  \033[0;31m✘\033[0m  %s\n'      "$1"; }
skip()    { printf '  \033[0;33m–\033[0m  %s\n'      "$1"; }
info()    { printf '\033[0;32m[install]\033[0m %s\n'  "$1"; }
warn()    { printf '\033[0;33m[install]\033[0m WARN: %s\n' "$1"; }
abort()   { printf '\033[0;31m[install]\033[0m ERROR: %s\n' "$1" >&2; exit 1; }
header()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ── Pre-flight check helper ───────────────────────────────────────────────────
# Usage: check <pass:true|false> "描述" "失敗時的修正指令"
ERRORS=0
check() {
  local passed="$1" desc="$2" fix="$3"
  if [ "$passed" = "true" ]; then
    ok "$desc"
  else
    fail "$desc"
    printf '       \033[2m→ %s\033[0m\n' "$fix"
    ERRORS=$((ERRORS + 1))
  fi
}

# ── Load NVM once (needed for node/codex path resolution) ────────────────────
NVM_SH="${HOME}/.nvm/nvm.sh"
if [ -s "$NVM_SH" ]; then
  # shellcheck source=/dev/null
  . "$NVM_SH" --no-use   # --no-use: load functions only, don't switch version yet
fi

# ─────────────────────────────────────────────────────────────────────────────
header "[0/5] Pre-flight checks"
# ─────────────────────────────────────────────────────────────────────────────

# NVM
check "$([ -s "$NVM_SH" ] && echo true || echo false)" \
  "NVM found at ~/.nvm" \
  "curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash"

# Node.js — exists and ≥ 18
NODE_BIN=""
NODE_OK=false
if [ -s "$NVM_SH" ]; then
  if NODE_BIN=$(nvm which default 2>/dev/null) && [ -n "$NODE_BIN" ]; then
    NODE_VER=$("$NODE_BIN" -e 'process.stdout.write(String(process.versions.node))' 2>/dev/null || echo "0")
    NODE_MAJOR=${NODE_VER%%.*}
    if [ "${NODE_MAJOR:-0}" -ge 18 ] 2>/dev/null; then
      NODE_OK=true
      ok "Node.js v${NODE_VER}  (${NODE_BIN})"
    else
      fail "Node.js v${NODE_VER} is too old (need ≥ 18)"
      printf '       \033[2m→ nvm install 20\033[0m\n'
      ERRORS=$((ERRORS + 1))
    fi
  else
    check "false" "Node.js not found via NVM" "nvm install 20"
  fi
else
  skip "Node.js check skipped (NVM not available)"
fi

# Resolve NVM bin dir for codex lookup
NODE_BIN_DIR=""
[ -n "$NODE_BIN" ] && NODE_BIN_DIR="$(dirname "$NODE_BIN")"

# Claude Code — installed?
CLAUDE_BIN=""
for p in "$(command -v claude 2>/dev/null)" \
         "${HOME}/.local/bin/claude" \
         "/usr/local/bin/claude"; do
  [ -x "${p:-}" ] && CLAUDE_BIN="$p" && break
done
check "$([ -n "$CLAUDE_BIN" ] && echo true || echo false)" \
  "Claude Code installed${CLAUDE_BIN:+": $("$CLAUDE_BIN" --version 2>/dev/null | head -1)"}" \
  "See https://claude.ai/code"

# Claude Code — logged in?
CLAUDE_CREDS="${CLAUDE_DIR}/.credentials.json"
CLAUDE_AUTHED=false
if [ -f "$CLAUDE_CREDS" ]; then
  python3 -c "import json; d=json.load(open('${CLAUDE_CREDS}')); exit(0 if 'claudeAiOauth' in d else 1)" 2>/dev/null \
    && CLAUDE_AUTHED=true
fi
check "$CLAUDE_AUTHED" \
  "Claude Code: logged in (OAuth token found)" \
  "claude   # opens browser → log in with your Claude subscription"

# Codex CLI — installed?
CODEX_BIN=""
for p in "$(command -v codex 2>/dev/null)" \
         "${NODE_BIN_DIR}/codex"; do
  [ -x "${p:-}" ] && CODEX_BIN="$p" && break
done
check "$([ -n "$CODEX_BIN" ] && echo true || echo false)" \
  "Codex CLI installed${CODEX_BIN:+": $("$CODEX_BIN" --version 2>/dev/null | head -1)"}" \
  "npm install -g @openai/codex"

# Codex CLI — logged in?
CODEX_AUTHED=false
if [ -n "$CODEX_BIN" ]; then
  "$CODEX_BIN" login status 2>&1 | grep -qi "logged in" && CODEX_AUTHED=true
fi
if [ -n "$CODEX_BIN" ]; then
  check "$CODEX_AUTHED" \
    "Codex CLI: logged in (ChatGPT account)" \
    "codex login   # opens browser → log in with your ChatGPT subscription"
else
  skip "Codex login check skipped (not installed)"
fi

# Abort if anything failed
if [ "$ERRORS" -gt 0 ]; then
  printf '\n\033[0;31m%d check(s) failed — fix the above and re-run install.sh\033[0m\n\n' "$ERRORS"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
header "[1/5] Create directory"
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "${INSTALL_DIR}"
info "${INSTALL_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
header "[2/5] Copy scripts"
# ─────────────────────────────────────────────────────────────────────────────
for f in keepalive.mjs start.sh; do
  [ -f "${SRC}/${f}" ] || abort "Source file not found: ${SRC}/${f}"

  # -ef: true when both paths point to the same inode (already in place)
  if [ "${SRC}/${f}" -ef "${INSTALL_DIR}/${f}" ]; then
    info "  already in place: ${f}"
  else
    cp -f "${SRC}/${f}" "${INSTALL_DIR}/${f}"
    info "  copied: ${f}"
  fi
done
chmod 755 "${INSTALL_DIR}/start.sh"
chmod 644 "${INSTALL_DIR}/keepalive.mjs"

# ─────────────────────────────────────────────────────────────────────────────
header "[3/5] .claude symlink"
# ─────────────────────────────────────────────────────────────────────────────
# keepalive.mjs runs claude with HOME=~/.ai-keepalive so it doesn't pick up
# your personal CLAUDE.md. The symlink lets claude still find your OAuth token.
if [ -L "${KEEPALIVE_CLAUDE_DIR}" ]; then
  info "already exists: ${KEEPALIVE_CLAUDE_DIR} -> $(readlink "${KEEPALIVE_CLAUDE_DIR}")"
elif [ -e "${KEEPALIVE_CLAUDE_DIR}" ]; then
  warn "${KEEPALIVE_CLAUDE_DIR} exists but is not a symlink — leaving as-is"
else
  ln -s "${CLAUDE_DIR}" "${KEEPALIVE_CLAUDE_DIR}"
  info "created: ${KEEPALIVE_CLAUDE_DIR} -> ${CLAUDE_DIR}"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "[4/5] CLAUDE.md"
# ─────────────────────────────────────────────────────────────────────────────
# An empty CLAUDE.md here stops claude from searching further up the tree
# and loading your personal project instructions during a keepalive ping.
CLAUDE_MD="${INSTALL_DIR}/CLAUDE.md"
if [ ! -f "${CLAUDE_MD}" ]; then
  touch "${CLAUDE_MD}"
  info "created empty CLAUDE.md"
else
  info "already exists: CLAUDE.md"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "[5/5] Crontab"
# ─────────────────────────────────────────────────────────────────────────────
MARKER="# ai-keepalive"
CRON_TZ_LINE="CRON_TZ=Asia/Taipei"
CRON_LINE="0 7,12,17 * * 1-7 ${INSTALL_DIR}/start.sh >> ${INSTALL_DIR}/cron.log 2>&1 ${MARKER}"

EXISTING=$(crontab -l 2>/dev/null || true)
if printf '%s\n' "${EXISTING}" | grep -qF "${MARKER}"; then
  info "already installed — skipping"
  crontab -l | grep "${MARKER}"
else
  if [ -z "${EXISTING}" ]; then
    printf '%s\n%s\n' "${CRON_TZ_LINE}" "${CRON_LINE}" | crontab -
  else
    printf '%s\n%s\n%s\n' "${EXISTING}" "${CRON_TZ_LINE}" "${CRON_LINE}" | crontab -
  fi
  info "installed: 07:00 / 12:00 / 17:00 Asia/Taipei, every day"
fi

# ─────────────────────────────────────────────────────────────────────────────
header "Done"
# ─────────────────────────────────────────────────────────────────────────────
printf '\n'
info "Directory:  ${INSTALL_DIR}"
info "Main log:   ${INSTALL_DIR}/keepalive.log"
info "Cron log:   ${INSTALL_DIR}/cron.log"
printf '\n'

# Offer to run a test immediately
printf 'Run a test now? [y/N] '
read -r answer
if printf '%s' "$answer" | grep -qi '^y'; then
  printf '\n'
  "${INSTALL_DIR}/start.sh"
fi
