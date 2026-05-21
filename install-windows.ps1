param()

# install-windows.ps1 - one-shot installer for ai-keepalive on Windows

$ErrorActionPreference = "Continue"

$InstallDir = Join-Path $env:USERPROFILE ".ai-keepalive"
$ClaudeDir = Join-Path $env:USERPROFILE ".claude"
$KeepaliveClaudeDir = Join-Path $InstallDir ".claude"
$SourceDir = Split-Path -Parent $PSCommandPath
$TaskName = "ai-keepalive"
$Errors = 0
$UsableAgents = @()

function Write-Ok { param([string]$Text) Write-Host "  [ok]   $Text" -ForegroundColor Green }
function Write-Fail { param([string]$Text, [string]$Fix) Write-Host "  [fail] $Text" -ForegroundColor Red; Write-Host "         -> $Fix" -ForegroundColor DarkGray; $script:Errors++ }
function Write-Info { param([string]$Text) Write-Host "[install] $Text" -ForegroundColor Green }
function Write-Warn { param([string]$Text) Write-Host "[install] WARN: $Text" -ForegroundColor Yellow }
function Write-Header { param([string]$Text) Write-Host ""; Write-Host $Text -ForegroundColor White }

function Test-JsonProperty {
  param([string]$Path, [string]$Property)
  if (-not (Test-Path $Path)) { return $false }
  try {
    $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
    return ($null -ne $json.$Property)
  } catch {
    return $false
  }
}

Write-Header "[0/5] Pre-flight checks"

if ($PSVersionTable.PSVersion.Major -ge 5) {
  Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
} else {
  Write-Fail "PowerShell 5+ required" "Install Windows PowerShell 5.1 or PowerShell 7"
}

$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($null -ne $claudeCmd) {
  $claudeVersion = (& claude --version 2>$null | Select-Object -First 1)
  Write-Ok "Claude Code installed: $claudeVersion ($($claudeCmd.Source))"

  $claudeCreds = Join-Path $ClaudeDir ".credentials.json"
  if (Test-JsonProperty -Path $claudeCreds -Property "claudeAiOauth") {
    Write-Ok "Claude Code logged in (OAuth token found)"
    $UsableAgents += "claude"
  } else {
    Write-Warn "Claude Code not logged in - Claude keepalive will be skipped"
  }
} else {
  Write-Warn "Claude Code CLI not found - Claude keepalive will be skipped"
}

$codexCmd = Get-Command codex -ErrorAction SilentlyContinue
if ($null -ne $codexCmd) {
  $codexVersion = (& codex --version 2>$null | Select-Object -First 1)
  Write-Ok "Codex CLI installed: $codexVersion ($($codexCmd.Source))"
} else {
  Write-Warn "Codex CLI not found - Codex keepalive will be skipped"
}

if ($null -ne $codexCmd) {
  $codexUsable = $true
  $status = (& codex login status 2>&1 | Out-String)
  if ($status -match "(?im)^\s*Logged in\b") {
    Write-Ok "Codex CLI logged in"
  } else {
    Write-Warn "Codex CLI not logged in - Codex keepalive will be skipped"
    $codexUsable = $false
  }

  $codexSource = [string]$codexCmd.Source
  $appDataNpm = Join-Path $env:APPDATA "npm"
  $isNpmShim = $codexSource.EndsWith(".ps1", [StringComparison]::OrdinalIgnoreCase) -or
    $codexSource.StartsWith($appDataNpm, [StringComparison]::OrdinalIgnoreCase)
  if ($isNpmShim) {
    if ($null -ne (Get-Command node -ErrorAction SilentlyContinue)) {
      Write-Ok "Node.js available: $(& node --version 2>$null)"
    } else {
      Write-Warn "Node.js missing for npm-based Codex CLI - Codex keepalive will be skipped"
      $codexUsable = $false
    }

    if ($null -ne (Get-Command npm -ErrorAction SilentlyContinue)) {
      Write-Ok "npm available: $(& npm --version 2>$null)"
    } else {
      Write-Warn "npm missing for npm-based Codex CLI - Codex keepalive will be skipped"
      $codexUsable = $false
    }
  }

  if ($codexUsable) {
    $UsableAgents += "codex"
  }
}

if ($UsableAgents.Count -eq 0) {
  Write-Fail "No usable AI CLI found" "Install and login to Claude Code CLI or Codex CLI"
}

if ($Errors -gt 0) {
  Write-Host ""
  Write-Host "$Errors check(s) failed - fix the above and re-run install-windows.ps1" -ForegroundColor Red
  exit 1
}

Write-Header "[1/5] Create directory"
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Write-Info $InstallDir

Write-Header "[2/5] Copy scripts"
$sourceKeepalive = Join-Path $SourceDir "keepalive.ps1"
$targetKeepalive = Join-Path $InstallDir "keepalive.ps1"
if (-not (Test-Path $sourceKeepalive)) {
  Write-Host "[install] ERROR: Source file not found: $sourceKeepalive" -ForegroundColor Red
  exit 1
}
if ((Resolve-Path $sourceKeepalive).Path -eq (Resolve-Path $targetKeepalive -ErrorAction SilentlyContinue)?.Path) {
  Write-Info "already in place: keepalive.ps1"
} else {
  Copy-Item -Path $sourceKeepalive -Destination $targetKeepalive -Force
  Write-Info "copied: keepalive.ps1"
}

Write-Header "[3/5] .claude junction"
if ($UsableAgents -contains "claude") {
  if (Test-Path $KeepaliveClaudeDir) {
    $item = Get-Item $KeepaliveClaudeDir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      Write-Info "already exists: $KeepaliveClaudeDir"
    } else {
      Write-Warn "$KeepaliveClaudeDir exists but is not a junction/symlink - leaving as-is"
    }
  } else {
    New-Item -ItemType Junction -Path $KeepaliveClaudeDir -Target $ClaudeDir | Out-Null
    Write-Info "created: $KeepaliveClaudeDir -> $ClaudeDir"
  }
} else {
  Write-Warn "Claude not configured - skipping .claude junction"
}

Write-Header "[4/5] CLAUDE.md"
$claudeMd = Join-Path $InstallDir "CLAUDE.md"
if (-not (Test-Path $claudeMd)) {
  New-Item -ItemType File -Path $claudeMd | Out-Null
  Write-Info "created empty CLAUDE.md"
} else {
  Write-Info "already exists: CLAUDE.md"
}

Write-Header "[5/5] Task Scheduler"
$pwsh = (Get-Command powershell.exe).Source
$action = New-ScheduledTaskAction -Execute $pwsh -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$targetKeepalive`""
$triggers = @()
$triggers += New-ScheduledTaskTrigger -Daily -At 7:00AM
$triggers += New-ScheduledTaskTrigger -Daily -At 12:00PM
$triggers += New-ScheduledTaskTrigger -Daily -At 5:00PM
$currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$task = New-ScheduledTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
  # Update action and settings only — triggers belong to the user, never touch them
  Set-ScheduledTask -TaskName $TaskName -Action $action -Settings $settings | Out-Null
  Write-Info "updated: $TaskName (action refreshed, existing triggers preserved)"
} else {
  Register-ScheduledTask -TaskName $TaskName -InputObject $task | Out-Null
  Write-Info "installed: $TaskName (07:00 / 12:00 / 17:00, current user)"
}

Write-Header "Done"
Write-Info "Directory: $InstallDir"
Write-Info "Log:       $(Join-Path $InstallDir 'keepalive.log')"
Write-Host ""

$answer = Read-Host "Run a test now? [y/N]"
if ($answer -match "^[yY]") {
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetKeepalive
}
