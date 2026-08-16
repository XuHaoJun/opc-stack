# OPC Stack GitHub 整合 — Design Spec

日期: 2026-08-16
狀態: approved (user)

## 目標

在 OPC stack (buzz + hermes + paperclip) 上, 讓使用者從 buzz 或 hermes 對話要求「開發 xx 軟體」, 端到端自動完成:

1. hermes agent 釐清需求
2. hermes 在 paperclip 建立 ticket
3. paperclip 調用 omp (既有 `claude_local` adapter + `omp acp --yolo` handshake) 開發
4. omp 開發完後 `gh repo create` + push 到 GitHub
5. GitHub project link **自動**送達 buzz 頻道 (v2 全自動, 使用者不需主動詢問)

## 非目標

- 不實作 Nodalis。
- 不改 buzz relay / hermes gateway 的既有身份與頻道機制。
- 不把 buzz credential 放進 paperclip (見不變量: paperclip 零 buzz 接觸)。
- v1 不實作 hermes agent 對 paperclip 的 invite/claim onboarding 流程 (agent 身份); 用 static board API key。若之後要 paperclip 以 `hermes_gateway` adapter 喚醒 hermes agent, 再走 `doc/HERMES_GATEWAY_ONBOARDING.md` 的 join/claim 流程。
- hermes dashboard 開的 ticket 若未在 ticket 內記錄 buzz channel id, 不保證自動送達 buzz (記錄 channel 才有)。

## 不變量 (約束, 來自 AGENTS.md)

1. **容器禁止 host mount / privileged** → credential 不得 bind mount; 用 named volume + 同步腳本 (同 `/nix` pattern)。
2. `upstream/` 是 submodule, 永不直接編輯 → 一切改動放 `patches/`。
3. 工具持久化走 `nix profile add` (named volume, boot seed + self-heal)。
4. **paperclip 不直接使用 buzz** — 所有送往 buzz 的訊息必須以 hermes (frontdoor agent) 身份與容器發出。

## 架構與資料流

```
[host] ~/.ssh + ~/.config/gh + ~/.gitconfig
   │  scripts/sync-gh-creds.sh (throwaway 容器, read-only bind → named volume)
   ▼
opc-gh-creds volume ──mount──▶ paperclip:/creds   (必需: omp 開發+push 所在)
             └───────────────▶ hermes:/creds      (備用: hermes 直接操作 GitHub)
             └───────────────▶ frontdoor:/creds   (備用)

buzz 頻道: "開發 xx"
   ▼
frontdoor agent (hermes acp, buzz-acp 常駐)
   │ ① REST 建立 paperclip ticket (PAPERCLIP_API_KEY; skill `paperclip-api` 教 curl)
   │ ② ticket 內容含 acceptance criteria: gh repo create --private --push + link 回 ticket
   │ ③ ticket 內記錄 buzz channel id (NIP-29 channel UUID)
   │ ④ spawn 背景 `opc-issue-watcher.sh <ticket-id> <channel-uuid>`
   ▼
paperclip: ticket → heartbeat 喚醒 omp (claude_local adapter, 既有 handshake)
   │ omp 在 issue workspace:
   │   git init → 開發 → gh repo create --source . --private --push
   │   → gh repo view --json url → link 貼回 ticket comment → issue completed
   ▼
opc-issue-watcher.sh (frontdoor 容器內, 每 60s poll paperclip REST)
   │ 偵測 status=completed 且含 link comment
   ▼
buzz messages send --channel <uuid> --content "✅ <名稱> 完成: <link>"
   (BUZZ_PRIVATE_KEY = frontdoor agent nsec, frontdoor-entrypoint 已 export)
   ▼
buzz 頻道收到 link   ← paperclip 全程零 buzz 接觸
```

## 組件規格

### 1. `scripts/sync-gh-creds.sh` (新增, host side)

- 冪等; 可任意時機重跑以刷新 credential。
- 實作: 起一個 throwaway 容器, read-only bind host 的 `~/.ssh`, `~/.config/gh`, `~/.gitconfig`, 寫入 named volume `opc-gh-creds`, 目錄結構:
  - `opc-gh-creds/ssh/` — `~/.ssh` 全部內容 (config, keys, known_hosts)
  - `opc-gh-creds/gh/` — `~/.config/gh` 全部內容 (hosts.yml 含 token)
  - `opc-gh-creds/git/config` — 從 host `~/.gitconfig` 抽取 `user.name` + `user.email` (最小化; 不搬 include/signing 等複雜設定)
- 若 `ssh/known_hosts` 缺 `github.com`, 自動補 (`ssh-keyscan github.com`)。
- 錯誤處理: host 缺任一來源 (如無 `~/.config/gh/hosts.yml`) → 明確警告但繼續同步其餘; exit code 非零以利 CI/手動察覺。
- 不寫入 `.env` 任何 secret; credential 只存在 volume。

### 2. Compose 變更 (`docker-compose.yml`)

- 新增 top-level volume `opc-gh-creds`。
- `paperclip`: `volumes` 加 `opc-gh-creds:/creds` (rw, 供 chmod)。
- `hermes`: 加 `opc-gh-creds:/creds`。
- `frontdoor`: 加 `opc-gh-creds:/creds`。
- `.env.example` 新增 `PAPERCLIP_API_KEY` (hermes→paperclip REST bearer; 由 user 從 paperclip board 建立後填入)。

### 3. `opc-gh-seed.sh` (新增, 3 個 image 共用; 放 `patches/<proj>/` 各一份)

- 由各 entrypoint source 執行 (同 `opc-nix-seed.sh` 模式), 自癒、冪等:
  ```sh
  chmod 600 /creds/ssh/* 2>/dev/null || true   # ssh 拒收 group/world-readable key
  export GIT_SSH_COMMAND="ssh -F /creds/ssh/config"
  export GH_CONFIG_DIR=/creds/gh
  export GIT_CONFIG_GLOBAL=/creds/git/config
  ```
- env 導向而非寫入 HOME: paperclip 跑 `node` user (uid 1000, HOME=/paperclip), hermes 跑 uid 10000 (HOME=/opt/data), frontdoor 跑 root — HOME 各異, env 最穩。
- omp 為 paperclip server 的子 process, 繼承 env → 自動獲得 git/gh credential。
- 注意: hermes/frontdoor 若 seed 到 `GIT_SSH_COMMAND` 但該容器無 GitHub 需求, 無害; 仍全數 seed 保持一致。

### 4. gh CLI

- **paperclip image 已內建** (apt: `gh git ...`), 無需安裝。
- hermes / frontdoor 需要時: `nix profile add nixpkgs#gh` (持久於各自 `/nix` volume; 或日後加入 nix-seed 預設工具 self-heal 清單 — 本次不做, 文件註記)。

### 5. hermes → paperclip 整合 (REST + skill)

- 官方整合面: paperclip `doc/HERMES_GATEWAY_ONBOARDING.md` 確認 `PAPERCLIP_API_URL` + `PAPERCLIP_API_KEY` 是 hermes-originated 呼叫的注入面。
- 決定走 **REST + skill** 而非 MCP sidecar:
  - 需要的 endpoint 只有 3 個 (`createIssue` / `addComment` / `getIssue`); paperclip MCP server 包本身即 REST 薄 wrapper, MCP 無額外能力。
  - frontdoor 容器無 node, `npx` stdio MCP 跑不起來; MCP 需 sidecar + stdio↔HTTP bridge (第三方移動件) — REST 對 gateway/frontdoor 兩側一致 (terminal + curl)。
  - credential 兩路相同。
- 新增 skill `paperclip-api` (SKILL.md), seed 進 hermes 與 frontdoor 的 skills dir (entrypoint 照 `memory_tencentdb` 的 sync pattern): curl 範例 + 工作流 (見 §7)。
- 具體 REST surface (已從 `packages/mcp-server` 與 `packages/shared` 驗證; base = `$PAPERCLIP_API_URL/api`, auth = `Authorization: Bearer $PAPERCLIP_API_KEY`):
  - 找 company: `GET /agents/me`
  - 開 ticket: `POST /companies/{companyId}/issues` body `{ title, description, status?, priority?, assigneeAgentId? }` (status enum: `backlog|todo|in_progress|in_review|done|blocked|cancelled`)
  - 讀 ticket: `GET /issues/{issueId}`
  - 加 comment: `POST /issues/{issueId}/comments` body `{ body }`
  - 更新狀態: `PATCH /issues/{issueId}` body `{ status: "done" }` (omp 完成時)
  - 列 comments: `GET /issues/{issueId}/comments`
- channel 記錄約定: 開票後 frontdoor agent 立刻加一則 comment, 內容含 marker 行 `BUZZ_CHANNEL: <uuid>` — watcher 與 boot sweep 都靠這 marker。
- 所需 env (compose, 兩處 hermes 皆設):
  - `PAPERCLIP_API_URL=http://paperclip:3100`
  - `PAPERCLIP_API_KEY=${PAPERCLIP_API_KEY}`

### 6. `opc-issue-watcher.sh` (新增, frontdoor image)

- 位置: `patches/buzz/opc-issue-watcher.sh`, install 到 `/usr/local/bin/`。
- 用法: `opc-issue-watcher.sh <ticket-id> <channel-uuid>` — 背景 process, 每 60s poll:
  - `GET /api/issues/<ticket-id>` → status:
    - `done` 且 comments (`GET /api/issues/<id>/comments`) 含 `https://github.com/` URL → buzz post:
      `buzz messages send --channel <uuid> --content "✅ <ticket-title> 完成: <link>"`
    - `cancelled` / `blocked` → 通知錯誤/取消摘要。
  - 逾時 (max-age 24h) → 通知「仍在進行」, 停止 poll。
  - 除錯輸出進 stdout (container log 可看)。
- 冪等: watcher 啟動時在 `/opt/data/issue-watchers/<ticket-id>.state` 寫狀態檔 (含 pid); boot sweep 以狀態檔去重/續接。
- **boot sweep (自癒)**: frontdoor-entrypoint 啟動時, 掃 paperclip 所有 open issue (`GET /api/companies/{companyId}/issues`), 找含 `BUZZ_CHANNEL:` marker comment 且無活 watcher 狀態的 ticket, 重新 spawn watcher — 容器重啟後自動續接。

### 7. 工作流 (skill 內容 = hermes 行為契約)

frontdoor agent 收到「開發 xx」:
1. 用 `paperclip-api` skill 建立 ticket: 標題 = 專案名, 描述 = 需求 + acceptance criteria 明確寫:
   - 「完成後: `gh repo create <name> --private --source . --remote origin --push`, 把 repo URL 貼回本 ticket comment, 然後 `PATCH /api/issues/<id>` 將 status 改為 `done`」
2. 立刻加一則 comment, 內含 `BUZZ_CHANNEL: <uuid>` marker (buzz 頻道 UUID) 供 watcher/boot sweep 使用。
3. spawn `/usr/local/bin/opc-issue-watcher.sh <ticket-id> <channel-uuid>` (background)。
4. 回覆使用者: 「已建立 ticket #<id>, 開發中, 完成後我會在這裡貼 link」。

omp 側行為由 ticket acceptance criteria 驅動 (omp 無需新 skill; 必要時可在 repo 加 AGENTS.md 由 omp 自行閱讀)。

## 錯誤處理

| 情境 | 行為 |
|---|---|
| `gh` push 失敗 (auth/網路) | omp 把錯誤寫進 ticket comment + 標記 `blocked`; watcher 照樣通知 (內容 = 錯誤摘要) |
| watcher 隨容器重啟而亡 | boot sweep 掃描重新 attach (冪等) |
| ticket 永不完成 | max-age (24h) 後 watcher 通知目前狀態並停止 |
| host credential 更新 | 重跑 `sync-gh-creds.sh`; 容器內 env 指向 volume, 下次呼叫即生效 (不需 rebuild; 建議 `docker compose restart` 讓 seed 重新 chmod) |
| `~/.config/gh` 不存在 | sync script 警告; 容器內 `gh auth status` 會失敗 — 文件載明前置條件 |

## 驗證計畫

1. `scripts/sync-gh-creds.sh` → `docker compose exec paperclip sh -c 'gh auth status && ssh -T git@github.com'` (或 `ssh -F /creds/ssh/config -T git@github.com`)。
2. `docker compose exec frontdoor bash -c 'ls /creds && echo $GIT_SSH_COMMAND $GH_CONFIG_DIR'`。
3. 端到端: buzz 頻道下「開發一個 hello-world 專案」→ 等待 → 確認 buzz 收到 GitHub link; 手動檢查 paperclip ticket 有 link comment。
4. 既有 `acp-smoke-test.mjs` 保持通過 (不應受影響)。

## 已驗證事實 (grounding)

- paperclip image apt 已含 `gh` + `git` (`upstream/paperclip/opc/Dockerfile` base stage)。
- paperclip `packages/mcp-server` 為 stdio-only REST wrapper (`paperclipCreateIssue` 等)。
- hermes config.yaml 支援 `mcp_servers` (stdio/http/sse), ACP 模式自動加 `mcp-<name>` toolset。
- hermes gateway **無** nostr/buzz 平台 adapter → buzz 送達必須走 frontdoor (buzz CLI + nsec)。
- buzz CLI `messages send --channel <UUID> --content "..."` 存在, 讀 `BUZZ_PRIVATE_KEY` env; frontdoor-entrypoint 已 export。
- paperclip onboarding 文件: `PAPERCLIP_API_URL`/`PAPERCLIP_API_KEY` 為 hermes-originated 呼叫注入面。
- paperclip REST surface 驗證: issue CRUD/comments 路徑與 status enum (`backlog|todo|in_progress|in_review|done|blocked|cancelled`) 取自 `packages/mcp-server/src/tools.ts` + `packages/shared/src/constants.ts` + `server/src/routes/issues.ts`; auth 為 bearer `PAPERCLIP_API_KEY`, base `$PAPERCLIP_API_URL/api`。
- paperclip webhook route 為 plugin 入站型, 無 outbound issue-event webhook → 完成偵測採 watcher poll, 不採 webhook。

## 決策紀錄

| 決策 | 選擇 | 理由 |
|---|---|---|
| credential 機制 | named volume + sync script | 不變量 5 禁 host mount; 同 `/nix` pattern |
| credential 內容 | 個人 SSH key + gh token | user 決定 (blast radius 取捨已知) |
| hermes→paperclip | REST + skill | 3 endpoint、frontdoor 無 node、無第三方 bridge |
| 完成偵測 | watcher poll (frontdoor 內) | paperclip 無 outbound webhook; buzz CLI + nsec 已在 frontdoor |
| buzz 送達 | frontdoor agent 身份 (buzz CLI) | hermes 無 nostr adapter; 符合「全走 hermes」 |
| gh CLI 安裝 | 僅 paperclip 內建; hermes/frontdoor nix 按需 | 執行者只有 paperclip 需要 |
