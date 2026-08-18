# AGENTS.md — OPC Stack

Buzz (對話) + Hermes (agent runtime) + Paperclip (work 控制面) + TencentDB-Agent-Memory (agent memory) 的 docker compose 部署。**本 repo 不實作 Nodalis**(架構決策: `docs/nodalis-prd-v10.1.md`)。

## 架構

- **`upstream/`** = 4 個 git submodule, pin 在 upstream tag commit (乾淨 checkout, 永不直接編輯): buzz `desktop-v0.5.14` / hermes `v2026.8.16` / paperclip `canary/v2026.722.1-canary.0` / tencentdb `v2.0.0`。
- **`patches/`** = 全部本地客製 (opc/Dockerfile、entrypoints、one-shot scripts)。build 前 `scripts/prepare.sh` 把 `patches/<proj>/` rsync 進 `upstream/<proj>/opc/` (冪等)。**改 image 一律改 `patches/`, 不改 upstream 主 Dockerfile。**
- **`patches/nix-seed/`** = 第一個不屬 submodule 的 build context (compose service `nix-seed`, one-shot)。pin nix 2.35.2 + nixpkgs `8be7bd0c83f1`, 建 `/nix-seed` (cp -al hardlink) 含 8 工具 (ripgrep jq fd htop bat just mise gh)。各 build service `depends_on nix-seed` + `FROM ${NIX_SEED_IMAGE} AS nix-seed` / `COPY --from=nix-seed` 取用 (BuildKit 不支援 `--from` 變數展開, 故用 stage alias)。改 seed 工具清單 = 改這個 Dockerfile, seed 只重裝 1 次。
- **prototype lane** (`prototype` CLI, paperclip image): 一個 prototype = 一個 Paperclip project + `/prototypes/<name>` (自己的 git) + 一個 devenv 租約 + 一個掛在 **project workspace** 上的 runtime service。服務掛 project 層而非 execution workspace,所以沒有 issue 在跑時宣告仍在,**preview URL 跨 session 不變**。`prototype create` 冪等,同時是「建立」與「用名字接續」的路徑。設計見 `docs/superpowers/specs/2026-08-18-devenv-http-preview-design.md`。
- **devenv** (`docker-compose.yml` 的 `devenv-pg` / `devenv-valkey`): paperclip agent 的開發資源租約。agent 跑 `devenv provision <key>` 拿到獨立的 postgres DB (pgvector) + valkey ACL user, 寫進 workspace `.env` 的 `DATABASE_URL`/`VALKEY_URL`。刻意不給 agent docker (不變量 6); 設計見 `docs/superpowers/specs/2026-08-18-devenv-resource-provisioning-design.md`。
- 服務 (port): buzz relay 3000 (+pg/redis/minio) · frontdoor (buzz-acp→`hermes acp`, 與 buzz 共用 netns) · hermes gateway 8642 (API server; dashboard 關閉) · hermes-dashboard 9119 (web UI, 掛 frontdoor 的 hermes home, 看 buzz 對話 session/thinking log) · paperclip 3100 · tencentdb core 8420 / panel 8125 / knowledge 8424 / proxy 8096。
- LLM: OpenCode Go (`https://opencode.ai/zen/go/v1`)。`.env` 填 `OPENCODE_API_KEY` 一個 key 全棧通用; hermes 以 `provider: custom` + `OPENAI_BASE_URL/KEY` 接。

## 運作模型 (為什麼派工長這樣)

PRD (`docs/nodalis-prd-v10.1.md`) 的核心規則: **一個概念只能有一個 durable writer authority。**

| Truth | Owner |
|---|---|
| 對話 | Buzz |
| 意圖判斷 / triage | Front-door Hermes |
| durable work (issue / assignment / status) | **Paperclip** |
| 執行 | Hermes / omp / 其他 runtime |
| 學到的知識 | TencentDB Agent Memory |
| 事實來源 (code / docs) | Git repo |

日常實際流向:

```text
Human
  │ 定義價值 / 做重要判斷
  ▼
Buzz  (或 hermes-dashboard chat / 未來 Telegram — 同一個 agent, 不同 platform adapter)
  │
  ├─ 沒價值 ────────→ 消失
  ├─ 值得記住 ──────→ TencentDB chat memory        (已接: memory_tencentdb)
  ├─ 成為公司共識 ──→ TencentDB Wiki / CodeGraph   (服務在跑, 尚未接)
  └─ 承諾要完成 ────→ Paperclip issue
                          │ hermes 在此決定 lane (見「已知坑」的路由條目)
                          ├─ engineering → OMP Engineer
                          └─ prototype   → Prototyper
```

這張圖是好幾條規則的由來:

- **Hermes Kanban 關掉** (不變量 2) — Paperclip 才是 work truth, 不能有第二套。同理禁止任何 runtime 的
  internal todo/plan 跨 invocation 存活: 要被別人接手或被人追蹤, 就得 materialize 成 Paperclip issue。
- **派工路由放 skill 而非 system_prompt** — hermes 是上圖的 triage 層, 而三個入口是同一個 agent。
- **memory 只影響 reasoning** — recall 到「上次說 production 可以自動 deploy」只是 context, **不得**
  當成 capability / credential / production / 付款 / 對外授權的依據。PRD 硬邊界, 破壞它算 architecture
  regression 不算 integration 便利。
- **知識不會自動升格** — capture 可以隨意, 升成 team 資產要顯式 review。「跑成功一次」≠ OPC SOP。

Lean Mode (拿掉 Paperclip、Hermes Kanban 轉正) 是 PRD 允許的另一種模式, 但**不可與現況混用** —
兩個 canonical work plane 同時存在是明確禁止的。

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
docker compose exec paperclip devenv list   # agent 開發資源用量 (或 SQL client 連 127.0.0.1:5433)
docker compose exec paperclip prototype list          # 目前有哪些 prototype (名字 / port / URL)
docker compose exec paperclip prototype restore       # 手動把該跑的 preview 叫回來 (開機時會自動跑)
docker compose exec -it paperclip prototype destroy <name>   # 唯一的刪除路徑, 會先列出再要你打名字
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
6b. **prototype 與正式 project 同級, 只有人明確要求才刪。** 沒有任何自動回收 —
   devenv 租約、prototype 目錄、Paperclip project 都不會被排程清掉 (已確認 paperclip
   server 的 5 個週期性 timer 沒有一個碰 workspace/project)。唯一的刪除路徑是
   `prototype destroy <name>`, 它會先列出將刪的東西並要求打名字確認, 且**刻意不提供
   `--yes`** — 那個旗標會讓這條規則變成一行 script 就能繞過。閒置 7 天只停 process,
   不動資料。
7. **`upstream/` 是 submodule** — 直接改它 = 改壞版控。改動一律放 `patches/`。升版後 (新 tag checkout) patches 可能不兼容, 升版前 review upstream changelog。

## 已知坑 (踩過)

- `buzz-admin` 讀 `RELAY_URL` env (不是 BUZZ_RELAY_URL); add-member 需 DATABASE_URL/REDIS_URL + relay key + S3 env。
- Paperclip `pi_local` adapter 不兼容 omp v17 (flag 差異); 整合 omp 用 `claude_local` + `engine:"acp"` + `agentCommand:"omp acp --yolo"` (handshake 已驗證, 見 SETUP.md)。
- **「hermes 不自己實作」這條規則住在 `SOUL.md`, 不是 skill 也不是 `config.yaml`**。三個位置都試過, 只有一個成立:
  - **skill 不行** — skill 只能影響「已經決定載入它」的 model, 而「不要自己做」必須在那個決定**之前**就成立。實測反例: 請 frontdoor prototype 一個小工具, 它把整個 app 寫進自己的 home、上傳到 Buzz media, **一張 ticket 都沒開**。
  - **`config.yaml` 的 `agent.system_prompt` 也不行** — 那個 key 由 `cli.py` 的 `class HermesCLI` 解析 (`resolve_ephemeral_system_prompt`), 只對 `hermes chat` 生效。**ACP lane 完全不讀** (`acp_adapter/session.py` 建 `AIAgent(**kwargs)` 時沒傳 `system_prompt`), 而 frontdoor 跑的正是 `hermes acp`。與 `completion_queue` 只被 cli.py / gateway 消耗是同一類的 lane 落差。
  - **`SOUL.md` 才對** — `AIAgent` 自己組 prompt 時會讀 (`agent/system_prompt.py` → `load_soul_md`, 且 scope 在 agent 自己的 `HERMES_HOME`), 所以**每個 lane 都吃得到**。兩個 image 各 bake 一份 `/opt/hermes/SOUL.md`, entrypoint 每次開機覆蓋進 home (與 skill 同一套機制)。兩份必須逐字相同, `scripts/prepare.sh` 會擋。
  lane 表繼續留在 skill (那是會變的細節), 「你不是實作者」是常駐約束。
- **`config.yaml` 不是放「必須成立的規則」的地方**: seed 是「不存在才寫」, 而且 **hermes 會自己遷移它** — frontdoor 的 volume 被遷到 `_config_version 37` 的過程中 **`system_prompt` 整個不見了**, 於是它有很長一段時間在**沒有 system prompt** 的狀態下跑, 而沒有任何地方會顯示這件事。config.yaml 現在只放對話語氣與 Buzz 發文機制, 且每次開機 reconcile。
- **派工路由住在 `paperclip-api` skill, 不在 system_prompt**: hermes 是決定 assignee 的那一層 (Paperclip 在本 stack 沒有自動路由 — 無 CEO、org 全扁平、`role=general`, 未指派的 ticket 沒人會醒)。lane 表 (`engineering`→`OMP Engineer` / `prototype`→`Prototyper`) 放 skill 的理由: skill 由 image 在每次開機同步進 **兩個** hermes home (frontdoor 與 gateway), 而 `config.yaml` 的 system_prompt 是 per-home 且 dashboard 可編輯 — 規則放 prompt 會分歧。**改 skill 要同時改 `patches/buzz/skills/` 與 `patches/hermes/skills/` 兩份** (內容必須相同)。channel 層的 `platforms.<name>.channel_overrides[channel_id]` 可覆寫 system_prompt/model, 但那是 per-platform × per-channel-id, 只適合當加速器, 不要拿來當路由機制。
- **preview 的對外位址由 `PAPERCLIP_PUBLIC_URL` 決定, 不要另外設一份**: `DEVENV_HTTP_PUBLIC_HOST` 留空時從它的 host 推導 (`providers/http.sh`)。理由是 preview 連結**長在 board 上**, 兩者必然從同一個地方被存取 —— 寫成兩個變數只會製造「board 開得起來、連結打不開」這種只有症狀沒有訊息的分歧。發佈位址 `DEVENV_HTTP_BIND` 預設 `0.0.0.0`(與 paperclip/buzz/hermes 一致); 要收窄就設 `127.0.0.1` 或 tailnet IP。**改了要 recreate paperclip 容器**(docker 的 port 發佈在建立容器時固定)。
- **project-only skill = 放進專案目錄, 不是 Paperclip 的 scope**: Paperclip 的 `sharingScope` 只有 `private|company|public_link`, **沒有 project 這個層級**。omp 從工作目錄探索 skill (binary 裡有 `.claude/skills` / `.agents/skills` / `.omp/skills` 三種), 所以 `prototype skill add <name> --from <repo>` 把它 vendor 進 `<project>/.claude/skills/` 並 pin SHA —— 只有這個 prototype 的 session 看得到。用 `.claude/skills` 是因為 Claude Code 也讀它, 換 engine 不會壞。
- **preview server 是 paperclip 的子行程, 容器一重建就全死**, 而 paperclip **沒有** desiredState 的開機 reconciler (server 的 5 個週期性 timer 沒有一個碰 workspace)。症狀最惡劣的地方在於**完全無聲**: board 上一切正常, 只有 URL 是死的。`opc-prototype-restore.sh` 由 entrypoint 背景啟動 (背景是必要的 —— 它要等的 API 正是即將 exec 的那個行程), 等 health 後跑 `prototype restore`。存活判斷是**在容器內 probe `127.0.0.1:<port>`** 而不是信 DB: 重建後 row 還寫著 running 但行程早就不在。
- **preview 不在 localhost, dev server 要明確放行**: `.env` 給 `DEV_HOST`。Next.js 16 對**任何**帶 `Origin` header 且 host 非 localhost 的請求回 **403** —— 連 same-origin 也擋, 所以是日常使用就會中, 不是只有 CORS。症狀是頁面載入後每個 JS chunk 403、畫面看起來壞掉。解法 `allowedDevOrigins: [process.env.DEV_HOST]`; Vite 對應 `server.allowedHosts`。**用 curl 驗不出來**(curl 不送 `Origin`), 一定要用瀏覽器開一次。
- **prototype/preview 的三個坑**: (1) `expose.urlTemplate` 的變數語法是 `{{port}}` 不是 `${port}` (upstream `doc/plans/` 的範例過期); (2) **dev server 一定要綁 `0.0.0.0`** — 綁 loopback 時 paperclip 的 readiness 從容器內打 `127.0.0.1` 會過, 但 host 連不上, 於是 board 顯示綠色 live 卻打不開 (devenv 因此把 `HOST=0.0.0.0` 寫進 `.env`); (3) preview port pool 的 base 必須 **低於 32768** (kernel ephemeral range), 否則 `bind(0)` 可能搶走已租但當下沒 listen 的 port。`DEVENV_HTTP_PORT_RANGE_END` 與 `BASE+COUNT-1` 是兩個必須一致的來源 (compose 不會算術), 開機檢查會 warn。
- **`PAPERCLIP_WORKSPACE_ID` 是 project workspace id, 不是 execution workspace id** (`heartbeat.ts` 塞 `executionWorkspace.workspaceId`, 而 `workspace-runtime.ts` 用它當 `projectWorkspaceId`)。要 execution workspace 得走 `GET /issues/<id>/heartbeat-context` → `.currentExecutionWorkspace.id`。
- **paperclip 不會建 `local_path` workspace 的 cwd** (`mkdir` 只出現在 worktree 路徑), 而 **`setupCommand` 從來不會被執行** (upstream 只有 CRUD 讀寫它)。目錄與 `git init` 由 `prototype create` 在容器內做。
- **指派會叫醒 agent, 不需要排程 heartbeat** (`issue-assignment-wakeup.ts`), 唯一的前置條件是 `issue.status !== "backlog"`。另外 `heartbeatEnabled` **不是欄位** — 相關的只有 agent 的 `status` (`idle` vs `paused`)。回完沒給 disposition 的 issue 會**反覆喚醒** agent。
- **`opc-paperclip-bootstrap.sh` 的 skill/agent 安裝必須 reconcile 而非 create-only**: 改 `patches/` 裡的 skill 或 `desiredSkills` 之後, 若安裝器只在缺席時建立, 變更永遠到不了跑著的 stack — 檔案說一套、agent 讀另一套, 而且沒有任何地方會顯示這個落差。目前 SKILL.md 內容與 Prototyper 的 `desiredSkills` 都會逐次比對更新。
- **Paperclip 的 GitHub skill import 只抓 `SKILL.md`** — 會 pin commit SHA 也會做 trust level 檢查, 但 sibling 檔案 (mattpocock prototype 的 `LOGIC.md`/`UI.md`) 不會跟著進來, 匯進去的 skill 兩條分支都是斷的。所以第三方 skill 一律 **vendor 到 `patches/paperclip/skills/<slug>/`** (附 `SOURCE` 記 repo+SHA), 由 `opc-paperclip-bootstrap.sh` 建成 local skill; 更新跑 `scripts/refresh-vendored-skills.sh`。注意 `GET /skills/:id/files` 的 inventory 會落後 (新增檔案後仍只列 SKILL.md), 以磁碟 `/paperclip/instances/default/skills/<companyId>/<slug>/` 與 run 時物化的 bundle 為準。
- **devenv 回收是手動的** (`devenv release <key>`), 沒有任何自動 gc/排程。累積靠 `devenv_usage` view 看 (按 postgres 磁碟大小遞減 — valkey 槽位用罄會自己以 exit 3 喊, 磁碟不會)。valkey 租戶隔離靠 9.1+ 的 `db=<dbid>` ACL op, **9.0.x 沒有這個功能**, 升降版本前先確認。per-tenant 密碼是從 `DEVENV_SECRET_SALT` 推導而非儲存 (這是 provision 冪等的原因), **改 salt 會讓所有已發出的 `.env` 失效**。agent 身分優先序 `DEVENV_OWNER` → `agent:$PAPERCLIP_AGENT_ID` → `user@hostname`; adapterConfig 的 `env` 值在 ACP lane 存成 `{"type":"plain",...}` 而 env 迴圈跳過非字串, 所以別依賴 `env.DEVENV_OWNER`, `PAPERCLIP_AGENT_ID` 才是每次 run 一定有的。
- **devenv-pg 是 pg18, volume 要掛 `/var/lib/postgresql` 而非其下的 `data`** — 沿用 pg17 的掛法 image 會拒絕啟動。
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
- `patches/{buzz,hermes}/SOUL.md` — agent 身分 + 「不自己實作」規則 (兩份必須相同; 唯一對所有 lane 都生效的位置)
- `patches/<proj>/opc-mise-seed.sh` — 每 project 一份, entrypoint source 的 mise bootstrap (空 volume 自動裝 node/rust/omp)
- `patches/tencentdb-agent-memory/MemoryCore/` — tencentdb-core 的 opc Dockerfile (schema overlay: team/create + agent/create 接受顯式 id) + `opc-tencentdb-provision.sh` (meta-plane bootstrap)
- `patches/paperclip/skills/<slug>/` — vendor 的第三方 skill (SKILL.md + sibling 檔 + `SOURCE` 記 repo/SHA); image 內落在 `/opt/opc-skills/`, bootstrap 裝進 company library
- `patches/paperclip/prototype/` — `prototype` CLI (paperclip-aware 的工作流層: project + git + 租約)。**刻意不放進 devenv** — devenv 是通用資源租約, 不該認識 paperclip; 它只多一個 `mark-exposed` 供 `devenv list` 標記
- `patches/paperclip/skills/{devenv,prototype-workspace}/` — first-party skill (租約用法 / prototype 工作流 + 覆寫 vendored `prototype` skill 的第 1、3、6 條規則)
- `patches/paperclip/devenv/` — `devenv` CLI + `providers/{postgres,valkey}.sh` + `bootstrap.sql`;
  image 內落在 `/usr/local/lib/devenv/`, symlink 到 `/usr/local/bin/devenv`。schema 由 `opc-devenv-seed.sh` 每次開機套用 (冪等, 後端不通只警告不擋 `up`)
- `scripts/prepare.sh` — 除了同步 patches, 還有**防漂移檢查**: 兩份 `paperclip-api` SKILL.md 與兩份 `SOUL.md` 必須逐字相同, 不同就中止 build (這條規則在本 repo 已經默默壞過三次)
- `scripts/` — setup / prepare / upgrade / test-connectivity; `host-sync.sh` (通用 host→volume 鏡像 CLI) + `host-sync-worker.sh` (容器側 engine, 唯一邏輯) + `hooks/` (per-source 轉換, ssh/gitconfig/claude-cred) + `sync-gh-creds.sh` / `sync-claude-creds.sh` (場景薄 wrapper); compose `host-sync` (gh) 與 `host-sync-claude` (Claude cred) 兩個 one-shot 每次 up 自動跑
- `upstream/<proj>/opc/` — prepare.sh 產物, 勿手改
- `acp-smoke-test.mjs` — omp ACP handshake 驗證 script (在 paperclip 容器內跑)
