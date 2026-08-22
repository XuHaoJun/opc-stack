# OPC Stack

Buzz(對話)+ Hermes(agent runtime)+ Paperclip(work 控制面)+ TencentDB-Agent-Memory(Knowledge Plane)的 docker compose 部署。Nodalis 為 evidence-gated governance,本 repo 不實作(架構決策見 `docs/nodalis-prd-v10.1.md`)。

## 服務

| 服務 | 說明 | port |
|---|---|---|
| `buzz` | Nostr relay(+ pg/redis/minio) | 3000 |
| `frontdoor` | buzz-acp → `hermes acp`(與 buzz 共用 netns) | — |
| `hermes` | gateway API server (dashboard 關閉) | 8642 |
| `hermes-dashboard` | web dashboard over the buzz front door's hermes home (sessions + live logs/thinking) | 9119 |
| `paperclip` | canonical work control plane | 3100 |
| `devenv-pg` / `devenv-valkey` / `devenv-s3` | agent 共用、租戶隔離的 PostgreSQL/pgvector、Valkey 與 S3 | 5433 / 6380 / 9002（僅 localhost） |
| `podenv` | rootless Podman daemon，提供巢狀容器租約 | 23000–23015（僅 localhost） |
| `tencentdb-core` / `-hub` / `-proxy` | memory gateway / panel+knowledge / LLM proxy | 8420 / 8125+8424 / 8096 |

LLM 全棧預設使用 OpenCode Go(`https://opencode.ai/zen/go/v1`),`.env` 填 `OPENAI_API_KEY` 一個 key 即可。`OPENAI_BASE_URL` 控制 OpenAI-compatible endpoint;shared gateway/dashboard/Paperclip/TencentDB 的模型用 `OPENAI_MODEL`（預設 `deepseek-v4-flash`）,frontdoor relay 則用 `BUZZ_AGENT_MODEL`（預設 `deepseek-v4-pro`）。Hermes custom provider runtime 讀 key/base URL,模型以 `config.yaml` 為 source of truth。Hermes 的記憶走官方 `memory_tencentdb` provider,直連 `tencentdb-core`。

## 開發資源租約

### devenv

`devenv` 提供 agent 可直接使用、但彼此隔離的開發資源。預設租約會建立獨立的 PostgreSQL/pgvector database 與 Valkey ACL user；也可用 `--with` 選擇 `postgres`、`valkey`、`http`、`s3`，並將對應的連線變數寫入 workspace 的 `.env`。適合一般應用程式開發；agent 不需要也拿不到 host Docker。

```bash
docker compose exec -u node paperclip devenv provision demo --env-file /tmp/demo.env
docker compose exec paperclip devenv list          # 查看租約與用量
docker compose exec paperclip devenv release demo  # 手動刪除租約及資料
```

PostgreSQL 與 Valkey 也分別發佈在 host 的 `127.0.0.1:5433`、`127.0.0.1:6380`，可用租約輸出的憑證從 SQL/Valkey client 直接連線。租約不會自動回收。

### podenv

`podenv` 用 rootless Podman 在隔離的 service container 內提供 daemon 租約，適用於無法共享多租戶的服務，或只能以 image 取得的指定舊版本，例如 MySQL 5.7。PostgreSQL、pgvector、Valkey、Redis 家族預設會被導向 `devenv`；確實需要獨立或舊版 instance 時，必須用 `--dedicated` 記錄原因。

```bash
docker compose exec paperclip podenv provision legacy-erp --image mysql:5.7 --port 3306 \
  --as MYSQL_URL --env-file /tmp/legacy-erp.env
docker compose exec paperclip podenv list
docker compose exec paperclip podenv release legacy-erp  # 唯一回收路徑，連資料一起刪除
```

每個租約會取得 host port 與連線變數；資料會跨 stack restart 保留，但沒有自動 GC 或個別磁碟配額。完整選型、參數與限制見 `SETUP.md`，隔離與操作不變量見 `AGENTS.md`。

## 快速開始

```bash
scripts/setup.sh              # 新機器一鍵: .env → submodule init → prepare → build → up
scripts/prepare.sh            # patches/ → upstream/ 同步(改 patch 後、build 前必跑)
docker compose up -d --build  # 啟動/重建
tests/connectivity.sh          # 連通性測試(不碰 LLM)
docker compose logs -f <svc>  # 看日誌
```

改動一律改 `patches/<proj>/`,不直接改 `upstream/`(git submodule,乾淨 checkout)。

## 文件

- `AGENTS.md` — 架構、不變量、已知坑(改動前必讀)
- `SETUP.md` — 安裝、設定頁、agent wiring
- `docs/nodalis-prd-v10.1.md` — 架構決策(PRD v10 / v10.1)
- `docs/superpowers/` — 設計與實作計畫
