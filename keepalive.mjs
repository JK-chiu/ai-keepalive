#!/usr/bin/env node

// ==========================================================================
// keepalive.mjs — Rolling session window keepalive for AI coding CLIs
// ==========================================================================
//
// ## Usage
//
//   node keepalive.mjs            # run once (one-shot)
//   crontab: 0 7,12,17 * * 1-7 ~/.ai-keepalive/start.sh
//
// ## Setup
//
//   bash setup.sh   # one-shot Linux installer (creates dirs, symlinks, crontab)
//
// ## How the 5-hour rolling window works
//
//   Claude Code (Max/Pro) and Codex CLI (Plus/Pro) each use a 5-hour
//   rolling rate-limit window. The window starts from your FIRST request
//   and resets 5 hours later. If you start coding at 09:00, hit the limit
//   at 10:00, you wait until 14:00 (5h from 09:00).
//
//   This script sends a cheap "hi" ping BEFORE you sit down to work, so
//   the window starts early and resets sooner — reducing your actual wait
//   time from hours to minutes.
//
// ## How this script works
//
//   1. Triggers each CLI in parallel (Claude + Codex) with minimal-token
//      flags (cheapest model, no tools, custom system prompt, etc.)
//   2. Verifies each trigger succeeded by parsing the rate-limit response:
//      - Claude: `rate_limit_event` in --output-format json stdout
//      - Codex: `token_count` event in ~/.codex/sessions/ file
//   3. On failure, applies retry logic based on the window expiry time:
//      - Expires within TOLERANCE (45min) → wait, then retry once
//      - Expires beyond TOLERANCE → skip, wait for the next cron tick
//      - Already expired → retry immediately
//      - Unknown expiry → retry after RETRY_DELAY (30s)
//
// ## Customization
//
//   All tunables are in the constants block below.
//
// ==========================================================================

import { execFile, spawn } from "node:child_process"
import { appendFile, mkdir, readdir, readFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

// ---------------------------------------------------------------------------
// Constants — all tunables live here
// ---------------------------------------------------------------------------

const TOLERANCE_MS = 45 * 60 * 1000   // 45 minutes
const RETRY_DELAY_MS = 30 * 1000      // 30 seconds (fallback when no resetsAt)
const EXEC_TIMEOUT_MS = 60 * 1000     // 60 seconds
const TZ = "Asia/Taipei"
const TRIGGER_HOME = join(homedir(), ".ai-keepalive")
const LOG_FILE = join(TRIGGER_HOME, "keepalive.log")

const AGENTS = [
  {
    name: "claude",
    cwd: "/tmp",
    env: { HOME: TRIGGER_HOME },
    cmd: [
      "claude", "-p", "hi", "--output-format", "stream-json", "--verbose",
      "--model", "haiku",
      "--tools", "",
      "--effort", "low",
      "--system-prompt", "Reply with only the word ok.",
      "--no-session-persistence",
      "--disable-slash-commands",
    ],
    parseResult: parseClaudeResult,
  },
  {
    name: "codex",
    cwd: "/tmp",
    cmd: [
      "codex", "exec", "hi", "--json",
      "--skip-git-repo-check",
      "-C", "/tmp",
      "-m", "gpt-5.4-mini",
      "-c", `model_reasoning_effort="low"`,
      "--disable", "shell_tool",
    ],
    parseResult: parseCodexResult,
  },
]

// ---------------------------------------------------------------------------
// Time formatting (GMT+8)
// ---------------------------------------------------------------------------

function formatTW(date_or_ms) {
  const d = typeof date_or_ms === "number" ? new Date(date_or_ms) : date_or_ms
  const p = new Intl.DateTimeFormat("en-CA", {
    timeZone: TZ,
    year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit",
    hour12: false,
  }).formatToParts(d)
  const g = (type) => p.find((x) => x.type === type)?.value
  return `${g("year")}-${g("month")}-${g("day")}T${g("hour")}:${g("minute")}:${g("second")}+08:00`
}

// Returns "HH:MM:SS" in Taiwan time — used for compact expiry display
function timeTW(ms) {
  return formatTW(ms).slice(11, 19)
}

// Returns "4h 59m", "45m", or "已過期"
function timeUntil(ms) {
  const diff = ms - Date.now()
  if (diff <= 0) return "已過期"
  const h = Math.floor(diff / 3_600_000)
  const m = Math.floor((diff % 3_600_000) / 60_000)
  return h > 0 ? `${h}h ${m}m` : `${m}m`
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

const SEP = "─".repeat(60)

function log(agent_name, status, message = "") {
  const ts = formatTW(new Date())
  const col1 = agent_name.padEnd(9)
  const col2 = status.padEnd(10)
  const suffix = message ? message : ""
  const line = `${ts}  ${col1}  ${col2}  ${suffix}`.trimEnd()

  // Separator before each new run makes runs visually distinct in the log
  const output = (agent_name === "keepalive" && status === "start")
    ? `${SEP}\n${line}`
    : line

  console.log(output)
  appendFile(LOG_FILE, output + "\n").catch(() => {})
}

// ---------------------------------------------------------------------------
// Shell helpers
// ---------------------------------------------------------------------------

function commandExists(cmd) {
  return new Promise((resolve) => {
    execFile("which", [cmd], (err) => resolve(!err))
  })
}

function run(cmd_args, { timeout_ms = EXEC_TIMEOUT_MS, cwd, env } = {}) {
  return new Promise((resolve) => {
    const [cmd, ...args] = cmd_args
    const spawn_env = env ? { ...process.env, ...env } : undefined
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], cwd, env: spawn_env })

    let stdout = ""
    let stderr = ""
    let timed_out = false

    const timer = setTimeout(() => {
      timed_out = true
      child.kill("SIGTERM")
    }, timeout_ms)

    child.stdout.on("data", (chunk) => { stdout += chunk })
    child.stderr.on("data", (chunk) => { stderr += chunk })

    child.on("close", (code) => {
      clearTimeout(timer)
      resolve({
        stdout,
        stderr,
        exit_code: timed_out ? "TIMEOUT" : (code ?? 1),
      })
    })
  })
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

// ---------------------------------------------------------------------------
// Claude Code: parse result
// ---------------------------------------------------------------------------

function parseClaudeResult(stdout) {
  try {
    const items = parseJsonl(stdout)

    const event = items.find((e) => e.type === "rate_limit_event")
    if (!event) return { ok: false, resets_at: null, reply: null, usage: null }

    const info = event.rate_limit_info
    const resets_at = typeof info.resetsAt === "number" ? info.resetsAt * 1000 : null
    const ok = info.status === "allowed" && resets_at !== null

    const result_item = items.find((e) => e.type === "result")
    const reply = result_item?.result ?? null

    // Capture remaining quota if the API returns it
    const usage = {
      requests_remaining: info.requestsRemaining ?? null,
      requests_limit:     info.requestsLimit     ?? null,
      tokens_remaining:   info.tokensRemaining   ?? null,
      tokens_limit:       info.tokensLimit       ?? null,
    }

    return { ok, resets_at, reply, usage }
  } catch {
    return { ok: false, resets_at: null, reply: null, usage: null }
  }
}

// ---------------------------------------------------------------------------
// Codex CLI: parse result
// ---------------------------------------------------------------------------

function parseJsonl(text) {
  return text
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => {
      try { return JSON.parse(line) } catch { return null }
    })
    .filter(Boolean)
}

async function findCodexSessionFile(thread_id) {
  const today = new Date()
  const year = today.getFullYear().toString()
  const month = String(today.getMonth() + 1).padStart(2, "0")
  const day = String(today.getDate()).padStart(2, "0")

  const session_dir = join(homedir(), ".codex", "sessions", year, month, day)

  try {
    const files = await readdir(session_dir)
    const match = files.find((f) => f.includes(thread_id))
    return match ? join(session_dir, match) : null
  } catch {
    return null
  }
}

async function parseCodexResult(stdout) {
  try {
    const events = parseJsonl(stdout)

    const started = events.find((e) => e.type === "thread.started")
    if (!started || !started.thread_id) return { ok: false, resets_at: null, reply: null, usage: null }

    const thread_id = started.thread_id

    // Extract reply from stdout events
    const completed_items = events.filter((e) => e.type === "item.completed")
    let reply = null
    for (const item of completed_items) {
      const texts = item.item?.content
        ?.filter((c) => c.type === "output_text")
        ?.map((c) => c.text)
      if (texts?.length) reply = texts.join("")
    }

    // Read rate limits from session file
    const session_path = await findCodexSessionFile(thread_id)
    if (!session_path) return { ok: false, resets_at: null, reply, usage: null }

    const session_content = await readFile(session_path, "utf-8")
    const session_events = parseJsonl(session_content)

    const token_events = session_events.filter(
      (e) => e.type === "event_msg" && e.payload?.type === "token_count"
    )

    if (token_events.length === 0) return { ok: false, resets_at: null, reply, usage: null }

    const last = token_events[token_events.length - 1]
    const rate_limits = last.payload.rate_limits
    const resets_at_raw = rate_limits?.primary?.resets_at
    const resets_at = typeof resets_at_raw === "number" ? resets_at_raw * 1000 : null
    const ok = resets_at !== null && rate_limits?.rate_limit_reached_type === null

    // Cumulative token counts (all token_count events in this session)
    const tc = last.payload.token_count
    const usage = {
      input_tokens:  tc?.input_tokens  ?? null,
      output_tokens: tc?.output_tokens ?? null,
      total_tokens:  tc?.total_tokens  ?? null,
    }

    return { ok, resets_at, reply, usage }
  } catch {
    return { ok: false, resets_at: null, reply: null, usage: null }
  }
}

// ---------------------------------------------------------------------------
// Result formatting
// ---------------------------------------------------------------------------

// Builds the detail string shown after "ok" or "retry ok"
function formatResultLine(agent_name, result) {
  const parts = []

  if (result.resets_at) {
    parts.push(`視窗到期 ${timeTW(result.resets_at)}  (還剩 ${timeUntil(result.resets_at)})`)
  }

  if (result.usage) {
    const u = result.usage
    if (agent_name === "claude") {
      if (u.requests_remaining != null && u.requests_limit != null)
        parts.push(`請求 ${u.requests_remaining}/${u.requests_limit}`)
      if (u.tokens_remaining != null && u.tokens_limit != null)
        parts.push(`token ${u.tokens_remaining.toLocaleString()}/${u.tokens_limit.toLocaleString()}`)
    } else if (agent_name === "codex") {
      if (u.total_tokens != null)
        parts.push(`本次 token ${u.total_tokens}`)
    }
  }

  return parts.join("  │  ")
}

// ---------------------------------------------------------------------------
// Core trigger logic
// ---------------------------------------------------------------------------

async function triggerAgent(agent) {
  const exists = await commandExists(agent.cmd[0])
  if (!exists) {
    log(agent.name, "skip", `${agent.cmd[0]} not found`)
    return
  }

  const result = await attemptTrigger(agent)

  if (result.ok) {
    log(agent.name, "ok", formatResultLine(agent.name, result))
    return
  }

  const now = Date.now()

  if (result.resets_at !== null) {
    const wait_ms = result.resets_at - now

    if (wait_ms <= 0) {
      log(agent.name, "fail", `視窗已過期，立即重試`)
      await retryTrigger(agent)
      return
    }

    if (wait_ms <= TOLERANCE_MS) {
      log(agent.name, "fail", `視窗 ${timeTW(result.resets_at)} 即將到期 (還剩 ${timeUntil(result.resets_at)})，等待後重試`)
      await sleep(wait_ms)
      await retryTrigger(agent)
      return
    }

    log(agent.name, "skip", `視窗到期 ${timeTW(result.resets_at)} (還剩 ${timeUntil(result.resets_at)})，超出容忍範圍，等下次 cron`)
    return
  }

  log(agent.name, "fail", `無法取得視窗到期時間，${RETRY_DELAY_MS / 1000}s 後重試`)
  await sleep(RETRY_DELAY_MS)
  await retryTrigger(agent)
}

async function attemptTrigger(agent) {
  const { stdout, stderr, exit_code } = await run(agent.cmd, { cwd: agent.cwd, env: agent.env })

  if (exit_code === "TIMEOUT") {
    log(agent.name, "fail", "指令逾時 (60s)")
    return { ok: false, resets_at: null, reply: null, usage: null }
  }

  if (exit_code !== 0 && !stdout) {
    const hint = stderr ? stderr.split("\n")[0].slice(0, 200) : ""
    log(agent.name, "fail", `exit ${exit_code}${hint ? "  — " + hint : ""}`)
    return { ok: false, resets_at: null, reply: null, usage: null }
  }

  return await agent.parseResult(stdout)
}

async function retryTrigger(agent) {
  const result = await attemptTrigger(agent)
  const detail = formatResultLine(agent.name, result)

  if (result.ok) {
    log(agent.name, "retry ok", detail)
  } else {
    log(agent.name, "retry fail", detail || "—")
  }
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  await mkdir(TRIGGER_HOME, { recursive: true }).catch(() => {})
  const start_ms = Date.now()
  log("keepalive", "start", `pid=${process.pid}  node=${process.version}`)
  await Promise.all(AGENTS.map((agent) => triggerAgent(agent)))
  const elapsed = ((Date.now() - start_ms) / 1000).toFixed(1)
  log("keepalive", "done", `${elapsed}s`)
}

main().catch((err) => {
  console.error("keepalive fatal:", err)
  process.exit(1)
})
