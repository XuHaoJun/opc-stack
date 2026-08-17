# .env 變數分類:Seed vs Runtime

- **撰寫日期**: 2026-08-17 (UTC)
- **基準 commit**: `496d9c4e5e1e90939a6017fcd2e32e1fc2552e9c`(撰寫時 HEAD;本文件為新檔,尚未 commit)
- **來源**: 追蹤 `docker-compose.yml` + `patches/` 各 entrypoint / one-shot bootstrap 的實際讀取點,非 .env.example 註解

## 結論速覽

- 大部分 LLM / port / 認證類 env 是 **runtime**:`docker compose up -d` 即可生效,不需 rebuild。
- 真正 **seed**(第一次 boot 燒進 volume/DB)的是 DB / minio / keys / bootstrap 相關。
- 兩個**死變數**:寫在 .env.example,但 compose 沒接線,改了沒有效果。

---

## 重建 container 即生效 (Runtime)

| Env | 生效方式 |
|---|---|
| `OPENCODE_API_KEY` | runtime。frontdoor/hermes/dashboard 每次 boot 重新 export 成 `OPENAI_API_KEY` 給 hermes(provider custom 讀 env);buzz/paperclip/tencentdb-core/hub 也直接讀 |
| `ANTHROPIC/OPENAI/GOOGLE/OPENROUTER/GROQ/DEEPSEEK/XAI_API_KEY` | runtime,compose 每次傳給 frontdoor/hermes/dashboard/paperclip |
| `OPENCODE_GO_BASE_URL` | 大多 runtime;例外見「config.yaml 陷阱」 |
| `BUZZ_REDIS_PASSWORD` | runtime — `--requirepass` 是啟動參數,每次重啟重套,buzz 的 `REDIS_URL` 同步更新 |
| `BUZZ_PORT` / `HERMES_DASHBOARD_PORT` / `HERMES_API_PORT` / `PAPERCLIP_PORT` / `TENCENTDB_*_PORT` | host port 綁定,runtime |
| `BUZZ_RELAY_URL` | runtime,但**語意上改 host = 新 community**(AGENTS.md 不變量 1);`buzz-bootstrap` one-shot 每次 `up` 重跑、冪等補 add-member。流程:改 .env → `docker compose up -d buzz frontdoor` |
| `HERMES_DASHBOARD_USERNAME/PASSWORD`、`HERMES_API_SERVER_KEY` | runtime(gateway/dashboard 啟動時讀 env) |
| `PAPERCLIP_PUBLIC_URL` / `PAPERCLIP_ALLOWED_HOSTNAMES` | runtime(paperclip server 讀 env) |
| `BETTER_AUTH_SECRET` | runtime,但改了會使所有人現有 session 失效、需重新登入(未燒進 DB) |
| `TENCENTDB_GATEWAY_API_KEY` | runtime(core Bearer、hub `REMOTE_INSTANCE_KEY`、hermes/frontdoor memory plugin 每次 boot 讀 env);對 proxy 的影響除外,見 seed 表 |
| `TENCENTDB_KNOWLEDGE_PUBLIC_URL`、`TENCENTDB_LLM_API_KEY/BASE_URL/MODEL` | runtime(core/hub 每次啟動讀 env) |
| `IMAGE_PREFIX` | build-time:改 image tag,需 `up -d --build` 重建 image,非單純 recreate |

## Seed — 第一次 boot 燒進 volume/DB,事後改要清 volume 或手動修

| Env | 為什麼是 seed |
|---|---|
| `COMPOSE_PROJECT_NAME` | volume 名稱前綴,compose 文件註明「Change BEFORE first up」 |
| `BUZZ_DB_PASSWORD` | postgres `POSTGRES_PASSWORD` 只在 volume 首次初始化時寫入。事後改會讓 buzz 的 `DATABASE_URL` 對不上 DB 實際密碼(要 `ALTER USER` 或砍 `buzz-pgdata`) |
| `BUZZ_S3_ACCESS_KEY` / `BUZZ_S3_SECRET_KEY` | minio root creds 燒在 minio data volume 首次 init;事後改會弄掛 `buzz-minio-init` 的 `mc alias set` 與 buzz 的 S3 存取 |
| `BUZZ_S3_BUCKET` | `mc mb --ignore-existing` 冪等;改名字只是新增空 bucket,舊媒體留在舊 bucket(要手動搬) |
| `PAPERCLIP_ADMIN_EMAIL/PASSWORD/NAME`、`PAPERCLIP_COMPANY_NAME`、`PAPERCLIP_EXECUTOR_AGENT_NAME` | 只被 `paperclip-bootstrap` one-shot 吃(idempotent:admin/company/agent 已存在即跳過)。事後改 admin 密碼要在 Paperclip UI 改 |
| `PAPERCLIP_API_KEY`(無 .env 變數;entrypoint 從 `/keys/paperclip-api.key` 注入) | bootstrap 寫 key 檔(只回傳一次)。換 key 要清 opc-keys volume 內該檔或重跑 bootstrap |
| `TENCENTDB_ADMIN_USERNAME/USER_KEY` | `init-admin` idempotent(已存在回 409);事後改沒效果,且 USER_KEY 改了會使 provision 的 `/v3/meta/auth/verify` 失敗 |
| `TENCENTDB_TEAM_ID/NAME`、`TENCENTDB_AGENT_ID/NAME` | 只進 `tencentdb-bootstrap` 的 get-before-create;hermes/frontdoor 的 memory 寫入在 compose 硬編碼 `team=opc` / `agt-hermes-front-door`(未接 .env)。事後改只生空 team/agent,資料仍寫在原 id 下 |
| `PROXY_UPSTREAM_URL` / `PROXY_UPSTREAM_API_KEY` | **大坑**:`proxy-entrypoint.sh` 只在 `if [ ! -f /data/config.yaml ]` 時從 env 生成設定,該檔在 `tencentdb-proxy-data` volume 內 → 第一次 boot 後 env 失效。改法:刪/改該 config 再 recreate proxy。`TENCENTDB_GATEWAY_API_KEY` 對 proxy 的影響同理(PROXY_TDAI_API_KEY 也燒進去) |

另外(無對應 env):relay/agent Nostr 公私鑰由 `buzz-keys` one-shot 生成一次,存 `opc-keys` volume,idempotent;無 env 可換。

## 死變數 — 寫在 .env.example 但 compose 未接線

- **`BUZZ_REQUIRE_RELAY_MEMBERSHIP`** — compose 的 buzz service 未傳此 env(只傳 `BUZZ_AUTO_MIGRATE`、`RELAY_URL` 等)。relay 實際以預設 `false`(開放)跑。SETUP.md「set false before first up」與 .env.example 註解都不實;要關閉 relay 需自行 patch compose 加入 buzz environment。
- **`PAPERCLIP_BRIDGE_API_KEY`** — 只有 upstream `paperclip-task-bridge` skill(hermes agent 內)會讀,compose 未傳給任何 service。要用需自行加進 hermes/frontdoor 的 environment。

## config.yaml 陷阱 (OPENCODE_GO_MODEL / BASE_URL)

hermes 與 frontdoor 的 `$HERMES_HOME/config.yaml` 在**第一次 boot** 用 env seed;之後 entrypoint 的 sed 只重寫兩個**舊版 legacy 值**:

- `base_url: https://opencode.ai/zen/go/v1` → 新 base_url(sed 有 match,因為這就是預設值)→ 改 `OPENCODE_GO_BASE_URL` 通常有效
- `default: deepseek-v4-pro` → 新 model(**只 match 舊值**;目前預設已是 `deepseek-v4-flash`,改 model 不會被重寫)→ 改 `OPENCODE_GO_MODEL` 基本無效

換 model 正確做法:hermes-dashboard(Chat 設定)改、或 `docker compose exec frontdoor` 改 `/opt/data/config.yaml` 後重啟、或刪掉該檔讓 entrypoint 重新 seed。

## 操作結論

改 runtime env:`docker compose up -d` 就夠(compose 偵測 env 變動會 recreate),不需 `--build`,除非改 `patches/` 或 `IMAGE_PREFIX`。改 seed 類:清 volume(`docker compose down -v` 全清,AGENTS.md 不變量 4)或手動修 DB/config。
