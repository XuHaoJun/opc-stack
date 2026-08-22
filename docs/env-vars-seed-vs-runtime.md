# .env 變數分類:Seed vs Runtime

- **撰寫日期**: 2026-08-17 (UTC)
- **基準 commit**: `496d9c4e5e1e90939a6017fcd2e32e1fc2552e9c`(撰寫時 HEAD;本文件為新檔,尚未 commit)
- **來源**: 追蹤 `docker-compose.yml` + `patches/` 各 entrypoint / one-shot bootstrap 的實際讀取點,非 .env.example 註解

## 結論速覽

- 大部分 LLM / port / 認證類 env 是 **runtime**:`docker compose up -d` 即可生效,不需 rebuild。
- executor 的名稱、top-level role/title/capabilities 與 managed prompt 是 **bootstrap reconcile**；`adapterConfig` 保留：重跑 one-shot 即收斂，不必清 volume。
- 真正 **seed**(第一次 boot 燒進 volume/DB)的是 DB / minio / keys 與 create-only bootstrap 資料。
- 兩個**死變數**:寫在 .env.example,但 compose 沒接線,改了沒有效果。

---

## 重建 container 即生效 (Runtime)

| Env | 生效方式 |
|---|---|
| `OPENAI_API_KEY` | runtime。frontdoor/hermes/dashboard/Paperclip 每次 boot/runtime 讀取；TencentDB 由下方的 adapter mapping 接收。Buzz relay 本身不消費 LLM key；需要模型的是獨立的 frontdoor ACP。 |
| `ANTHROPIC/GOOGLE/OPENROUTER/GROQ/DEEPSEEK/XAI_API_KEY` | runtime,compose 每次傳給 frontdoor/hermes/dashboard/paperclip |
| `OPENAI_BASE_URL` | runtime。Hermes custom provider runtime 讀取；第一次 boot 也用來 seed gateway/frontdoor 的 `config.yaml`，既有 editable config 改 env 後可能仍需手動調整 |
| `OPENAI_MODEL` | runtime。shared gateway/dashboard/Paperclip/TencentDB defaults 讀取；Hermes gateway 第一次 boot 用來 seed `config.yaml`，既有 editable config 的模型以該檔為 source of truth |
| `BUZZ_AGENT_MODEL` | runtime。frontdoor relay 專用模型（預設 `deepseek-v4-pro`）；frontdoor 第一次 boot 用來 seed `config.yaml`，既有 editable config 改 env 後可能仍需手動調整 |
| `BUZZ_REDIS_PASSWORD` | runtime — `--requirepass` 是啟動參數,每次重啟重套,buzz 的 `REDIS_URL` 同步更新 |
| `BUZZ_PORT` / `HERMES_DASHBOARD_PORT` / `HERMES_API_PORT` / `PAPERCLIP_PORT` / `TENCENTDB_*_PORT` | host port 綁定,runtime |
| `BUZZ_RELAY_URL` | runtime,但**語意上改 host = 新 community**(AGENTS.md 不變量 1);`buzz-bootstrap` one-shot 每次 `up` 重跑、冪等補 add-member。流程:改 .env → `docker compose up -d buzz frontdoor` |
| `HERMES_DASHBOARD_USERNAME/PASSWORD`、`HERMES_API_SERVER_KEY` | runtime(gateway/dashboard 啟動時讀 env) |
| `PAPERCLIP_PUBLIC_URL` / `PAPERCLIP_ALLOWED_HOSTNAMES` | runtime(paperclip server 讀 env) |
| `BETTER_AUTH_SECRET` | runtime,但改了會使所有人現有 session 失效、需重新登入(未燒進 DB) |
| `TENCENTDB_GATEWAY_API_KEY` | runtime(core Bearer、hub `REMOTE_INSTANCE_KEY`、hermes/frontdoor memory plugin 每次 boot 讀 env);對 proxy 的影響除外,見 seed 表 |
| `TENCENTDB_KNOWLEDGE_PUBLIC_URL`、`TENCENTDB_LLM_API_KEY/BASE_URL/MODEL` | runtime(core/hub 每次啟動讀 env) |
| `IMAGE_PREFIX` | build-time:改 image tag,需 `up -d --build` 重建 image,非單純 recreate |
### TencentDB Compose adapter mapping / precedence

Compose maps the canonical `OPENAI_*` values into each TencentDB adapter; the
fallback order is not identical across services. The `:-` nesting below is
the actual precedence (left-hand value is selected when non-empty):

| Service | Adapter variables | Compose precedence |
|---|---|---|
| `tencentdb-core` | `TDAI_LLM_API_KEY`, `TDAI_LLM_BASE_URL`, `TDAI_LLM_MODEL` | API key: `OPENAI_API_KEY` first, then `TENCENTDB_LLM_API_KEY`; base URL/model: `TENCENTDB_LLM_BASE_URL`/`TENCENTDB_LLM_MODEL` first, then `OPENAI_BASE_URL`/`OPENAI_MODEL`, then defaults |
| `tencentdb-hub` | `LLM_API_KEY`, `LLM_BASE_URL`, `LLM_MODEL` | API key: `OPENAI_API_KEY` first, then `TENCENTDB_LLM_API_KEY`; base URL/model: `TENCENTDB_LLM_BASE_URL`/`TENCENTDB_LLM_MODEL` first, then `OPENAI_BASE_URL`/`OPENAI_MODEL`, then defaults |
| `tencentdb-proxy` | `PROXY_UPSTREAM_URL`, `PROXY_UPSTREAM_API_KEY` | service-specific `PROXY_UPSTREAM_URL`/`PROXY_UPSTREAM_API_KEY` first, then `OPENAI_BASE_URL`/`OPENAI_API_KEY`, then the endpoint default for URL |

Therefore `TENCENTDB_LLM_*` is a service-specific override for base/model, but
for the core/hub API key Compose intentionally checks `OPENAI_API_KEY` first
and uses `TENCENTDB_LLM_API_KEY` only as fallback. The Buzz relay itself does
not consume the LLM key; its separate frontdoor ACP uses the canonical
provider settings.

## Bootstrap reconcile — 重跑 one-shot 即收斂

| Env | 生效方式 |
|---|---|
| `PAPERCLIP_EXECUTOR_AGENT_NAME` | executor 由 `paperclip-bootstrap` 每次執行時 reconcile：名稱、top-level `role`/`title`/`capabilities` 與 bootstrap-owned managed prompt 會收斂，既有 `adapterConfig` 保留。既有名稱若**精確等於** legacy `OMP Engineer`，會依原 agent ID 就地改名為 `Fullstack Engineer`，不建立重複 agent；真正自訂過的名稱保持自訂，不會被覆蓋。變更後重跑 `paperclip-bootstrap` one-shot 即可，不需清 volume |

## Seed — 第一次 boot 燒進 volume/DB,事後改要清 volume 或手動修

| Env | 為什麼是 seed |
|---|---|
| `COMPOSE_PROJECT_NAME` | volume 名稱前綴,compose 文件註明「Change BEFORE first up」 |
| `BUZZ_DB_PASSWORD` | postgres `POSTGRES_PASSWORD` 只在 volume 首次初始化時寫入。事後改會讓 buzz 的 `DATABASE_URL` 對不上 DB 實際密碼(要 `ALTER USER` 或砍 `buzz-pgdata`) |
| `BUZZ_S3_ACCESS_KEY` / `BUZZ_S3_SECRET_KEY` | minio root creds 燒在 minio data volume 首次 init;事後改會弄掛 `buzz-minio-init` 的 `mc alias set` 與 buzz 的 S3 存取 |
| `BUZZ_S3_BUCKET` | `mc mb --ignore-existing` 冪等;改名字只是新增空 bucket,舊媒體留在舊 bucket(要手動搬) |
| `PAPERCLIP_ADMIN_EMAIL/PASSWORD/NAME`、`PAPERCLIP_COMPANY_NAME` | admin/company 由 `paperclip-bootstrap` one-shot 建立；已存在即保留。事後改 admin 密碼要在 Paperclip UI 改 |
| `PAPERCLIP_API_KEY`(無 .env 變數;entrypoint 從 `/keys/paperclip-api.key` 注入) | bootstrap 寫 key 檔(只回傳一次)。換 key 要清 opc-keys volume 內該檔或重跑 bootstrap |
| `TENCENTDB_ADMIN_USERNAME/USER_KEY` | `init-admin` idempotent(已存在回 409);事後改沒效果,且 USER_KEY 改了會使 provision 的 `/v3/meta/auth/verify` 失敗 |
| `TENCENTDB_TEAM_ID/NAME`、`TENCENTDB_AGENT_ID/NAME` | 只進 `tencentdb-bootstrap` 的 get-before-create;hermes/frontdoor 的 memory 寫入在 compose 硬編碼 `team=opc` / `agt-hermes-front-door`(未接 .env)。事後改只生空 team/agent,資料仍寫在原 id 下 |
| `PROXY_UPSTREAM_URL` / `PROXY_UPSTREAM_API_KEY` | **大坑**:`proxy-entrypoint.sh` 只在 `if [ ! -f /data/config.yaml ]` 時從 env 生成設定,該檔在 `tencentdb-proxy-data` volume 內 → 第一次 boot 後 env 失效。改法:刪/改該 config 再 recreate proxy。`TENCENTDB_GATEWAY_API_KEY` 對 proxy 的影響同理(PROXY_TDAI_API_KEY 也燒進去) |

另外(無對應 env):relay/agent Nostr 公私鑰由 `buzz-keys` one-shot 生成一次,存 `opc-keys` volume,idempotent;無 env 可換。

## 死變數 — 寫在 .env.example 但 compose 未接線

- **`BUZZ_REQUIRE_RELAY_MEMBERSHIP`** — compose 的 buzz service 未傳此 env(只傳 `BUZZ_AUTO_MIGRATE`、`RELAY_URL` 等)。relay 實際以預設 `false`(開放)跑。SETUP.md「set false before first up」與 .env.example 註解都不實;要關閉 relay 需自行 patch compose 加入 buzz environment。
- **`PAPERCLIP_BRIDGE_API_KEY`** — 只有 upstream `paperclip-task-bridge` skill(hermes agent 內)會讀,compose 未傳給任何 service。要用需自行加進 hermes/frontdoor 的 environment。

## config.yaml 陷阱 (`OPENAI_MODEL` / `BUZZ_AGENT_MODEL` / `OPENAI_BASE_URL`)

Hermes gateway 的 `$HERMES_HOME/config.yaml` 第一次 boot 以
`OPENAI_BASE_URL` / `OPENAI_MODEL` seed；frontdoor relay 的 config 以
`OPENAI_BASE_URL` / `BUZZ_AGENT_MODEL` seed。之後各自的 editable
`config.yaml` 是模型選擇的 source of truth。entrypoint 只重寫精確 legacy
defaults，不覆蓋使用者編輯；既有 config 改 env 後可能仍需手動調整：

- `OPENAI_BASE_URL`: fresh config 會取得 env 值；既有 config 只有在仍是
  `https://opencode.ai/zen/go/v1` 這個預設值時才會被 entrypoint refresh，自訂過的
  endpoint 要手動改。
- `OPENAI_MODEL`: fresh gateway config 會取得 env 值；既有 gateway config 只有仍是
  `deepseek-v4-pro` 這個 legacy model 時才會被 entrypoint refresh。shared
  gateway/dashboard/Paperclip/TencentDB 的其他使用者設定，env 不會覆蓋，必須手動調整。
- `BUZZ_AGENT_MODEL`: fresh frontdoor config 會取得 env 值（預設
  `deepseek-v4-pro`）；既有 frontdoor config 只有仍是該 legacy model 時才會被
  entrypoint refresh。其他使用者設定必須手動調整。

換 model 正確做法: shared gateway/dashboard/Paperclip/TencentDB 用
`OPENAI_MODEL`，frontdoor relay 用 `BUZZ_AGENT_MODEL`；既有 editable config
直接在 Hermes dashboard(Chat 設定)改、或 `docker compose exec frontdoor` 改
`/opt/data/config.yaml` 後重啟；要以 env 重新 seed 則刪掉該檔讓 entrypoint
重新建立。

## 操作結論

改 runtime env:`docker compose up -d` 就夠(compose 偵測 env 變動會 recreate),不需 `--build`,除非改 `patches/` 或 `IMAGE_PREFIX`。改 seed 類:清 volume(`docker compose down -v` 全清,AGENTS.md 不變量 4)或手動修 DB/config。
