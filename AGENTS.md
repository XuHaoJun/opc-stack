# AGENTS.md — OPC Stack

Buzz (對話) + Hermes (agent runtime) + Paperclip (work 控制面) + TencentDB-Agent-Memory (agent memory) 的 docker compose 部署。**本 repo 不實作 Nodalis**(架構決策: `docs/nodalis-prd-v10.1.md`)。

## 架構

- **`upstream/`** = 4 個 git submodule, pin 在 upstream tag commit (乾淨 checkout, 永不直接編輯): buzz `desktop-v0.5.14` / hermes `v2026.8.16` / paperclip `canary/v2026.722.1-canary.0` / tencentdb `v2.0.0`。
- **`patches/`** = 全部本地客製 (opc/Dockerfile、entrypoints、one-shot scripts)。build 前 `scripts/prepare.sh` 把 `patches/<proj>/` rsync 進 `upstream/<proj>/opc/` (冪等)。**改 image 一律改 `patches/`, 不改 upstream 主 Dockerfile。**
- **`patches/nix-seed/`** = 第一個不屬 submodule 的 build context (compose service `nix-seed`, one-shot)。pin nix 2.35.2 + nixpkgs `8be7bd0c83f1`, 建 `/nix-seed` (cp -al hardlink) 含 8 工具 (ripgrep jq fd htop bat just mise gh)。各 build service `depends_on nix-seed` + `FROM ${NIX_SEED_IMAGE} AS nix-seed` / `COPY --from=nix-seed` 取用 (BuildKit 不支援 `--from` 變數展開, 故用 stage alias)。改 seed 工具清單 = 改這個 Dockerfile, seed 只重裝 1 次。
- 服務 (port): buzz relay 3000 (+pg/redis/minio) · frontdoor (buzz-acp→`hermes acp`, 與 buzz 共用 netns) · hermes gateway 8642 (API server; dashboard 關閉) · hermes-dashboard 9119 (web UI, 掛 frontdoor 的 hermes home, 看 buzz 對話 session/thinking log) · paperclip 3100 · tencentdb core 8420 / panel 8125 / knowledge 8424 / proxy 8096。
- LLM: OpenCode Go (`https://opencode.ai/zen/go/v1`)。`.env` 填 `OPENCODE_API_KEY` 一個 key 全棧通用; hermes 以 `provider: custom` + `OPENAI_BASE_URL/KEY` 接。

## 常用指令

```bash
scripts/setup.sh              # 新機器一鍵: .env → submodule init → prepare → build → up
scripts/prepare.sh            # patches/ → upstream/ 同步 (改 patch 後、build 前必跑)
scripts/upgrade.sh <proj> <tag>  # 升版: checkout 新 tag → prepare → rebuild → redeploy
scripts/test-connectivity.sh  # 連通性測試 (不碰 LLM)
docker compose up -d --build  # 啟動/重建 (改過 patches/ 後); host config (gh creds) 由 host-sync one-shot 自動同步
docker compose logs -f <svc>
docker compose down           # 停 (volume 保留); down -v 全清
scripts/sync-gh-creds.sh      # host GitHub cred 變更後手動重同步 (自動同步已涵蓋 down -v 場景)
scripts/sync-claude-creds.sh  # host Claude OAuth cred 重同步 (token 輪替後容器端失效時跑)
```

- 改 `patches/<proj>/` 後: `scripts/prepare.sh` → `docker compose up -d --build <svc>`。
- 手動 build 單一 image: `docker build --target opc-relay -t ${IMAGE_PREFIX:-opc}/buzz:local -f upstream/buzz/opc/Dockerfile upstream/buzz` (其餘服務同理, 見 compose 的 build 區段)。
- image prefix 由 `.env` `IMAGE_PREFIX` 控制 (預設 `opc`); compose project name 由 `COMPOSE_PROJECT_NAME` 控制 (預設 `opc`)。

## 不變量 (改動前必讀)

1. **Buzz 一個 canonical host = 一個 community** (schema UNIQUE + NIP-42/98 以連線 host 驗簽名)。改 host → 改 `.env` `BUZZ_RELAY_URL` → 重啟 buzz + frontdoor → **重跑 add-member** (community 是新的)。Host 不要用 proxy 改寫 (會弄壞簽名驗證)。
2. **Hermes Kanban 關閉** (Paperclip 是唯一 work plane): hermes/frontdoor 的 config.yaml seed 有 `agent.disabled_toolsets: [kanban]` + dispatcher off。別把它們開回來。
3. **nix tool 持久化**: hermes/buzz/frontdoor/paperclip 的 `/nix` 是 named volume, 首次開機從 image 內的 `/nix-seed` (nix-seed stage 提供) seed + 每 boot 自癒 (缺 rg/mise/just/gh 任一 → 重加 8 工具, unpinned nixpkgs)。加 tool 用 `nix profile add` (deprecated `install` 會蓋掉 profile)。
4. **mise toolchain 持久化**: buzz/frontdoor/hermes/paperclip 各有 `*-mise:/opt/mise` volume; 空狀態首次開機 `opc-mise-seed.sh` 自動裝 node@lts + rust@stable + omp prebuilt (`github:can1357/oh-my-pi@17.3.5`, ~170MB)。PATH 尾掛 mise shims (baked node 優先, mise 補缺口)。日常加 toolchain = `docker exec <c> mise install <tool>`; 升 omp = `mise install github:can1357/oh-my-pi@latest` (零 rebuild)。
5. `docker compose down -v` 後: relay/agent keys、community、tencentdb admin、paperclip bootstrap 全部重建 (bootstrap 皆 one-shot 自動化, 應一次到位); `opc-gh-creds` 由 `host-sync` one-shot 在每次 `up` 從 host `~/.ssh`/`~/.config/gh`/`~/.gitconfig` 自動鏡像, 不會再空 volume; `opc-prototyper-home` 同理由 `host-sync-claude` 從 host `~/.claude/.credentials.json` 重建 (無 host login 只是 claude_local 不可用, 不擋 `up`)。
6. 容器內 root 隨便折騰, 但**沒有 host mount / privileged** — 隔離不可破壞。
7. **`upstream/` 是 submodule** — 直接改它 = 改壞版控。改動一律放 `patches/`。升版後 (新 tag checkout) patches 可能不兼容, 升版前 review upstream changelog。

## 已知坑 (踩過)

- `buzz-admin` 讀 `RELAY_URL` env (不是 BUZZ_RELAY_URL); add-member 需 DATABASE_URL/REDIS_URL + relay key + S3 env。
- Paperclip `pi_local` adapter 不兼容 omp v17 (flag 差異); 整合 omp 用 `claude_local` + `engine:"acp"` + `agentCommand:"omp acp --yolo"` (handshake 已驗證, 見 SETUP.md)。
- **Claude cred 只鏡像 `.credentials.json` 一個檔** (`host-sync-claude` one-shot → `opc-prototyper-home` volume, 掛 paperclip `/agent-homes/prototyper` = prototyper agent 的 `adapterConfig.env.HOME`)。host 的 `settings.json`(含 hook)、`plugins/`、`skills/`、`projects/`、`history.jsonl` 一律不進容器 — 容器內的 claude 是乾淨的。**OAuth refresh token 是單次使用**: 容器端刷新會讓 host 那份失效 (反之亦然), 壞了跑 `scripts/sync-claude-creds.sh` 重同步。`.env` 的 `ANTHROPIC_API_KEY` 若有值會蓋掉 OAuth (改用 API 計費), 想吃訂閱就留空。
- PyPI 的 hermes-agent 停在 0.19.0 → 0.20.1 用 editable install from git tag (`pip install -e "…[acp]"`)。
- **frontdoor 的 hermes acp 必須以 uid 10000 跑** (buzz-acp 以 root spawn, 靠 `patches/buzz/opc-hermes-acp.sh` setpriv wrapper drop): 共享 home (frontdoor-hermes volume) 同時被 hermes-dashboard (uid 10000) 服務, root 寫的 `state.db` 對 10000 是 read-only → 大量 `TUI session store unavailable` warning。`/keys` 是 ro mount, agent 子進程的 buzz wrapper 改讀 `$HERMES_HOME/.agent.nsec` (entrypoint 開機複製)。**agent 的 `HOME` 只在 wrapper 內設成 `/opt/data`, 不要在全域 export** — entrypoint seed 若寫進共享 home (e.g. nix 的 `.nix-profile` symlink 指向 `/nix/...`) 會讓 dashboard Files page 對整個目錄 403 (`Path outside managed files root`, symlink resolve 出 root)。agent 的 omp config 由 entrypoint seed 到 `$HERMES_HOME/.omp/`。
- TencentDB `MemoryKnowledge/Dockerfile` upstream 是壞的 → hub 用 `deploy/panel-knowledge-combined`。
- **TencentDB 面板 (8125) 是 meta-plane 驅動**: L0-L3 寫進 data plane 後, team/agent 沒在 meta registry (`/v3/meta/*`, sqlite `tdai_metadata_default`) 登記 → 面板全空 (`ensureChatMemoryAsset` 每筆 conversation/add 都 warn `agent not found`)。provision 由 `tencentdb-bootstrap` one-shot 處理 (`opc-tencentdb-provision.sh`), agent_id **必須以 `agt` 開頭** (面板用 `lastIndexOf('-agt')` 解析 `chat_memory-{team}-{agent}`)。
- **TencentDB L0/L1 以 user_id 隔離**: 面板用 `asset.owner_user_id` 查 data plane, 所以 plugin 的 `MEMORY_TENCENTDB_USER_ID` 必須 = admin user_id (bootstrap 寫入 `/keys/tencentdb-admin-user-id`, entrypoint export)。留空 = `default` → 面板層級全 0。
- TencentDB Gateway zod 上限: message content ≤8192 / query ≤2048 → plugin (`client.py`) 在邊界截斷 (頭尾保留 + marker), 超過會整筆 L0 寫入 400 掉。改 plugin 記得同步 `patches/hermes/` 與 `patches/buzz/` 兩份。
- nix static build 不吃 `/nix/etc/nix/nix.conf` 預設路徑 → 靠 `NIX_USER_CONF_FILES` env; build 時需要 nixbld group+user。
- **空 `*-mise` volume 首次開機會下載 node/rust/omp** (數分鐘, 看網路); bootstrap 完成前 `mise ls`/`just`/`omp` 可能失敗 — entrypoint 每 boot 檢查, 重開機即補。
- **paperclip 既有 nix profile 有舊 omp 17.3.4** 會 shadow mise 的 17.3.5 (fresh nix volume 後消失)。
- **rust toolchain 在 `$HOME/.cargo` (container layer)**: recreate 後首次 rustc/cargo 觸發 lazy ~300MB 重裝 (RUSTUP_HOME/CARGO_HOME 移 volume 的 fix 因 daemon-user write perm 考量擱置)。
- **`docker exec` 互動 session 不繼承 entrypoint runtime export 的 env** (GH_CONFIG_DIR / GIT_SSH_COMMAND / GIT_CONFIG_GLOBAL): 需手動 `. /usr/local/bin/opc-gh-seed.sh` 補上。mise shims (`/opt/mise/shims`) 已 bake 進 image ENV PATH 尾, 所以 exec 也吃得到 omp/rustc/cargo (volume seed 後)。

## 檔案地圖

- `docker-compose.yml` / `.env.example` / `SETUP.md` — 部署核心
- `patches/<proj>/` — 改寫的 Dockerfiles + entrypoints (唯一客製來源; 內容 = 各 repo 的 opc/ 目錄)
- `patches/nix-seed/` — nix seed build context (nix 2.35.2 + 8 工具, `cp -al` 成 `/nix-seed`); compose `nix-seed` 是 one-shot, 消費者 = 各 service Dockerfile 的 `COPY --from=nix-seed`
- `patches/<proj>/opc-mise-seed.sh` — 每 project 一份, entrypoint source 的 mise bootstrap (空 volume 自動裝 node/rust/omp)
- `patches/tencentdb-agent-memory/MemoryCore/` — tencentdb-core 的 opc Dockerfile (schema overlay: team/create + agent/create 接受顯式 id) + `opc-tencentdb-provision.sh` (meta-plane bootstrap)
- `scripts/` — setup / prepare / upgrade / test-connectivity; `host-sync.sh` (通用 host→volume 鏡像 CLI) + `host-sync-worker.sh` (容器側 engine, 唯一邏輯) + `hooks/` (per-source 轉換, ssh/gitconfig/claude-cred) + `sync-gh-creds.sh` / `sync-claude-creds.sh` (場景薄 wrapper); compose `host-sync` (gh) 與 `host-sync-claude` (Claude cred) 兩個 one-shot 每次 up 自動跑
- `upstream/<proj>/opc/` — prepare.sh 產物, 勿手改
- `acp-smoke-test.mjs` — omp ACP handshake 驗證 script (在 paperclip 容器內跑)
