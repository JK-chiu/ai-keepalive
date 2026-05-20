# ai-keepalive

Claude Code 與 Codex CLI 的 5 小時速率限制視窗管理腳本（Linux / Windows）。

## 原理

Claude Code（Max/Pro）和 Codex CLI（ChatGPT Plus/Pro）使用 **5 小時滾動速率限制視窗**：從第一次請求開始計時，5 小時後重置。

若你在 09:00 開始工作、10:00 達到上限，需等到 14:00 才能繼續。

此腳本在你開始工作前，發送極少 token 的 keepalive ping，提前觸發視窗計時，讓視窗在你需要時已重置。

---

## Linux 前提條件

### 1. NVM + Node.js

> Codex CLI 是 npm 套件，仍需要 Node.js 才能執行。

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 20
```

### 2. jq

```bash
sudo apt install jq   # Debian / Ubuntu
```

### 3. Claude Code CLI（訂閱登入）

```bash
# 安裝
npm install -g @anthropic-ai/claude-code
# 或下載二進位：https://claude.ai/code

# 登入（開啟瀏覽器，用 Claude 訂閱帳戶登入）
claude
```

### 4. Codex CLI（ChatGPT 訂閱登入）

```bash
# 安裝
npm install -g @openai/codex

# 登入（開啟瀏覽器，用 ChatGPT Plus/Pro 帳戶登入）
codex login
```

> **注意**：兩者皆使用 **瀏覽器 OAuth 登入**，不需要 API key。

---

## Linux 安裝

前提條件都滿足後，執行：

```bash
bash install.sh
```

`install.sh` 會先執行 **pre-flight 檢查**，確認以下項目全部通過才繼續安裝：

| 檢查項目 | 說明 |
|----------|------|
| NVM | `~/.nvm/nvm.sh` 存在 |
| Node.js | `nvm which default` 可解析 |
| jq | `jq` 可執行 |
| Claude Code 安裝 | `claude` 可執行 |
| Claude Code 登入 | `~/.claude/.credentials.json` 含有效 OAuth token |
| Codex CLI 安裝 | `codex` 可執行 |
| Codex CLI 登入 | `codex login status` 回傳 "Logged in" |

若任一項失敗，安裝中止並顯示修正指令。

---

## 轉移到新機器

### 步驟一：在新機器安裝前提條件

```bash
# 1. NVM
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc

# 2. Node.js
nvm install 20

# 3. jq
sudo apt install jq

# 4. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 5. Codex CLI
npm install -g @openai/codex
```

### 步驟二：登入兩個 CLI（需要瀏覽器）

```bash
# Claude Code：用 Claude.ai 訂閱帳戶登入
claude

# Codex CLI：用 ChatGPT Plus/Pro 帳戶登入
codex login

# 確認登入狀態
codex login status
```

### 步驟三：複製腳本

```bash
git clone git@github.com:JK-chiu/ai-keepalive.git ~/.ai-keepalive
```

> HTTPS 替代（若未設定 SSH key）：
> ```bash
> git clone https://github.com/JK-chiu/ai-keepalive.git ~/.ai-keepalive
> ```

### 步驟四：執行安裝腳本

```bash
cd ~/.ai-keepalive
bash install.sh
```

### 步驟五：驗證

```bash
# 手動執行測試
~/.ai-keepalive/keepalive.sh

# 確認 crontab 已安裝
crontab -l

# 查看記錄
tail -f ~/.ai-keepalive/keepalive.log
```

正常輸出範例：
```
────────────────────────────────────────────────────────────
2026-xx-xxTxx:xx:xx+08:00  keepalive  start      pid=...
2026-xx-xxTxx:xx:xx+08:00  claude     ok         視窗到期 HH:MM:SS  (還剩 Xh Ym)
2026-xx-xxTxx:xx:xx+08:00  codex      ok         視窗到期 HH:MM:SS  (還剩 Xh Ym)
2026-xx-xxTxx:xx:xx+08:00  keepalive  done       Xs
```

---

## 目錄結構

```
~/.ai-keepalive/
├── keepalive.sh       # 核心腳本（純 bash + jq，含 NVM 初始化）
├── install.sh         # 安裝腳本（含 pre-flight 檢查）
├── README.md          # 此文件
├── CLAUDE.md          # 空白覆蓋（防止載入個人 CLAUDE.md）
├── .gitignore         # 排除 log 與認證快取
├── keepalive.log      # 執行記錄（Asia/Taipei 時區）
└── .claude → ~/.claude  # symlink（共用 OAuth 認證）
```

---

## Cron 排程

```
CRON_TZ=Asia/Taipei
0 7,12,17 * * 1-7   每天 07:00、12:00、17:00（台灣時間）
```

透過 `CRON_TZ` 指定時區，系統時區為 UTC 也能正確以台灣時間觸發。

---

## 重試邏輯

| 狀況 | 行為 |
|------|------|
| 視窗已過期 | 立即重試 |
| 到期在 45 分鐘內 | 等待後重試一次 |
| 到期超過 45 分鐘 | 跳過，等下次 cron |
| 無法取得到期時間 | 30 秒後重試一次 |
| CLI 未安裝 | 跳過（`skip` 記錄）|

---

## 支援的代理

### Claude Code
- **模型**：`haiku`（最便宜）
- **輸出格式**：`stream-json --verbose`（需此格式才有 `rate_limit_event`）
- **認證**：`HOME=~/.ai-keepalive` + `.claude` symlink 共用 OAuth token

### Codex CLI
- **模型**：`gpt-5.4-mini`（最便宜，支援 `low` effort）
- **Reasoning effort**：`low`
- **認證**：`codex login`（ChatGPT Plus/Pro 訂閱）
- **已知限制**：若 Codex CLI session JSON 回傳 `rate_limits:null`，腳本只能確認 keepalive 已觸發，無法顯示 Codex 視窗到期時間。

---

## 設定參數

`keepalive.sh` 頂部常數：

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `TOLERANCE_SECS` | 45 分鐘 | 視窗到期容忍值 |
| `RETRY_DELAY_SECS` | 30 秒 | 無法取得 `resets_at` 時的重試等待 |
| `EXEC_TIMEOUT_SECS` | 60 秒 | CLI 執行逾時 |
| `TZ_VAL` | `Asia/Taipei` | 記錄時區 |

---

## 故障排除

**pre-flight 失敗：Claude Code not logged in**
```bash
claude   # 會開啟瀏覽器，用 claude.ai 訂閱帳戶登入
```

**pre-flight 失敗：Codex CLI not logged in**
```bash
codex login          # 開啟瀏覽器，用 ChatGPT 帳戶登入
codex login status   # 確認狀態
```

**cron 模擬環境測試**
```bash
env -i HOME=$HOME PATH=/usr/bin:/bin ~/.ai-keepalive/keepalive.sh
```

**查看記錄**
```bash
tail -f ~/.ai-keepalive/keepalive.log
```

---

## Windows 前提條件

Windows 版使用原生 PowerShell + Task Scheduler，不需要 WSL、Git Bash、NVM 或 jq。

> **重要**：只安裝 Claude Desktop / Codex App 不夠。Windows 版至少需要一個可在命令列執行且已登入的 CLI：`claude` 或 `codex`。缺少另一個 CLI 時，執行時會記錄 `skip`，不會讓整體失敗。

### 1. PowerShell

Windows PowerShell 5.1 以上即可：

```powershell
$PSVersionTable.PSVersion
```

### 2. Claude Code CLI（訂閱登入）

```powershell
claude --version
claude
```

登入後應有：

```powershell
Test-Path "$env:USERPROFILE\.claude\.credentials.json"
```

### 3. Codex CLI（ChatGPT 訂閱登入）

```powershell
codex --version
codex login
codex login status
```

若 `codex` 來自 npm shim（例如 `%APPDATA%\npm\codex.ps1`），則 Node.js / npm 也是必要依賴：

```powershell
node --version
npm --version
```

## Windows 安裝

```powershell
git clone git@github.com:JK-chiu/ai-keepalive.git "$env:USERPROFILE\.ai-keepalive-src"
cd "$env:USERPROFILE\.ai-keepalive-src"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install-windows.ps1
```

`install-windows.ps1` 會先執行 pre-flight 檢查。Claude / Codex 任一可用即可安裝；若兩者都不可用才會中止。

| 檢查項目 | 說明 |
|----------|------|
| PowerShell | 版本 5+ |
| Claude Code 安裝 | 若要啟用 Claude keepalive，需 `claude` 可執行 |
| Claude Code 登入 | 若要啟用 Claude keepalive，需 `%USERPROFILE%\.claude\.credentials.json` 含 OAuth token |
| Codex CLI 安裝 | 若要啟用 Codex keepalive，需 `codex` 可執行 |
| Codex CLI 登入 | 若要啟用 Codex keepalive，需 `codex login status` 回傳 "Logged in" |
| Node.js / npm | 只在 Codex CLI 是 npm shim 且要啟用 Codex 時要求 |

安裝內容：

```
%USERPROFILE%\.ai-keepalive\
├── keepalive.ps1       # Windows 核心腳本
├── CLAUDE.md           # 空白覆蓋，避免載入個人 CLAUDE.md
├── keepalive.log       # 執行記錄
└── .claude -> %USERPROFILE%\.claude  # junction，共用 Claude OAuth
```

## Windows Task Scheduler

安裝器會建立 task：

```powershell
Get-ScheduledTask -TaskName ai-keepalive
```

排程：

```
每天 07:00、12:00、17:00
僅目前使用者登入時執行
```

若已存在同名 task `ai-keepalive`，安裝器只提醒並保留既有 task，不覆蓋觸發時間。

手動觸發：

```powershell
Start-ScheduledTask -TaskName ai-keepalive
```

手動測試：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.ai-keepalive\keepalive.ps1"
```

查看記錄：

```powershell
Get-Content "$env:USERPROFILE\.ai-keepalive\keepalive.log" -Tail 50
```

## Windows 故障排除

**Claude Code CLI not found**

```powershell
claude --version
```

Desktop App 不能取代 CLI；必須有 `claude` 指令。

若只使用 Codex，缺 Claude 會被記錄為 warning，不會中止安裝。

**Codex CLI not found**

```powershell
codex --version
```

Codex App 不能取代 CLI；必須有 `codex exec`。

若只使用 Claude，缺 Codex 會被記錄為 warning，不會中止安裝。

**pre-flight 失敗：Node.js required for npm-based Codex CLI**

```powershell
node --version
npm --version
```

若 `codex` 是 `%APPDATA%\npm\codex.ps1`，需要 Node.js / npm。

**Codex 已觸發但未回報視窗到期時間**

```text
codex ok 已觸發，Codex 未回報視窗到期時間
```

代表 `codex exec` 成功，但目前 Codex CLI session JSON 沒有 `rate_limits.primary.resets_at`；此狀況需等 Codex CLI / backend 恢復輸出。
