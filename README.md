# ai-keepalive

Claude Code 與 Codex CLI 的 5 小時速率限制視窗管理腳本（Linux 版）。

## 原理

Claude Code（Max/Pro）和 Codex CLI（ChatGPT Plus/Pro）使用 **5 小時滾動速率限制視窗**：從第一次請求開始計時，5 小時後重置。

若你在 09:00 開始工作、10:00 達到上限，需等到 14:00 才能繼續。

此腳本在你開始工作前，發送極少 token 的 keepalive ping，提前觸發視窗計時，讓視窗在你需要時已重置。

---

## 前提條件

### 1. NVM + Node.js

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
source ~/.bashrc
nvm install 20
```

### 2. Claude Code CLI（訂閱登入）

```bash
# 安裝
npm install -g @anthropic-ai/claude-code
# 或下載二進位：https://claude.ai/code

# 登入（開啟瀏覽器，用 Claude 訂閱帳戶登入）
claude
```

### 3. Codex CLI（ChatGPT 訂閱登入）

```bash
# 安裝
npm install -g @openai/codex

# 登入（開啟瀏覽器，用 ChatGPT Plus/Pro 帳戶登入）
codex login
```

> **注意**：兩者皆使用 **瀏覽器 OAuth 登入**，不需要 API key。

---

## 安裝

前提條件都滿足後，執行：

```bash
bash install.sh
```

`install.sh` 會先執行 **pre-flight 檢查**，確認以下項目全部通過才繼續安裝：

| 檢查項目 | 說明 |
|----------|------|
| NVM | `~/.nvm/nvm.sh` 存在 |
| Node.js | `nvm which default` 可解析 |
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

# 3. Claude Code CLI
npm install -g @anthropic-ai/claude-code

# 4. Codex CLI
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

**方法 A：git clone（推薦，若有 remote）**
```bash
git clone <repo-url> ~/.ai-keepalive
```

**方法 B：從舊機器 scp**
```bash
# 在舊機器上執行
scp ~/.ai-keepalive/{keepalive.mjs,start.sh,install.sh,CLAUDE.md,.gitignore} \
    USER@新機器IP:~/.ai-keepalive/
```

**方法 B 替代：手動建立目錄再 scp**
```bash
# 在新機器上
mkdir -p ~/.ai-keepalive

# 在舊機器上
scp -r ~/.ai-keepalive/{*.mjs,*.sh,*.md,.gitignore} USER@新機器:~/.ai-keepalive/
```

### 步驟四：執行安裝腳本

```bash
cd ~/.ai-keepalive
bash install.sh
```

成功輸出範例：
```
[Pre-flight checks]
  ✔  NVM found at ~/.nvm
  ✔  Node.js v20.20.0 (/home/USER/.nvm/versions/node/v20.20.0/bin)
  ✔  Claude Code installed: 2.x.x (Claude Code)
  ✔  Claude Code: logged in (OAuth credentials found)
  ✔  Codex CLI installed: codex-cli 0.x.x
  ✔  Codex CLI: Logged in using ChatGPT

[Installing]
  ...

[setup] Installation complete!
```

### 步驟五：驗證

```bash
# 手動執行測試
~/.ai-keepalive/start.sh

# 正常輸出
# 2026-xx-xxTxx:xx:xx+08:00 [claude] ok resetsAt=...
# 2026-xx-xxTxx:xx:xx+08:00 [codex]  ok resetsAt=...

# 確認 crontab 已安裝
crontab -l
```

---

## 目錄結構

```
~/.ai-keepalive/
├── keepalive.mjs      # 核心腳本（Node.js）
├── start.sh                   # cron 包裝（動態解析 NVM node 路徑）
├── install.sh                 # 安裝腳本（含 pre-flight 檢查）
├── README.md                # 此文件
├── CLAUDE.md                # 空白覆蓋（防止載入個人 CLAUDE.md）
├── .gitignore               # 排除 log 與認證快取
├── keepalive.log      # 執行記錄（Asia/Taipei 時區）
├── cron.log                 # cron stdout/stderr
└── .claude → ~/.claude      # symlink（共用 OAuth 認證）
```

---

## Cron 排程

```
0 7,12,17 * * 1-7   每天 07:00、12:00、17:00 UTC
```

UTC+8（台北）對應時間：15:00、20:00、01:00（次日）。

> 若要改為台北時間早上執行，可調整為 `0 1,4,9 * * 1-7`（UTC 01:00/04:00/09:00 = 台北 09:00/12:00/17:00）

---

## 重試邏輯

| 狀況 | 行為 |
|------|------|
| 視窗已過期 | 立即重試 |
| 到期在 45 分鐘內 | 等待後重試一次 |
| 到期超過 45 分鐘 | 跳過，等下次 cron |
| 無法取得到期時間 | 30 秒後重試一次 |
| CLI 未安裝 | 跳過（`skip:` 記錄）|

---

## 支援的代理

### Claude Code
- **模型**：`haiku`（最便宜）
- **輸出格式**：`stream-json --verbose`（v2.1.142+ 需此格式才有 `rate_limit_event`）
- **認證**：`HOME=~/.ai-keepalive` + `.claude` symlink 共用 OAuth token

### Codex CLI
- **模型**：`gpt-5.4-mini`（最便宜，支援 `low` effort）
- **Reasoning effort**：`low`
- **認證**：`codex login`（ChatGPT Plus/Pro 訂閱）

---

## 設定參數

`keepalive.mjs` 頂部常數：

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `TOLERANCE_MS` | 45 分鐘 | 視窗到期容忍值 |
| `RETRY_DELAY_MS` | 30 秒 | 無法取得 `resetsAt` 時的重試等待 |
| `EXEC_TIMEOUT_MS` | 60 秒 | CLI 執行逾時 |
| `TZ` | `Asia/Taipei` | 記錄時區 |

---

## 故障排除

**pre-flight 失敗：Claude Code not logged in**
```bash
claude   # 會開啟瀏覽器，用 claude.ai 訂閱帳戶登入
```

**pre-flight 失敗：Codex CLI not logged in**
```bash
codex login   # 開啟瀏覽器，用 ChatGPT 帳戶登入
codex login status   # 確認狀態
```

**cron 模擬環境測試**
```bash
env -i HOME=$HOME PATH=/usr/bin:/bin ~/.ai-keepalive/start.sh
```

**查看記錄**
```bash
tail -f ~/.ai-keepalive/keepalive.log
tail -f ~/.ai-keepalive/cron.log
```
