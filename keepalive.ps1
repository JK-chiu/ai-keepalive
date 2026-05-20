param()

# keepalive.ps1 - rolling session-window keepalive for AI coding CLIs on Windows

$ErrorActionPreference = "Continue"

$ToleranceSecs = 45 * 60
$RetryDelaySecs = 30
$ExecTimeoutSecs = 60
$TimeZoneId = "Taipei Standard Time"
$KeepaliveHome = Join-Path $env:USERPROFILE ".ai-keepalive"
$LogFile = Join-Path $KeepaliveHome "keepalive.log"
$Sep = "------------------------------------------------------------"

function Get-NowSecs {
  return [DateTimeOffset]::Now.ToUnixTimeSeconds()
}

function Convert-ToResetEpoch {
  param([object]$Value)

  if ($null -eq $Value) { return $null }
  $text = [string]$Value
  if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "null") { return $null }

  $epoch = 0L
  if ([long]::TryParse($text, [ref]$epoch)) { return $epoch }

  try {
    return ([DateTimeOffset]::Parse($text)).ToUnixTimeSeconds()
  } catch {
    return $null
  }
}

function Format-TwTime {
  param([long]$Epoch)

  $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
  $dt = [DateTimeOffset]::FromUnixTimeSeconds($Epoch)
  return [TimeZoneInfo]::ConvertTime($dt, $tz).ToString("HH:mm:ss")
}

function Format-TimeUntil {
  param([long]$Epoch)

  $diff = $Epoch - (Get-NowSecs)
  if ($diff -le 0) { return "expired" }

  $h = [math]::Floor($diff / 3600)
  $m = [math]::Floor(($diff % 3600) / 60)
  if ($h -gt 0) { return ("{0}h {1}m" -f $h, $m) }
  return ("{0}m" -f $m)
}

function Write-KeepaliveLog {
  param(
    [string]$Agent,
    [string]$Status,
    [string]$Message = ""
  )

  New-Item -ItemType Directory -Force -Path $KeepaliveHome | Out-Null

  $tz = [TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
  $now = [TimeZoneInfo]::ConvertTime([DateTimeOffset]::Now, $tz)
  $ts = $now.ToString("yyyy-MM-ddTHH:mm:ss+08:00")
  $line = "{0}  {1,-9}  {2,-10}" -f $ts, $Agent, $Status
  if ($Message) { $line = "$line  $Message" }

  $output = $line
  if ($Agent -eq "keepalive" -and $Status -eq "start") {
    $output = "$Sep`n$line"
  }

  Add-Content -Path $LogFile -Value $output -Encoding UTF8
  if ([Environment]::UserInteractive) {
    Write-Host $output
  }
}

function Format-Result {
  param([Nullable[long]]$ResetsAt)

  if ($null -eq $ResetsAt) { return "" }
  return "window resets at $(Format-TwTime $ResetsAt)  (remaining $(Format-TimeUntil $ResetsAt))"
}

function Invoke-CommandWithTimeout {
  param(
    [string]$Command,
    [string[]]$Arguments,
    [hashtable]$Environment = @{}
  )

  $job = Start-Job -ScriptBlock {
    param($Command, $Arguments, $Environment)

    foreach ($key in $Environment.Keys) {
      [Environment]::SetEnvironmentVariable($key, [string]$Environment[$key], "Process")
    }

    & $Command @Arguments 2>$null
    $LASTEXITCODE
  } -ArgumentList $Command, $Arguments, $Environment

  if (-not (Wait-Job -Job $job -Timeout $ExecTimeoutSecs)) {
    Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{ TimedOut = $true; ExitCode = 124; Output = @() }
  }

  $output = @(Receive-Job -Job $job)
  Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

  $exitCode = 0
  if ($output.Count -gt 0) {
    $last = $output[-1]
    $parsed = 0
    if ([int]::TryParse([string]$last, [ref]$parsed)) {
      $exitCode = $parsed
      if ($output.Count -gt 1) {
        $output = $output[0..($output.Count - 2)]
      } else {
        $output = @()
      }
    }
  }

  return [pscustomobject]@{ TimedOut = $false; ExitCode = $exitCode; Output = $output }
}

function Invoke-ClaudeAttempt {
  $envMap = @{ HOME = $KeepaliveHome; USERPROFILE = $KeepaliveHome }
  $args = @(
    "-p", "hi",
    "--output-format", "stream-json",
    "--verbose",
    "--model", "haiku",
    "--tools", "",
    "--effort", "low",
    "--system-prompt", "Reply with only the word ok.",
    "--no-session-persistence",
    "--disable-slash-commands"
  )

  $result = Invoke-CommandWithTimeout -Command "claude" -Arguments $args -Environment $envMap
  if ($result.TimedOut) {
    Write-KeepaliveLog "claude" "fail" "command timeout (${ExecTimeoutSecs}s)"
    return [pscustomobject]@{ Ok = $false; ResetsAt = $null; Message = "" }
  }
  if ($result.ExitCode -ne 0 -and $result.Output.Count -eq 0) {
    Write-KeepaliveLog "claude" "fail" "exit $($result.ExitCode)"
    return [pscustomobject]@{ Ok = $false; ResetsAt = $null; Message = "" }
  }

  foreach ($line in $result.Output) {
    try {
      $event = $line | ConvertFrom-Json
    } catch {
      continue
    }

    if ($event.type -eq "rate_limit_event") {
      $resetsAt = Convert-ToResetEpoch $event.rate_limit_info.resetsAt
      $ok = ($event.rate_limit_info.status -eq "allowed" -and $null -ne $resetsAt)
      return [pscustomobject]@{ Ok = $ok; ResetsAt = $resetsAt; Message = "" }
    }
  }

  return [pscustomobject]@{ Ok = $false; ResetsAt = $null; Message = "" }
}

function Invoke-CodexAttempt {
  $args = @(
    "exec", "hi",
    "--json",
    "--skip-git-repo-check",
    "-C", $env:TEMP,
    "-m", "gpt-5.4-mini",
    "-c", 'model_reasoning_effort="low"',
    "--disable", "shell_tool"
  )

  $result = Invoke-CommandWithTimeout -Command "codex" -Arguments $args
  if ($result.TimedOut) {
    Write-KeepaliveLog "codex" "fail" "command timeout (${ExecTimeoutSecs}s)"
    return [pscustomobject]@{ Ok = $false; ResetsAt = $null; Message = "" }
  }
  if ($result.ExitCode -ne 0) {
    Write-KeepaliveLog "codex" "fail" "exit $($result.ExitCode)"
    return [pscustomobject]@{ Ok = $false; ResetsAt = $null; Message = "" }
  }

  $today = Get-Date -Format "yyyy\\MM\\dd"
  $sessionDir = Join-Path (Join-Path $env:USERPROFILE ".codex\sessions") $today
  $sessionFile = Get-ChildItem -Path $sessionDir -Filter "rollout-*.jsonl" -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

  if ($null -eq $sessionFile) {
    return [pscustomobject]@{ Ok = $true; ResetsAt = $null; Message = "triggered; Codex did not report window reset time" }
  }

  $resetsAt = $null
  $rateReached = $null
  foreach ($line in Get-Content -Path $sessionFile.FullName -ErrorAction SilentlyContinue) {
    if ($line -notmatch '"token_count"') { continue }
    try {
      $event = $line | ConvertFrom-Json
    } catch {
      continue
    }

    if ($event.type -eq "event_msg" -and $event.payload.type -eq "token_count" -and $null -ne $event.payload.rate_limits) {
      $candidate = Convert-ToResetEpoch $event.payload.rate_limits.primary.resets_at
      if ($null -ne $candidate) {
        $resetsAt = $candidate
        $rateReached = $event.payload.rate_limits.rate_limit_reached_type
      }
    }
  }

  if ($null -eq $resetsAt) {
    return [pscustomobject]@{ Ok = $true; ResetsAt = $null; Message = "triggered; Codex did not report window reset time" }
  }

  $ok = ($null -eq $rateReached -or [string]$rateReached -eq "null")
  return [pscustomobject]@{ Ok = $ok; ResetsAt = $resetsAt; Message = "" }
}

function Invoke-Agent {
  param([string]$Name)

  if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
    Write-KeepaliveLog $Name "skip" "$Name not found"
    return
  }

  $attemptFn = if ($Name -eq "claude") { "Invoke-ClaudeAttempt" } else { "Invoke-CodexAttempt" }
  $result = & $attemptFn

  if ($result.Ok) {
    $message = if ($result.Message) { $result.Message } else { Format-Result $result.ResetsAt }
    Write-KeepaliveLog $Name "ok" $message
    return
  }

  $now = Get-NowSecs
  if ($null -ne $result.ResetsAt) {
    $waitSecs = $result.ResetsAt - $now

    if ($waitSecs -le 0) {
      Write-KeepaliveLog $Name "fail" "window expired; retrying now"
      $result = & $attemptFn
    } elseif ($waitSecs -le $ToleranceSecs) {
      Write-KeepaliveLog $Name "fail" "window resets at $(Format-TwTime $result.ResetsAt) soon (remaining $(Format-TimeUntil $result.ResetsAt)); waiting then retrying"
      Start-Sleep -Seconds $waitSecs
      $result = & $attemptFn
    } else {
      Write-KeepaliveLog $Name "skip" "window resets at $(Format-TwTime $result.ResetsAt) (remaining $(Format-TimeUntil $result.ResetsAt)); outside tolerance, wait for next schedule"
      return
    }
  } else {
    Write-KeepaliveLog $Name "fail" "could not get window reset time; retrying after ${RetryDelaySecs}s"
    Start-Sleep -Seconds $RetryDelaySecs
    $result = & $attemptFn
  }

  $detail = Format-Result $result.ResetsAt
  if ($result.Message) { $detail = $result.Message }
  if ($result.Ok) {
    Write-KeepaliveLog $Name "retry ok" $detail
  } else {
    Write-KeepaliveLog $Name "retry fail" $detail
  }
}

function Main {
  New-Item -ItemType Directory -Force -Path $KeepaliveHome | Out-Null
  $start = Get-NowSecs
  Write-KeepaliveLog "keepalive" "start" "pid=$PID"

  $scriptPath = $PSCommandPath
  $jobs = @()
  $jobs += Start-Job -Name "ai-keepalive-claude" -FilePath $scriptPath -ArgumentList @("__agent", "claude")
  $jobs += Start-Job -Name "ai-keepalive-codex" -FilePath $scriptPath -ArgumentList @("__agent", "codex")
  Wait-Job -Job $jobs | Out-Null

  foreach ($job in $jobs) {
    $agent = if ($job.Name -match 'claude') {
      "claude"
    } elseif ($job.Name -match 'codex') {
      "codex"
    } else {
      "job"
    }

    if ($job.State -eq "Failed") {
      $reason = $job.ChildJobs[0].JobStateInfo.Reason
      if ($reason) {
        Write-KeepaliveLog $agent "fail" "job failed: $($reason.Message)"
      } else {
        Write-KeepaliveLog $agent "fail" "job failed"
      }
    }

    foreach ($child in $job.ChildJobs) {
      foreach ($err in $child.Error) {
        $message = $err.Exception.Message
        if (-not [string]::IsNullOrWhiteSpace($message)) {
          Write-KeepaliveLog $agent "fail" "job error: $message"
        }
      }
    }
  }

  Remove-Job -Job $jobs -Force -ErrorAction SilentlyContinue

  $elapsed = (Get-NowSecs) - $start
  Write-KeepaliveLog "keepalive" "done" "${elapsed}s"
}

if ($args.Count -ge 2 -and $args[0] -eq "__agent") {
  Invoke-Agent $args[1]
} else {
  Main
}
