#!/usr/bin/env bash
# keepalive.sh — rolling session-window keepalive for AI coding CLIs
#
# Requires: NVM, jq, claude (~/.local/bin or PATH), codex (npm global via NVM)

set -uo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

TOLERANCE_SECS=$((45 * 60))     # window expiry tolerance before retry
RETRY_DELAY_SECS=30              # fallback wait when resets_at unknown
EXEC_TIMEOUT_SECS=60             # per-CLI hard timeout
TZ_VAL="Asia/Taipei"
KEEPALIVE_HOME="${HOME}/.ai-keepalive"
LOG_FILE="${KEEPALIVE_HOME}/keepalive.log"
SEP="────────────────────────────────────────────────────────────"

# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

now_secs() { date +%s; }

# HH:MM:SS in Taiwan time from unix seconds
time_tw() { TZ="$TZ_VAL" date -d "@$1" '+%H:%M:%S'; }

# "4h 59m", "45m", or "已過期"
time_until() {
  local diff=$(( $1 - $(now_secs) ))
  [ "$diff" -le 0 ] && { printf '已過期'; return; }
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  [ "$h" -gt 0 ] && printf '%dh %dm' "$h" "$m" || printf '%dm' "$m"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
#
# Writes to LOG_FILE always; also prints to stderr when running interactively.
# stderr output is gated by [ -t 2 ] to avoid duplicate lines when cron
# redirects stderr to the same log file via 2>&1.

log() {
  local agent="$1" status="$2" message="${3:-}"
  local ts
  ts=$(TZ="$TZ_VAL" date '+%Y-%m-%dT%H:%M:%S+08:00')
  local line
  line="$(printf '%s  %-9s  %-10s' "$ts" "$agent" "$status")"
  [ -n "$message" ] && line="${line}  ${message}"

  local output="$line"
  [ "$agent" = "keepalive" ] && [ "$status" = "start" ] && \
    output="${SEP}"$'\n'"${line}"

  # Always write to log file
  printf '%s\n' "$output" >> "$LOG_FILE"
  # Print to stderr only when running interactively (tty available)
  # This avoids duplicate writes when cron redirects stderr → log file
  [ -t 2 ] && printf '%s\n' "$output" >&2 || true
}

# ---------------------------------------------------------------------------
# Format result line
# ---------------------------------------------------------------------------

format_result() {
  local resets_at="$1"
  [ -z "$resets_at" ] || [ "$resets_at" = "null" ] && return
  printf '視窗到期 %s  (還剩 %s)' "$(time_tw "$resets_at")" "$(time_until "$resets_at")"
}

# ---------------------------------------------------------------------------
# Claude — attempt once
# ---------------------------------------------------------------------------
# Outputs: resets_at (unix secs) on stdout
# Returns: 0=ok, 1=fail

attempt_claude() {
  local tmpfile exit_code=0
  tmpfile=$(mktemp)

  env HOME="$KEEPALIVE_HOME" timeout "$EXEC_TIMEOUT_SECS" \
    claude \
    -p "hi" \
    --output-format stream-json --verbose \
    --model haiku \
    --tools "" \
    --effort low \
    --system-prompt "Reply with only the word ok." \
    --no-session-persistence \
    --disable-slash-commands \
    >"$tmpfile" 2>/dev/null || exit_code=$?

  if [ "$exit_code" -eq 124 ]; then
    log "claude" "fail" "指令逾時 (${EXEC_TIMEOUT_SECS}s)"
    rm -f "$tmpfile"; return 1
  fi

  if [ "$exit_code" -ne 0 ] && [ ! -s "$tmpfile" ]; then
    log "claude" "fail" "exit ${exit_code}"
    rm -f "$tmpfile"; return 1
  fi

  local rate_line
  rate_line=$(grep -m1 '"type":"rate_limit_event"' "$tmpfile" || true)
  rm -f "$tmpfile"

  [ -z "$rate_line" ] && return 1

  local status resets_at
  status=$(printf '%s' "$rate_line"   | jq -r '.rate_limit_info.status')
  resets_at=$(printf '%s' "$rate_line" | jq -r '.rate_limit_info.resetsAt')

  printf '%s' "$resets_at"
  [ "$status" = "allowed" ] && [ -n "$resets_at" ] && [ "$resets_at" != "null" ]
}

# ---------------------------------------------------------------------------
# Codex — attempt once
# ---------------------------------------------------------------------------
# Outputs: resets_at (unix secs) on stdout
# Returns: 0=ok, 1=fail

attempt_codex() {
  local exit_code=0
  timeout "$EXEC_TIMEOUT_SECS" \
    codex exec "hi" --json \
    --skip-git-repo-check \
    -C /tmp \
    -m gpt-5.4-mini \
    -c 'model_reasoning_effort="low"' \
    --disable shell_tool \
    >/dev/null 2>/dev/null || exit_code=$?

  if [ "$exit_code" -eq 124 ]; then
    log "codex" "fail" "指令逾時 (${EXEC_TIMEOUT_SECS}s)"
    return 1
  fi

  if [ "$exit_code" -ne 0 ]; then
    log "codex" "fail" "exit ${exit_code}"
    return 1
  fi

  # Newest session file = the run we just triggered
  local today session_file
  today=$(date +%Y/%m/%d)
  session_file=$(ls -t "$HOME/.codex/sessions/$today"/rollout-*.jsonl 2>/dev/null | head -1)

  [ -z "$session_file" ] && return 1

  local resets_at rate_reached
  resets_at=$(grep '"type":"event_msg"' "$session_file" \
    | jq -r 'select(.payload.type=="token_count") | .payload.rate_limits.primary.resets_at' \
    | tail -1)
  rate_reached=$(grep '"type":"event_msg"' "$session_file" \
    | jq -r 'select(.payload.type=="token_count") | .payload.rate_limits.rate_limit_reached_type' \
    | tail -1)

  printf '%s' "$resets_at"
  # rate_limits null → Codex API no longer returns window data; command still ran OK
  [ -z "$resets_at" ] || [ "$resets_at" = "null" ] && return 0
  [ "$rate_reached" = "null" ]
}

# ---------------------------------------------------------------------------
# Trigger agent with retry logic
# ---------------------------------------------------------------------------

trigger_agent() {
  local name="$1"
  local fn="attempt_${name}"

  if ! command -v "$name" >/dev/null 2>&1; then
    log "$name" "skip" "${name} not found"
    return
  fi

  local resets_at ok=0
  resets_at=$($fn) || ok=$?

  if [ "$ok" -eq 0 ]; then
    log "$name" "ok" "$(format_result "$resets_at")"
    return
  fi

  local now wait_secs
  now=$(now_secs)

  if [ -n "$resets_at" ] && [ "$resets_at" != "null" ]; then
    wait_secs=$(( resets_at - now ))

    if [ "$wait_secs" -le 0 ]; then
      log "$name" "fail" "視窗已過期，立即重試"
      ok=0; resets_at=$($fn) || ok=$?

    elif [ "$wait_secs" -le "$TOLERANCE_SECS" ]; then
      log "$name" "fail" \
        "視窗 $(time_tw "$resets_at") 即將到期 (還剩 $(time_until "$resets_at"))，等待後重試"
      sleep "$wait_secs"
      ok=0; resets_at=$($fn) || ok=$?

    else
      log "$name" "skip" \
        "視窗到期 $(time_tw "$resets_at") (還剩 $(time_until "$resets_at"))，超出容忍範圍，等下次 cron"
      return
    fi

  else
    log "$name" "fail" "無法取得視窗到期時間，${RETRY_DELAY_SECS}s 後重試"
    sleep "$RETRY_DELAY_SECS"
    ok=0; resets_at=$($fn) || ok=$?
  fi

  local detail
  detail=$(format_result "$resets_at")
  if [ "$ok" -eq 0 ]; then
    log "$name" "retry ok"   "$detail"
  else
    log "$name" "retry fail" "$detail"
  fi
}

# ---------------------------------------------------------------------------
# PATH setup via NVM (needed so codex can be found)
# ---------------------------------------------------------------------------

setup_path() {
  local nvm_sh="${HOME}/.nvm/nvm.sh"
  if [ ! -s "$nvm_sh" ]; then
    log "keepalive" "fail" "NVM not found at ${nvm_sh}"
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$nvm_sh" --no-use   # load functions only, no version switch
  local node_bin
  node_bin=$(nvm which default 2>/dev/null) || {
    log "keepalive" "fail" "nvm which default failed"
    exit 1
  }
  export PATH="$(dirname "$node_bin"):${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  mkdir -p "$KEEPALIVE_HOME"
  local start_ts
  start_ts=$(now_secs)
  log "keepalive" "start" "pid=$$"

  setup_path

  trigger_agent "claude" &
  trigger_agent "codex" &
  wait

  local elapsed=$(( $(now_secs) - start_ts ))
  log "keepalive" "done" "${elapsed}s"
}

main
