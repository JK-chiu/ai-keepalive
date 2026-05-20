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

# Taiwan-time clock from unix seconds. Pass "date" as $2 to prefix MM-DD
# (used for weekly windows, which can be days away).
time_tw() {
  local fmt='+%H:%M:%S'
  [ "${2:-}" = "date" ] && fmt='+%m-%d %H:%M:%S'
  TZ="$TZ_VAL" date -d "@$1" "$fmt"
}

# "4d 15h", "4h 59m", "45m", or "expired"
time_until() {
  local diff=$(( $1 - $(now_secs) ))
  [ "$diff" -le 0 ] && { printf 'expired'; return; }
  local d=$(( diff / 86400 ))
  local h=$(( (diff % 86400) / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"
  fi
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
# Rate-limit window labels
# ---------------------------------------------------------------------------

# Map a rateLimitType string to a short tag.
limit_label() {
  case "$1" in
    five_hour)        printf '[5h]' ;;
    seven_day|weekly) printf '[7d]' ;;
    "")               ;;
    *)                printf '[%s]' "$1" ;;
  esac
}

is_weekly() { [ "$1" = "seven_day" ] || [ "$1" = "weekly" ]; }

# Split an attempt function's "resets_at|limit_type|status" stdout into
# ATTEMPT_RESETS, ATTEMPT_LIMIT and ATTEMPT_STATUS.
parse_attempt_output() {
  local raw="$1" rest
  ATTEMPT_RESETS="${raw%%|*}"
  rest="${raw#*|}"
  if [ "$rest" = "$raw" ]; then ATTEMPT_LIMIT=''; ATTEMPT_STATUS=''; return; fi
  ATTEMPT_LIMIT="${rest%%|*}"
  if [ "${rest#*|}" = "$rest" ]; then ATTEMPT_STATUS=''; else ATTEMPT_STATUS="${rest#*|}"; fi
}

# ---------------------------------------------------------------------------
# Format result line
# ---------------------------------------------------------------------------

format_result() {
  local resets_at="$1" limit_type="${2:-}"
  { [ -z "$resets_at" ] || [ "$resets_at" = "null" ]; } && return

  local label datearg=''
  label=$(limit_label "$limit_type")
  is_weekly "$limit_type" && datearg='date'

  local body
  body="window resets at $(time_tw "$resets_at" "$datearg")  (remaining $(time_until "$resets_at"))"
  if [ -n "$label" ]; then printf '%s %s' "$label" "$body"; else printf '%s' "$body"; fi
}

# ---------------------------------------------------------------------------
# Claude — attempt once
# ---------------------------------------------------------------------------
# Outputs: "resets_at|limit_type|status" on stdout
# Returns: 0=ok (rate_limit_event seen), 1=fail (no event / timeout / exit)

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
    log "claude" "fail" "command timeout (${EXEC_TIMEOUT_SECS}s)"
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

  local status resets_at limit_type
  status=$(printf '%s' "$rate_line"     | jq -r '.rate_limit_info.status // empty')
  resets_at=$(printf '%s' "$rate_line"  | jq -r '.rate_limit_info.resetsAt // empty')
  limit_type=$(printf '%s' "$rate_line" | jq -r '.rate_limit_info.rateLimitType // empty')

  # A rate_limit_event means the request was delivered → ping succeeded,
  # regardless of the quota status field.
  printf '%s|%s|%s' "$resets_at" "$limit_type" "$status"
}

# ---------------------------------------------------------------------------
# Codex — attempt once
# ---------------------------------------------------------------------------
# Outputs: "resets_at||" on stdout (limit_type and status left empty)
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
    log "codex" "fail" "command timeout (${EXEC_TIMEOUT_SECS}s)"
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

  printf '%s||' "$resets_at"
  # rate_limits null → Codex API no longer returns window data; command still ran OK
  { [ -z "$resets_at" ] || [ "$resets_at" = "null" ]; } && return 0
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

  local raw ok=0
  raw=$($fn) || ok=$?
  parse_attempt_output "$raw"
  local resets_at="$ATTEMPT_RESETS" limit_type="$ATTEMPT_LIMIT" status="$ATTEMPT_STATUS"

  if [ "$ok" -eq 0 ]; then
    local line
    line="$(format_result "$resets_at" "$limit_type")"
    if [ -n "$status" ] && [ "$status" != "allowed" ]; then
      line="${line:+$line }status=${status}"
    fi
    log "$name" "ok" "$line"
    return
  fi

  local now wait_secs label prefix='' datearg=''
  now=$(now_secs)
  label=$(limit_label "$limit_type")
  [ -n "$label" ] && prefix="${label} "
  is_weekly "$limit_type" && datearg='date'

  if [ -n "$resets_at" ] && [ "$resets_at" != "null" ]; then
    wait_secs=$(( resets_at - now ))

    if [ "$wait_secs" -le 0 ]; then
      log "$name" "fail" "${prefix}window expired; retrying now"
      ok=0; raw=$($fn) || ok=$?
      parse_attempt_output "$raw"
      resets_at="$ATTEMPT_RESETS"; limit_type="$ATTEMPT_LIMIT"

    elif [ "$wait_secs" -le "$TOLERANCE_SECS" ]; then
      log "$name" "fail" \
        "${prefix}window resets at $(time_tw "$resets_at" "$datearg") soon (remaining $(time_until "$resets_at")); waiting then retrying"
      sleep "$wait_secs"
      ok=0; raw=$($fn) || ok=$?
      parse_attempt_output "$raw"
      resets_at="$ATTEMPT_RESETS"; limit_type="$ATTEMPT_LIMIT"

    else
      log "$name" "skip" \
        "${prefix}window resets at $(time_tw "$resets_at" "$datearg") (remaining $(time_until "$resets_at")); outside tolerance, wait for next schedule"
      return
    fi

  else
    log "$name" "fail" "could not get window reset time; retrying after ${RETRY_DELAY_SECS}s"
    sleep "$RETRY_DELAY_SECS"
    ok=0; raw=$($fn) || ok=$?
    parse_attempt_output "$raw"
    resets_at="$ATTEMPT_RESETS"; limit_type="$ATTEMPT_LIMIT"
  fi

  local detail
  detail=$(format_result "$resets_at" "$limit_type")
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
