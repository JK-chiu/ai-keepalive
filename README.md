# session-trigger

AI CLI（Claude Code / Codex CLI）速率限制視窗管理腳本，適用於 Linux 環境。

## 原理

Claude Code（Max/Pro）和 Codex CLI（Plus/Pro）使用 **5 小時滾動速率限制視窗**：視窗從第一次請求開始計時，5 小時後重置。

若你在 09:00 開始工作、10:00 達到上限，需等到 14:00（5h 後）才能繼續。

此腳本在你開始工作前，發送極少 token 的 keepalive ping，提前觸發視窗計時，使視窗在你需要時已重置。

---

## 快速安裝

> 前提：已安裝 Node.js（建議透過 NVM）、Claude Code CLI、Codex CLI，且已完成各 CLI 的認證（`claude` 已登入；Codex 已設定 `OPENAI_API_KEY`）。

```bash
# 進入腳本所在目錄後執行
bash setup.sh
```

**setup.sh 執行以下操作（冪等，可重複執行）：**
1. 建立 `~/.session-trigger/` 目錄
2. 建立 `~/.session-trigger/.claude → ~/.claude` symlink（共用 OAuth 認證）
3. 建立空的 `~/.session-trigger/CLAUDE.md`（防止載入個人設定檔）
4. 安裝 crontab 條目（保留現有 crontab，不覆蓋）

---

## 目錄結構

```
~/.session-trigger/
├── session-trigger.mjs      # 核心腳本（Node.js）
├── run.sh                   # cron 包裝腳本（解決 NVM PATH 問題）
├── setup.sh                 # 安裝腳本
├── session-trigger.log      # 執行記錄（Asia/Taipei 時區）
├── cron.log                 # cron 的 stdout/stderr
├── CLAUDE.md                # 空白覆蓋檔
└── .claude → ~/.claude      # symlink（共用認證）
```

---

## Cron 排程

```
0 7,12,17 * * 1-5   平日 07:00、12:00、17:00（台北時間）觸發
```

> 系統時區為 UTC，cron 時間以 UTC 計。若要改為台北時間（UTC+8），請對應扣除 8 小時：
> - 台北 07:00 = UTC 23:00（前一天）→ `0 23 * * 0-4`
> - 台北 12:00 = UTC 04:00 → `0 4 * * 1-5`
> - 台北 17:00 = UTC 09:00 → `0 9 * * 1-5`

---

## 手動執行

```bash
~/.session-trigger/run.sh
```

正常輸出範例：
```
2026-05-16T01:48:02+08:00 [session-trigger] start pid=310695 node=v20.20.0
2026-05-16T01:48:04+08:00 [claude] ok resetsAt=2026-05-16T06:10:00+08:00 reply="ok"
2026-05-16T01:48:07+08:00 [codex] ok resetsAt=2026-05-16T04:14:55+08:00
```

---

## 重試邏輯

腳本根據速率限制視窗到期時間決定處理方式：

| 狀況 | 行為 |
|------|------|
| `resetsAt` 已過期 | 立即重試 |
| `resetsAt` 在 45 分鐘內 | 等待到期後重試一次 |
| `resetsAt` 超過 45 分鐘 | 跳過，等下次 cron |
| 無法取得 `resetsAt` | 等待 30 秒後重試一次 |
| CLI 未安裝 | 跳過（`skip:` 記錄）|

---

## 設定參數

所有參數集中在 `session-trigger.mjs` 頂部的常數區塊：

| 參數 | 預設值 | 說明 |
|------|--------|------|
| `TOLERANCE_MS` | 45 分鐘 | 視窗到期容忍值 |
| `RETRY_DELAY_MS` | 30 秒 | 無法取得 `resetsAt` 時的重試等待 |
| `EXEC_TIMEOUT_MS` | 60 秒 | CLI 執行逾時 |
| `TZ` | `Asia/Taipei` | 記錄時區 |

---

## 支援的代理

### Claude Code

- **模型**：`haiku`（最便宜）
- **輸出格式**：`stream-json --verbose`（v2.1.142 需此格式才能取得 `rate_limit_event`）
- **認證**：透過 `HOME=~/.session-trigger` + `.claude` symlink 共用 OAuth token
- **速率限制解析**：從 JSONL 輸出中找 `rate_limit_event` → `rate_limit_info.resetsAt`

### Codex CLI

- **模型**：`gpt-5.4-mini`（最便宜，支援 `low` effort）
- **Reasoning effort**：`low`
- **認證**：需在環境中設定 `OPENAI_API_KEY`，或透過 `codex login` 登入 ChatGPT 帳戶
- **速率限制解析**：從 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` session 檔案中找 `token_count` → `rate_limits.primary.resets_at`

---

## 記錄範例

```log
[2026-05-15T17:48:02Z] [run.sh] OK: node = /home/aesop/.nvm/versions/node/v20.20.0/bin/node
[2026-05-15T17:48:02Z] [run.sh] OK: claude = /home/aesop/.local/bin/claude
[2026-05-15T17:48:02Z] [run.sh] OK: codex = /home/aesop/.nvm/versions/node/v20.20.0/bin/codex
[2026-05-15T17:48:02Z] [run.sh] launching session-trigger (node=v20.20.0)
2026-05-16T01:48:02+08:00 [session-trigger] start pid=310695 node=v20.20.0
2026-05-16T01:48:04+08:00 [claude] ok resetsAt=2026-05-16T06:10:00+08:00 reply="ok"
2026-05-16T01:48:07+08:00 [codex] ok resetsAt=2026-05-16T04:14:55+08:00
```

**記錄狀態說明：**
- `ok` — 觸發成功，視窗正常
- `fail:` — 觸發失敗，附帶原因
- `retry ok` / `retry fail` — 重試後的結果
- `skip:` — CLI 未安裝，跳過

---

## 環境需求

| 軟體 | 版本 | 路徑（本機） |
|------|------|-------------|
| Node.js | ≥ 18.x（透過 NVM） | `/home/aesop/.nvm/versions/node/v20.20.0/bin/node` |
| Claude Code | ≥ 2.x | `/home/aesop/.local/bin/claude` |
| Codex CLI | ≥ 0.112.0 | `/home/aesop/.nvm/versions/node/v20.20.0/bin/codex` |

---

## 故障排除

**Claude 失敗（`no resetsAt`）**
- 確認 Claude 認證：`claude --version` 及 `ls ~/.session-trigger/.claude/`
- 確認 `~/.session-trigger/.claude` 是指向 `~/.claude` 的 symlink
- 確認 `~/.claude/` 中有有效的認證檔案

**Codex 失敗（`exit code 1`）**
- 確認 API key：`echo $OPENAI_API_KEY` 或確認 codex 已透過 `codex login` 登入
- 確認模型可用：`codex exec hi --json -m gpt-5.4 -C /tmp 2>&1 | head -5`
- 確認 cron 環境能取得 API key（在 `run.sh` 中加入 `export OPENAI_API_KEY=...`）

**cron 找不到指令**
- 確認 `run.sh` 有執行權限：`ls -la ~/.session-trigger/run.sh`
- 模擬 cron 環境測試：`env -i HOME=/home/aesop PATH=/usr/bin:/bin ~/.session-trigger/run.sh`

**查看記錄**
```bash
tail -f ~/.session-trigger/session-trigger.log
tail -f ~/.session-trigger/cron.log
```
