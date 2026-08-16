# AGENTS.md — OPC Stack

Buzz (對話) + Hermes (agent runtime) + Paperclip (work 控制面) + TencentDB-Agent-Memory (agent memory) 的 docker compose 部署。**本 repo 不實作 Nodalis**(架構決策: `docs/nodalis-prd-v10.1.md`)。

## 架構

- **`upstream/`** = 4 個 git submodule, pin 在 upstream tag commit (乾淨 checkout, 永不直接編輯): buzz `desktop-v0.5.14` / hermes `v2026.8.13` / paperclip `canary/v2026.722.1-canary.0` / tencentdb `v2.0.0`。
- **`patches/`** = 全部本地客製 (opc/Dockerfile、entrypoints、one-shot scripts)。build 前 `scripts/prepare.sh` 把 `patches/<proj>/` rsync 進 `upstream/<proj>/opc/` (冪等)。**改 image 一律改 `patches/`, 不改 upstream 主 Dockerfile。**
- 服務 (port): buzz relay 3000 (+pg/redis/minio) · frontdoor (buzz-acp→`hermes acp`, 與 buzz 共用 netns) · hermes gateway 8642 (API server; dashboard 關閉) · hermes-dashboard 9119 (web UI, 掛 frontdoor 的 hermes home, 看 buzz 對話 session/thinking log) · paperclip 3100 · tencentdb core 8420 / panel 8125 / knowledge 8424 / proxy 8096。
- LLM: OpenCode Go (`https://opencode.ai/zen/go/v1`)。`.env` 填 `OPENCODE_API_KEY` 一個 key 全棧通用; hermes 以 `provider: custom` + `OPENAI_BASE_URL/KEY` 接。

## 常用指令

```bash
scripts/setup.sh              # 新機器一鍵: .env → submodule init → prepare → build → up
scripts/prepare.sh            # patches/ → upstream/ 同步 (改 patch 後、build 前必跑)
scripts/upgrade.sh <proj> <tag>  # 升版: checkout 新 tag → prepare → rebuild → redeploy
scripts/test-connectivity.sh  # 連通性測試 (不碰 LLM)
docker compose up -d --build  # 啟動/重建 (改過 patches/ 後)
docker compose logs -f <svc>
docker compose down           # 停 (volume 保留); down -v 全清
```

- 改 `patches/<proj>/` 後: `scripts/prepare.sh` → `docker compose up -d --build <svc>`。
- 手動 build 單一 image: `docker build --target opc-relay -t ${IMAGE_PREFIX:-opc}/buzz:local -f upstream/buzz/opc/Dockerfile upstream/buzz` (其餘服務同理, 見 compose 的 build 區段)。
- image prefix 由 `.env` `IMAGE_PREFIX` 控制 (預設 `opc`); compose project name 由 `COMPOSE_PROJECT_NAME` 控制 (預設 `opc`)。

## 不變量 (改動前必讀)

1. **Buzz 一個 canonical host = 一個 community** (schema UNIQUE + NIP-42/98 以連線 host 驗簽名)。改 host → 改 `.env` `BUZZ_RELAY_URL` → 重啟 buzz + frontdoor → **重跑 add-member** (community 是新的)。Host 不要用 proxy 改寫 (會弄壞簽名驗證)。
2. **Hermes Kanban 關閉** (Paperclip 是唯一 work plane): hermes/frontdoor 的 config.yaml seed 有 `agent.disabled_toolsets: [kanban]` + dispatcher off。別把它們開回來。
3. **nix tool 持久化**: hermes/buzz/frontdoor/paperclip 的 `/nix` 是 named volume, 開機 seed + 自癒。加 tool 用 `nix profile add` (deprecated `install` 會蓋掉 profile)。
4. `docker compose down -v` 後: relay/agent keys、community、tencentdb admin、paperclip bootstrap 全部重建 (bootstrap 皆 one-shot 自動化, 應一次到位)。
5. 容器內 root 隨便折騰, 但**沒有 host mount / privileged** — 隔離不可破壞。
6. **`upstream/` 是 submodule** — 直接改它 = 改壞版控。改動一律放 `patches/`。升版後 (新 tag checkout) patches 可能不兼容, 升版前 review upstream changelog。

## 已知坑 (踩過)

- `buzz-admin` 讀 `RELAY_URL` env (不是 BUZZ_RELAY_URL); add-member 需 DATABASE_URL/REDIS_URL + relay key + S3 env。
- Paperclip `pi_local` adapter 不兼容 omp v17 (flag 差異); 整合 omp 用 `claude_local` + `engine:"acp"` + `agentCommand:"omp acp --yolo"` (handshake 已驗證, 見 SETUP.md)。
- PyPI 的 hermes-agent 停在 0.19.0 → 0.20.1 用 editable install from git tag (`pip install -e "…[acp]"`)。
- TencentDB `MemoryKnowledge/Dockerfile` upstream 是壞的 → hub 用 `deploy/panel-knowledge-combined`。
- nix static build 不吃 `/nix/etc/nix/nix.conf` 預設路徑 → 靠 `NIX_USER_CONF_FILES` env; build 時需要 nixbld group+user。

## 檔案地圖

- `docker-compose.yml` / `.env.example` / `SETUP.md` — 部署核心
- `patches/<proj>/` — 改寫的 Dockerfiles + entrypoints (唯一客製來源; 內容 = 各 repo 的 opc/ 目錄)
- `scripts/` — setup / prepare / upgrade / test-connectivity
- `upstream/<proj>/opc/` — prepare.sh 產物, 勿手改
- `acp-smoke-test.mjs` — omp ACP handshake 驗證 script (在 paperclip 容器內跑)
