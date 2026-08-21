# AGENTS.md — OPC Stack

Buzz (對話) + Hermes (agent runtime) + Paperclip (work 控制面) + TencentDB-Agent-Memory (agent memory) 的 docker compose 部署。**本 repo 不實作 Nodalis**(架構決策: `docs/nodalis-prd-v10.1.md`)。

## 架構

- **`upstream/`** = 4 個 git submodule, pin 在 upstream tag commit (乾淨 checkout, 永不直接編輯): buzz `desktop-v0.5.14` / hermes `v2026.8.16` / paperclip `canary/v2026.722.1-canary.0` / tencentdb `v2.0.0`。
- **`patches/`** = 全部本地客製 (opc/Dockerfile、entrypoints、one-shot scripts)。build 前 `scripts/prepare.sh` 把 `patches/<proj>/` rsync 進 `upstream/<proj>/opc/` (冪等)。**改 image 一律改 `patches/`, 不改 upstream 主 Dockerfile。**
- **`patches/nix-seed/`** = 第一個不屬 submodule 的 build context (compose service `nix-seed`, one-shot)。pin nix 2.35.2 + nixpkgs `8be7bd0c83f1`, 建 `/nix-seed` (cp -al hardlink) 含 13 工具 (ripgrep jq fd htop bat just mise gh procps iproute2 lsof postgresql valkey — procps/iproute2/lsof 是 ps/pkill/ss/lsof, 沒有它們連「誰在跑」「誰佔著 port」都查不了; postgresql 是為了 **client** psql/pg_isready —— 每個 devenv 租戶 (prototype lane、現在加上 scientist expert) 都握著一個 postgres 租約, 操作者被要求直接拿 SQL client 接上去 (`devenv list` 那行「或 SQL client 連 127.0.0.1:5433」), client 因此屬於 seed, 與任何測試是否存在無關; nixpkgs 沒有 client-only 切分所以 server binary 一起進來 (量到的 closure ~166MB, 沒有單一依賴獨占多數 — icu4c ~40MB、postgresql 本體 ~26MB、其餘是 curl/openssl/glibc 系), valkey 同理且證據相同 —— 每個 devenv 租約都同時發 `VALKEY_URL`, 所以 client 該跟 `psql` 成對存在; 選 `valkey` 不選 `redis` 是因為伺服器是 valkey 9.1 而租戶隔離靠它 9.1+ 的 `db=<dbid>` ACL op, 何況這個 package 同時裝出 `valkey-*` 與 `redis-*` 兩套 binary, 是超集 (量到的邊際成本 ~100MB / 33 個 store path, 幾乎全是 seed 原本沒有的完整 systemd); 沒有任何東西會啟動它, 而這筆成本不只付在共用的 `opc-nix` volume 一次 —— `COPY --from=nix-seed /nix-seed /nix-seed` 把同一份 seed 烤進**每個** service image 的 layer, 所以也逐 image 付一次)。各 build service `depends_on nix-seed` + `FROM ${NIX_SEED_IMAGE} AS nix-seed` / `COPY --from=nix-seed` 取用 (BuildKit 不支援 `--from` 變數展開, 故用 stage alias)。改 seed 工具清單 = 改這個 Dockerfile, seed 只重裝 1 次。
  **`depends_on` 不排序 build, 只排序啟動** —— 而這裡的 seed 是別人的 base image。compose 把整組交給 buildx bake 當**一張平行圖**跑, 所以乾淨機器上 paperclip 的 `FROM` 會在 nix-seed 還在 build 時就去解析, 解不到就轉去 registry, 死在 `pull access denied for <prefix>/nix-seed` —— 一個看起來完全不像順序問題的授權錯誤。`scripts/setup.sh` 因此先單獨 `docker compose build nix-seed` 再 `up -d --build`。任何機器只要 build 過一次就再也看不到這個 bug (image 已在 store 裡), 它只咬乾淨安裝 —— 由 `tests/fresh-install.sh` 抓到。
- **prototype lane** (`prototype` CLI, paperclip image): 一個 prototype = 一個 Paperclip project + `/prototypes/<name>` (自己的 git) + 一個 devenv 租約 + 一個掛在 **project workspace** 上的 runtime service。服務掛 project 層而非 execution workspace,所以沒有 issue 在跑時宣告仍在,**preview URL 跨 session 不變**。`prototype create` 冪等,同時是「建立」與「用名字接續」的路徑。設計見 `docs/superpowers/specs/2026-08-18-devenv-http-preview-design.md`。
- **devenv** (`docker-compose.yml` 的 `devenv-pg` / `devenv-valkey`): agent 的開發資源租約, **兩類租戶**。(1) paperclip agent 自己跑 `devenv provision <key>`, 拿到獨立的 postgres DB (pgvector) + valkey ACL user, 寫進 workspace `.env` 的 `DATABASE_URL`/`VALKEY_URL`。(2) **hermes 專家 agent 有常駐租約**: one-shot `devenv-expert-leases` (跑 paperclip image, 因為 devenv CLI 只住在那裡) provision `scientist` 到 `/keys/devenv-scientist.env`, hermes entrypoint 的 `opc_seed_expert_profile()` 把它 merge 進 profile 的 `.env`。**租約壞掉只會降級專家, 不會擋 gateway 起來** —— one-shot 一律 exit 0, 失敗時印 WARNING (詳見不變量 8)。刻意不給 agent docker (不變量 6); 設計見 `docs/superpowers/specs/2026-08-18-devenv-resource-provisioning-design.md`。
- 服務 (port): buzz relay 3000 (+pg/redis/minio) · frontdoor (buzz-acp→`hermes acp`, 與 buzz 共用 netns) · hermes gateway 8642 (API server; dashboard 關閉; **專家 agent 的宿主** — multiplex 服務 `hermes-profiles` volume 上的每個 profile, 目前有 `agt-scientist`) · hermes-dashboard 9119 (web UI, 掛 frontdoor 的 hermes home, 看 buzz 對話 session/thinking log) · paperclip 3100 · tencentdb core 8420 / panel 8125 / knowledge 8424 / proxy 8096。
- LLM: OpenCode Go (`https://opencode.ai/zen/go/v1`)。`.env` 填 `OPENAI_API_KEY` 一個 key 全棧通用;Hermes custom provider runtime 讀 `OPENAI_API_KEY` + `OPENAI_BASE_URL`。shared gateway/dashboard/Paperclip/TencentDB 的 model 用 `OPENAI_MODEL`（預設 deepseek-v4-flash）,frontdoor relay 用 `BUZZ_AGENT_MODEL`（預設 deepseek-v4-pro）;模型選擇以 `config.yaml` 為 source of truth。

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

## 部署假設 (誰會跑這個 stack)

**現況: 一個使用者、一台在跑的 stack、專案尚未對外開放。**

由此推出兩條相反方向的規則, 兩條都要成立:

- **不寫 migration / 升版腳本。** 既有那台**手動調整就好** —— 改動附一段可以整段貼的
  指令即可 (放 `SETUP.md`), 不要為了一台機器建立一條要長期維護的升級路徑。
  (`scripts/upgrade.sh` 是**另一回事** —— 它升的是 upstream submodule 的 tag, 不是遷移
  我們自己產生的狀態。)
- **但必須假設別人開箱即用。** 乾淨機器 `git clone` → `scripts/setup.sh` 之後,
  **全部功能可用, 不需要任何手動補步驟**。所以每一份狀態 (金鑰、community membership、
  board agent、meta registry 註冊、profile 目錄、租約……) 的產生者都得是 **compose 的
  one-shot 或 entrypoint, 而且冪等**。

**最容易騙過自己的地方**: compose 的 one-shot 在**容器已存在且 exit 0 時不會重跑**。
所以開發時「我 `docker compose up --force-recreate <bootstrap>` 過, 它會動」對**乾淨
安裝完全沒有證明力** —— 那台機器上根本沒有那個容器, 走的是另一條路徑。真正算數的驗證
只有真的從空狀態走一次 `setup.sh` 之後三條 gate 直接綠 —— 但**不要在這台上
`docker compose down -v`** (會毀掉 community/board/memory/prototype/租約)。
跑 `tests/fresh-install.sh`: 它把 repo clone 出去、換 compose project /
image prefix / 全部 port (+1000) / 自己的 Buzz relay, 在活著的 stack **旁邊**
做完整排練, 再從 clone 裡跑 audit-bootstrap + test-connectivity + test-scientist。
`tests/audit-bootstrap.sh` 只是靜態稽核, 不是這件事的證明。

## 常用指令

```bash
scripts/setup.sh              # 新機器一鍵: .env → submodule init → prepare → build → up
scripts/prepare.sh            # patches/ → upstream/ 同步 (改 patch 後、build 前必跑)
scripts/upgrade.sh <proj> <tag>  # 升版: checkout 新 tag → prepare → rebuild → redeploy
tests/connectivity.sh  # 連通性測試 (不碰 LLM)
tests/fresh-install.sh # 開箱排練: clone 到別的 compose project 走一次 setup.sh (慢, 偶爾跑)
docker compose up -d --build  # 啟動/重建 (改過 patches/ 後); host config (gh creds) 由 host-sync one-shot 自動同步
docker compose logs -f <svc>
docker compose down           # 停 (volume 保留); down -v 全清
scripts/sync-gh-creds.sh      # host GitHub cred 變更後手動重同步 (自動同步已涵蓋 down -v 場景)
scripts/sync-claude-creds.sh  # host Claude OAuth cred 重同步 (token 輪替後容器端失效時跑)
docker compose exec paperclip devenv list   # agent 開發資源用量 (或 SQL client 連 127.0.0.1:5433)
docker compose exec paperclip prototype list          # 目前有哪些 prototype (名字 / port / URL)
docker compose exec paperclip prototype restore       # 手動把該跑的 preview 叫回來 (開機時會自動跑)
docker compose exec paperclip prototype templates     # 可用的 scaffold
tests/prototype-template.sh nextjs [ui]        # template/layer smoke test (建→裝→migrate→serve→驗兩個後端→刪)
docker compose exec -it paperclip prototype destroy <name>   # 唯一的刪除路徑, 會先列出再要你打名字
```

- 改 `patches/<proj>/` 後: `scripts/prepare.sh` → `docker compose up -d --build <svc>`。
- 手動 build 單一 image: `docker build --target opc-relay -t ${IMAGE_PREFIX:-opc}/buzz:local -f upstream/buzz/opc/Dockerfile upstream/buzz` (其餘服務同理, 見 compose 的 build 區段)。
- image prefix 由 `.env` `IMAGE_PREFIX` 控制 (預設 `opc`); compose project name 由 `COMPOSE_PROJECT_NAME` 控制 (預設 `opc`)。

## 不變量 (改動前必讀)

1. **Buzz 一個 canonical host = 一個 community** (schema UNIQUE + NIP-42/98 以連線 host 驗簽名)。改 host → 改 `.env` `BUZZ_RELAY_URL` → 重啟 buzz + frontdoor → **重跑 add-member** (community 是新的)。Host 不要用 proxy 改寫 (會弄壞簽名驗證)。
2. **Hermes Kanban 關閉** (Paperclip 是唯一 work plane): hermes/frontdoor 的 config.yaml seed 有 `agent.disabled_toolsets: [kanban]` + dispatcher off。別把它們開回來。
3b. **兩條入口、兩個身分**: entrypoint 以 root 起再降權到 runtime user, 但 `docker compose exec` **永遠**落在 root — 兩者共用同一批可寫的樹, 而**誰先建立誰擁有**。paperclip entrypoint 的 `opc_own_runtime_trees` 每次開機用 first-mismatch `find` 探測 `/prototypes` 與 runtime user 的 cache, 不符才 `chown -R`(乾淨時只花一次 metadata walk)。之所以值得主張這個不變量, 是因為**症狀都不像權限問題**: git 說 `dubious ownership` 然後 commit 靜靜失敗、Next 的 `EACCES: mkdir .next/dev` 只以 API 500 呈現、pnpm 說 `attempt to write a readonly database`。這與 `/keys` 是**不同**問題 — 那邊是刻意的 600 root 機密, 解法是鏡像一份給 runtime uid, 不是 chown。
3. **nix: 一個 store、一個 daemon、兩層 profile**。`/nix` 是**單一共用 volume `opc-nix`** (buzz/frontdoor/hermes/hermes-dashboard/paperclip 全掛同一個), 由 compose service **`nix-daemon`** 獨佔擁有 (`patches/nix-seed/opc-nix-daemon.sh`, 與 nix-seed 同 image 的長駐角色)。之所以能一個 daemon 服務全部容器: **unix socket 放在共用 volume 上跨容器連得到** (實測: daemon 在 hermes、client 在 hermes-dashboard 以 uid 10000 連上)。daemon 獨佔的原因是這些事只能有一個 writer: volume seeding、系統 profile 自癒、共用 agent profile、wrapper 發佈 —— 四個容器同時對同一個 store 自癒就是 race。
   - **兩層 profile**: 系統層 `per-user/root/profile` (12 工具, **只有 root 能改**) 在 PATH **最前**; 共用 agent 層 `profiles/opc-agents/profile` 在其後。所以 agent 裝的東西全棧可見, 但**蓋不掉**系統工具, 自癒也騙不了 (偵測讀 profile 路徑, 不是 `command -v`)。**加新 seed 工具時必須同時加進偵測條件** (`patches/nix-seed/opc-nix-daemon.sh` 的 `SEED_TOOLS` 清單 — 偵測與自癒的安裝清單都從它派生, 只有一個地方要改; 與 Dockerfile 的清單是兩個必改的地方), 否則既有 volume 永遠收不到它 —— image 的 `/nix-seed` 只在 volume 空的時候被複製, 既有 volume 的唯一入口是自癒。自癒與 Dockerfile 用**同一個 pin** (`$NIXPKGS`), 否則既有機器拿到的版本會與乾淨機器不同。
   - **agent 自主安裝**: nix 從 single-user 改為 **multi-user**, 非 root 的 agent 自動偵測 socket 即可安裝。權限靠群組 **`nixagents` gid 3000** (跨 image 必須同數字 —— 共用 volume 上比對的是數字); hermes 的 s6-setuidgid 與 paperclip 的 gosu 都會帶 supplementary groups, 但 frontdoor 的 `opc-hermes-acp.sh` 用 `setpriv --groups 3000` (該 image 沒有 uid 10000 的 passwd entry, `--init-groups` 不能用, 而原本的 `--clear-groups` 會把群組全丟掉)。
   - **agent 一律走 `nix-add` / `nix-rm` / `nix-list`** (daemon 發佈到 `/nix/var/nix/opc-bin`), **不要裸 `nix profile add`**。兩個理由: 裸 add 進的是呼叫者自己的 profile, 不在別人 PATH 上 (「裝一次大家都有」無聲失效); 而且它會在 `$HOME` 留下 resolve 得進 `/nix/store` 的 symlink 鏈, 而 hermes-dashboard 的 Files page 用無 per-entry 保護的 list comprehension 建清單 (`web_server.py:2562-2567`), 對逃出 managed root 的 entry 直接 403 (`:2425`) —— **一條 symlink 就讓整個目錄列不出來**。帶 `--profile` 時 symlink 指向 HOME 內尚未存在的路徑, 不會逃逸 (兩種都實測過)。frontdoor entrypoint 另有開機清除當保險。
   - root 經 `docker exec` 的 `nix profile add` 仍然是**系統層**安裝 (SETUP.md 的既有語意不變)。加 tool 用 `add` (deprecated `install` 會蓋掉 profile)。
   - **agent 不准 `apt-get`**: apt 寫進 container layer, rebuild/recreate 就消失; nix 寫進 volume。規則寫在 `patches/{buzz,hermes}/SOUL.md` (hermes 全 lane) 與 `patches/paperclip/skills/container-tools/` (omp agent)。
4. **mise toolchain 持久化**: buzz/frontdoor/hermes/paperclip 各有 `*-mise:/opt/mise` volume; 空狀態首次開機 `opc-mise-seed.sh` 自動裝 node@lts + rust@stable + omp prebuilt (`github:can1357/oh-my-pi@17.3.5`, ~170MB)。PATH 尾掛 mise shims (baked node 優先, mise 補缺口)。日常加 toolchain = `docker exec <c> mise install <tool>`; 升 omp = `mise install github:can1357/oh-my-pi@latest` (零 rebuild)。
5. `docker compose down -v` 後: relay/agent keys、community、tencentdb admin、paperclip bootstrap 全部重建 (bootstrap 皆 one-shot 自動化, 應一次到位); `opc-gh-creds` 由 `host-sync` one-shot 在每次 `up` 從 host `~/.ssh`/`~/.config/gh`/`~/.gitconfig` 自動鏡像, 不會再空 volume; `opc-prototyper-home` 同理由 `host-sync-claude` 從 host `~/.claude/.credentials.json` 重建 (無 host login 只是 claude_local 不可用, 不擋 `up`)。
6. 容器內 root 隨便折騰, 但**沒有 host mount / privileged** — 隔離不可破壞。
6b. **prototype 與正式 project 同級, 只有人明確要求才刪。** 沒有任何自動回收 —
   devenv 租約、prototype 目錄、Paperclip project 都不會被排程清掉 (已確認 paperclip
   server 的 5 個週期性 timer 沒有一個碰 workspace/project)。唯一的刪除路徑是
   `prototype destroy <name>`, 它會先列出將刪的東西並要求打名字確認, 且**刻意不提供
   `--yes`** — 那個旗標會讓這條規則變成一行 script 就能繞過。閒置 7 天只停 process,
   不動資料。手動回收面共兩條: prototype 走 `prototype destroy <name>`; **hermes 專家
   的常駐 devenv 租約走 `devenv release scientist`** (在 paperclip 容器內跑) —— 專家退役
   時要記得, 否則那顆 DB 與 valkey 槽位會一直佔著, 而 `devenv-expert-leases` one-shot
   每次 `up` 又會把它 provision 回來 (要真的退, 連 one-shot 一起從 compose 拿掉)。
7. **`upstream/` 是 submodule** — 直接改它 = 改壞版控。改動一律放 `patches/`。升版後 (新 tag checkout) patches 可能不兼容, 升版前 review upstream changelog。
8. **專家 agent 住在 `hermes-profiles` volume, 而 `hermes` 容器不得掛 `frontdoor-hermes`。**
   兩顆 volume 分開不是整理癖: `frontdoor-hermes` 根目錄有參謀長的 `.agent.nsec`
   (600 uid 10000), 而專家跑在**同一個 uid**, hermes 的 cross-profile guard 又不涵蓋
   terminal tool (`agent/file_safety.py:427`, 上游原話「Soft guard, NOT a security boundary: the agent runs as the same OS user」)。
   整顆掛進去 = 一行 `cat` 就拿到參謀長的 Buzz 身分, 之後它發的文都掛在參謀長名下。
   dashboard 兩顆都掛是刻意的 —— 那是「一次登入看到全部 agent」的來源
   (`list_profiles()` 列舉 `$HERMES_HOME/profiles`)。
   **但 dashboard 不是「只讀不跑」——它會跑 agent, 而且那條路徑拿得到參謀長的 key。**
   `/chat` 頁面在 xterm.js PTY 裡跑一個真的 hermes
   (`upstream/hermes/hermes_cli/web_server.py:2508`), 並且支援 per-request 的
   `HERMES_HOME` override (`:17438` 一帶的 profile scoping)。那個容器同時掛
   `frontdoor-hermes`(根目錄有參謀長的 `.agent.nsec`) 與 `hermes-profiles`, 又以
   uid 10000 跑 —— 所以**人**在 dashboard 上選 `agt-scientist` 然後開 Chat, 拿到的
   shell 讀得到那把 key。buzz wrapper 的 profile guard 擋不住這條: wrapper 尊重
   已經設好的 `BUZZ_PRIVATE_KEY`, 而 shell 裡本來就能 `cat`。
   **這是已知且接受的代價, 不是漏洞回報。** 兩個限定條件是它可以被接受的原因:
   (1) 這條路徑**由人發起**, 不是 agent 自主 —— 專家 agent 自己跑在 `hermes` 容器,
   那裡**沒有** `frontdoor-hermes`(本不變量的第一句), 所以自主執行永遠碰不到;
   (2) 能開 dashboard 的人已經有 `HERMES_DASHBOARD_BASIC_AUTH_*`, 也就是已經是
   operator。**不要為此拿掉 dashboard 的 `frontdoor-hermes` 掛載** —— 那會毀掉
   「一次登入看到全部 agent(含參謀長)」這個使用者明確選擇的性質; 要換掉這個取捨
   是使用者的決定。真正被機器守住的是 `hermes` 容器那半邊, 由
   `tests/scientist.sh` 的兩條結構檢查釘住 (不掛 `frontdoor-hermes`、
   uid 10000 讀不到 `/keys/agent.nsec`)。
   **專家之間不隔離** (同容器同 uid), 這是換 8 倍記憶體的顯式取捨: 每專家一容器是
   ~118MB × N (Python heap 是 RssAnon, 行程間不共享), multiplex 是 ~148MB + ~9MB × N
   (量測見 `docs/superpowers/specs/2026-08-20-scientist-expert-profile-design.md` §4.6)。
   要對某個專家硬隔離, 用上游 `container_boot.py` 的 per-profile s6 slot, 資料不用搬。
   **專家的 devenv 租約壞掉時只降級專家, 不擋 gateway。** `hermes` 用
   `service_completed_successfully` 等 `devenv-expert-leases` 是為了排序 (乾淨
   `setup.sh` 必須先有租約檔才輪到 profile seeding), 但那條邊同時意味著 one-shot 任何
   非零 exit 都會讓整個 agent runtime 起不來 —— valkey 槽位用罄 (`devenv` exit 3)、salt
   輪替、admin 密碼錯, 全都算。所以 one-shot **一律 exit 0**, 失敗時印
   `[devenv-expert-leases] WARNING`(並把 provisioner 輸出裡的密碼遮掉再印), 讓專家退化成
   「沒有 `DATABASE_URL`/`VALKEY_URL`」而不是全棧起不來。與
   `patches/paperclip/opc-devenv-seed.sh` 同一個立場: devenv 的問題要在**用到資源時**炸,
   不是在開機時。偵測器是 `tests/scientist.sh` 的 `── devenv lease ──` 三條
   (含一條真的用租約 `psql` 連上去), 修完重跑
   `docker compose up devenv-expert-leases` 即可 —— 它是冪等的。
   **dashboard 容器的 `command` argv[0] 必須是 `dashboard`** —— upstream 用
   `/proc/1/cmdline` 判斷要不要跳過 profile reconcile, 判錯就是兩個容器搶
   `logs/gateways/<profile>/lock` 的 s6-log restart storm。

## 已知坑 (踩過)

- `buzz-admin` 讀 `RELAY_URL` env (不是 BUZZ_RELAY_URL); add-member 需 DATABASE_URL/REDIS_URL + relay key + S3 env。
- Paperclip `pi_local` adapter 不兼容 omp v17 (flag 差異); 整合 omp 用 `claude_local` + `engine:"acp"` + `agentCommand:"omp acp --yolo"` (handshake 已驗證, 見 SETUP.md)。
- **「hermes 不自己實作」這條規則住在 `SOUL.md`, 不是 skill 也不是 `config.yaml`**。三個位置都試過, 只有一個成立:
  - **skill 不行** — skill 只能影響「已經決定載入它」的 model, 而「不要自己做」必須在那個決定**之前**就成立。實測反例: 請 frontdoor prototype 一個小工具, 它把整個 app 寫進自己的 home、上傳到 Buzz media, **一張 ticket 都沒開**。
  - **`config.yaml` 的 `agent.system_prompt` 也不行** — 那個 key 由 `cli.py` 的 `class HermesCLI` 解析 (`resolve_ephemeral_system_prompt`), 只對 `hermes chat` 生效。**ACP lane 完全不讀** (`acp_adapter/session.py` 建 `AIAgent(**kwargs)` 時沒傳 `system_prompt`), 而 frontdoor 跑的正是 `hermes acp`。與 `completion_queue` 只被 cli.py / gateway 消耗是同一類的 lane 落差。
  - **`SOUL.md` 才對** — `AIAgent` 自己組 prompt 時會讀 (`agent/system_prompt.py` → `load_soul_md`, 且 scope 在 agent 自己的 `HERMES_HOME`), 所以**每個 lane 都吃得到**。兩個 image 各 bake 一份 `/opt/hermes/SOUL.md`, entrypoint 每次開機覆蓋進 home (與 skill 同一套機制)。兩份必須逐字相同, `scripts/prepare.sh` 會擋。
  lane 表繼續留在 skill (那是會變的細節), 「你不是實作者」是常駐約束。
- **hermes multiplex 的 provider key 隔離是 per-variable-name, 不是 per-profile
  (實測), 但背後機制未證實**: 量到的三件事都是真的 —— 只存在於某 profile 自己
  `.env` 的變數, 在該 profile 的 `config.yaml` `${VAR}` 引用裡解析正常; default 與
  `agt-scientist` 用**同名變數**(`OPENAI_API_KEY`)但**不同值**時, 重啟後**先接到請求
  的那個 profile 決定了兩條路由都拿到的值**(另一邊直接 401); 換成**不同的變數名**則
  兩邊乾淨。但「`${VAR}` 是對著該 profile 自己的 `.env` 解析」這個因果**沒有證實**
  —— 讀 source 反而指向相反方向: `config.py::_env_expand_match` (~2591-2637) 只從
  `os.environ` 解析 `${VAR}`, 解不到就留字面不動; `gateway/run.py:1963-1975` 在
  multiplex 下明確拒絕把 profile 的 `.env` load 進 `os.environ`;
  `_profile_runtime_scope` (`gateway/run.py:2067-2100`) 建的是完全不動
  `os.environ` 的隔離 dict。沒找到能讓「per-profile `.env` 解析」這個說法成立的路徑
  —— 真正在解析的可能是某個共用的 credential pool, 或另一個 global, 目前不知道是
  哪個。**操作規則不受這個因果影響, 照樣成立**: 別讓兩個 profile 的 `config.yaml`
  用同一個變數名裝不同值; 專家要自己的 provider key 就換一個變數名; 這裡的憑證行為
  要靠量測驗證, 不要只靠讀 source 判斷。另外 profile 的 `config.yaml` **不可省略
  `model.api_key`**(這件事是獨立且已證實的): 省掉會 401, 因為
  `runtime_provider.py:1325-1335` 把 `OPENAI_API_KEY` 這個候選 host-gate 到
  openai.com, 而我們的 base_url 是 opencode.ai, 最後落到 `"no-key-required"`
  (與 `1881e40` 修的同一件事, 每個 profile 各要一份)。
- **`config.yaml` 不是放「必須成立的規則」的地方**: seed 是「不存在才寫」, 而且 **hermes 會自己遷移它** — frontdoor 的 volume 被遷到 `_config_version 37` 的過程中 **`system_prompt` 整個不見了**, 於是它有很長一段時間在**沒有 system prompt** 的狀態下跑, 而沒有任何地方會顯示這件事。config.yaml 現在只放對話語氣與 Buzz 發文機制, 且每次開機 reconcile。
- **派工路由住在 `paperclip-api` skill, 不在 system_prompt**: hermes 是決定 assignee 的那一層 (Paperclip 在本 stack 沒有自動路由 — 無 CEO、org 全扁平、`role=general`, 未指派的 ticket 沒人會醒)。lane 表 (`engineering`→`OMP Engineer` / `prototype`→`Prototyper`) 放 skill 的理由: skill 由 image 在每次開機同步進 **兩個** hermes home (frontdoor 與 gateway), 而 `config.yaml` 的 system_prompt 是 per-home 且 dashboard 可編輯 — 規則放 prompt 會分歧。**改 skill 要同時改 `patches/buzz/skills/` 與 `patches/hermes/skills/` 兩份** (內容必須相同)。channel 層的 `platforms.<name>.channel_overrides[channel_id]` 可覆寫 system_prompt/model, 但那是 per-platform × per-channel-id, 只適合當加速器, 不要拿來當路由機制。
- **preview 的對外位址由 `PAPERCLIP_PUBLIC_URL` 決定, 不要另外設一份**: `DEVENV_HTTP_PUBLIC_HOST` 留空時從它的 host 推導 (`providers/http.sh`)。理由是 preview 連結**長在 board 上**, 兩者必然從同一個地方被存取 —— 寫成兩個變數只會製造「board 開得起來、連結打不開」這種只有症狀沒有訊息的分歧。發佈位址 `DEVENV_HTTP_BIND` 預設 `0.0.0.0`(與 paperclip/buzz/hermes 一致); 要收窄就設 `127.0.0.1` 或 tailnet IP。**改了要 recreate paperclip 容器**(docker 的 port 發佈在建立容器時固定)。
- **prototype 目錄的擁有者必須是 runtime user (`node`)**: paperclip server 與它 spawn 的 dev server 都是 node, 但人用 `docker compose exec` 是 root。root 建出來的樹會讓 `expose --start` 回 **500**, 而真正的原因 (`EACCES: mkdir .next/dev`) 只出現在 paperclip 的 log 裡, 看起來完全不像權限問題。`prototype` CLI 在以 root 執行時會自動 chown; 同一類問題也影響 git (`dubious ownership` → `|| true` 包住的 commit 靜靜失敗)。
- **project-only skill = 放進專案目錄, 不是 Paperclip 的 scope**: Paperclip 的 `sharingScope` 只有 `private|company|public_link`, **沒有 project 這個層級**。omp 從工作目錄探索 skill (binary 裡有 `.claude/skills` / `.agents/skills` / `.omp/skills` 三種), 所以 `prototype skill add <name> --from <repo>` 把它 vendor 進 `<project>/.claude/skills/` 並 pin SHA —— 只有這個 prototype 的 session 看得到。用 `.claude/skills` 是因為 Claude Code 也讀它, 換 engine 不會壞。
- **preview server 是 paperclip 的子行程, 容器一重建就全死**, 而 paperclip **沒有** desiredState 的開機 reconciler (server 的 5 個週期性 timer 沒有一個碰 workspace)。症狀最惡劣的地方在於**完全無聲**: board 上一切正常, 只有 URL 是死的。`opc-prototype-restore.sh` 由 entrypoint 背景啟動 (背景是必要的 —— 它要等的 API 正是即將 exec 的那個行程), 等 health 後跑 `prototype restore`。存活判斷是**在容器內 probe `127.0.0.1:<port>`** 而不是信 DB: 重建後 row 還寫著 running 但行程早就不在。
- **preview 不在 localhost, dev server 要明確放行**: `.env` 給 `DEV_HOST`。Next.js 16 對**任何**帶 `Origin` header 且 host 非 localhost 的請求回 **403** —— 連 same-origin 也擋, 所以是日常使用就會中, 不是只有 CORS。症狀是頁面載入後每個 JS chunk 403、畫面看起來壞掉。解法 `allowedDevOrigins: [process.env.DEV_HOST]`; Vite 對應 `server.allowedHosts`。**用 curl 驗不出來**(curl 不送 `Origin`), 一定要用瀏覽器開一次。
- **prototype/preview 的三個坑**: (1) `expose.urlTemplate` 的變數語法是 `{{port}}` 不是 `${port}` (upstream `doc/plans/` 的範例過期); (2) **dev server 一定要綁 `0.0.0.0`** — 綁 loopback 時 paperclip 的 readiness 從容器內打 `127.0.0.1` 會過, 但 host 連不上, 於是 board 顯示綠色 live 卻打不開 (devenv 因此把 `HOST=0.0.0.0` 寫進 `.env`); (3) preview port pool 的 base 必須 **低於 32768** (kernel ephemeral range), 否則 `bind(0)` 可能搶走已租但當下沒 listen 的 port。`DEVENV_HTTP_PORT_RANGE_END` 與 `BASE+COUNT-1` 是兩個必須一致的來源 (compose 不會算術), 開機檢查會 warn。
- **`PAPERCLIP_WORKSPACE_ID` 是 project workspace id, 不是 execution workspace id** (`heartbeat.ts` 塞 `executionWorkspace.workspaceId`, 而 `workspace-runtime.ts` 用它當 `projectWorkspaceId`)。要 execution workspace 得走 `GET /issues/<id>/heartbeat-context` → `.currentExecutionWorkspace.id`。
- **paperclip 不會建 `local_path` workspace 的 cwd** (`mkdir` 只出現在 worktree 路徑), 而 **`setupCommand` 從來不會被執行** (upstream 只有 CRUD 讀寫它)。目錄與 `git init` 由 `prototype create` 在容器內做。
- **指派會叫醒 agent, 不需要排程 heartbeat** (`issue-assignment-wakeup.ts`), 唯一的前置條件是 `issue.status !== "backlog"`。另外 `heartbeatEnabled` **不是欄位** — 相關的只有 agent 的 `status` (`idle` vs `paused`)。回完沒給 disposition 的 issue 會**反覆喚醒** agent。
- **hermes_gateway 的 600 秒預設對研究 lane 太短, 而它被砍的樣子不像 timeout**: `DEFAULT_TIMEOUT_SEC` 是 600 (`gateway/shared/constants.ts`), 這是**牆鐘**上限不是 idle timeout。第一張真正派給科學家的票 (OPC-11) 在 601.7 秒被砍在 `tool.started` 中間, run 記錄的 `errorMessage` 是 **null**, log 裡唯一的痕跡是一行 `[hermes-gateway] stop requested for run …`。它靠 `sessionKeyStrategy: "agent"` 在下一次喚醒接回去做完, 所以**成品看起來完全正常** —— 只有 board 上多一筆 `timed_out`。Scientist 因此固定 `timeoutSec` 1800 (`opc-paperclip-bootstrap.sh` 的 `SCIENTIST_TIMEOUT_SEC`, compose 以 `HERMES_SCIENTIST_TIMEOUT_SEC` 轉發), 由 `tests/scientist.sh` 的 `run timeout is raised` 守著。paperclip **沒有**自己的 run 時長 watchdog, 所以這是唯一的旋鈕; `getAgent` 每次 run 直讀 DB, 改完不必重啟 paperclip。
- **hermes lane 在 board 上不會顯示 working activity, 這是 upstream UI parser 的缺口, 不是我們配置錯**: hermes 的 SSE 事件流是好的 (`GET /v1/runs/<id>/events` 200, 一次 run 94KB, 含 `tool.started`/`tool.completed` 帶 `tool` 與 `preview`), 且完整落在 run log 裡。斷點在 `packages/adapters/hermes/src/gateway/ui/parse-stdout.ts:50` —— 只有 `message.delta`/`run.failed`/`reasoning.available` 有對應, 其餘一律 fallthrough 成 `kind:"system"`, 而 UI 只從 `kind:"tool_call"` 建 tool 卡片 (`ui/src/components/task-chat/transcript-adapter.ts:231`; 對照 `adapters/claude-local/src/ui/parse-stdout.ts:76`)。**不要以為差別在 `ctx.onEvent`** —— 量過了, omp 的 run 也只有 `lifecycle`/`run.startup.step`/`adapter.invoke`, 一樣沒有 tool event, 所以往 `onEvent` 補只會拿到 pill 上一行 `Using <tool>`, 拿不到 activity 時間軸。修它要動 `upstream/` (違反不變量 7) 且 parser 已編進 UI bundle (`/app/ui/dist/assets/index-*.js` 內含 `Hermes event: ${a}`), 所以要重 build UI。目前**刻意不修**, 待決定是否往上游提。同一個缺口 `openclaw-gateway` 也有。
- **`opc-paperclip-bootstrap.sh` 的 skill/agent 安裝必須 reconcile 而非 create-only**: 改 `patches/` 裡的 skill 或 `desiredSkills` 之後, 若安裝器只在缺席時建立, 變更永遠到不了跑著的 stack — 檔案說一套、agent 讀另一套, 而且沒有任何地方會顯示這個落差。目前 SKILL.md 內容與 Prototyper 的**整份 `adapterConfig`** (engine / agentCommand / `paperclipSkillSync.desiredSkills` / `env.DEVENV_OWNER`) 都會逐次比對更新 —— 比對是**合併而非覆寫**, 沒被列名的 key (paperclip 自己寫的 `instructions*`、operator 在 board 上加的東西) 原樣保留。Prototyper 其餘欄位刻意不主張, 因為它們就是 paperclip 的建立預設: `heartbeat {enabled:false, maxConcurrentRuns:20}`、`modelProfiles.cheap {enabled:false}`、`permissions {canCreateAgents:false, canCreateSkills:true}`、managed AGENTS.md instructions bundle、company membership 與 `tasks:assign` grant (後兩者在 create 當下鑄出)。**skill 內容要走 `PATCH /companies/<c>/skills/<id>/files` 帶 `path:SKILL.md`, 不能走 skill 本身的 PATCH** —— `updateSkill` 收下 `markdown` 然後靜靜丟掉 (它只寫 name/description/categories/sharing), 回你 **200** 而 board 上還是舊字; `updateFile` 才會真的寫檔 + 寫 markdown 欄 + 依 frontmatter 重算 name/description + 切一版。devenv 與 prototype-workspace 就這樣在 board 上停在舊版好幾個 commit, 而 bootstrap 每次都印「skill updated」—— 因為 `api_patch_raw` 結尾是 `|| true`, `&&` 永遠成立。現在改成驗回應裡有 `.path` 才算成功。
- **Paperclip 的 GitHub skill import 只抓 `SKILL.md`** — 會 pin commit SHA 也會做 trust level 檢查, 但 sibling 檔案 (mattpocock prototype 的 `LOGIC.md`/`UI.md`) 不會跟著進來, 匯進去的 skill 兩條分支都是斷的。所以第三方 skill 一律 **vendor 到 `patches/paperclip/skills/<slug>/`** (附 `SOURCE` 記 repo+SHA), 由 `opc-paperclip-bootstrap.sh` 建成 local skill; 更新跑 `scripts/refresh-vendored-skills.sh`。注意 `GET /skills/:id/files` 的 inventory 會落後 (新增檔案後仍只列 SKILL.md), 以磁碟 `/paperclip/instances/default/skills/<companyId>/<slug>/` 與 run 時物化的 bundle 為準。
- **profile `config.yaml` 的 reconcile 是「逐行精確比對」, 所以 dashboard 寫回的一個尾註就會多出一整塊**: `hermes-entrypoint.sh` 收斂 `platforms.api_server.enabled: false` 的方式是找那一行 `platforms:`(以及其下的 `api_server:`)。dashboard 可編輯這個檔, 而 YAML dumper / 人手都可能把它寫成 `platforms:  # managed` —— 精確比對就對不上, reconcile 於是**在檔尾再 append 一整個 `platforms:` block**。YAML 後者覆蓋前者, 所以「看起來」還在, 但症狀出現在別的地方: 那個 profile **啟動 0 個 secondary adapter**(`gateway/run.py` 的 secondary-profile loader 在 per-profile adapter 迴圈**之前**就丟 `SecondaryPortBindingConfigError`), 而 warning 只提 api_server, 完全不提「你有兩個 platforms key」。檢查方式: `grep -c '^platforms:' /opt/data/profiles/<p>/config.yaml` 必須是 1。真正的修法是讓 reconcile 認得註解/空白變體, 目前只有這條紀錄。
- **`devenv` CLI 不會建 control schema, 建它的是 `opc-devenv-seed.sh`**: 兩個呼叫者 —— paperclip entrypoint, 以及 `devenv-expert-leases` one-shot(自己套 schema, 見它上方的註解)。這條之所以值得寫下來, 是因為 schema 不在時的**原始訊息會指錯方向**: `devenv_valkey_db_alloc` 的 registry 讀取回空字串, CLI 就喊 `no free valkey database id (cap N) — run 'devenv list' and release one`, 讀起來像槽位用罄, 於是人去 release 無辜的租約。現在 `provision`/`list` 開頭都先跑 `devenv_require_control_schema`, 缺 schema 就以 exit 4 明講。

- **devenv 回收是手動的** (`devenv release <key>`), 沒有任何自動 gc/排程。累積靠 `devenv_usage` view 看 (按 postgres 磁碟大小遞減 — valkey 槽位用罄會自己以 exit 3 喊, 磁碟不會)。valkey 租戶隔離靠 9.1+ 的 `db=<dbid>` ACL op, **9.0.x 沒有這個功能**, 升降版本前先確認。per-tenant 密碼是從 `DEVENV_SECRET_SALT` 推導而非儲存 (這是 provision 冪等的原因), **改 salt 會讓所有已發出的 `.env` 失效**。agent 身分優先序 `DEVENV_OWNER` → `agent:$PAPERCLIP_AGENT_ID` → `user@hostname`; **`env.DEVENV_OWNER` 目前不可能到達 agent 行程** — 不是設錯而是無路可走: API 的 `secrets.ts canonicalizeBinding` 會把裸字串一律改寫成 `{"type":"plain",value}` 存檔, 而每個 local adapter 組 child env 時都是 `if (typeof value !== "string") continue` (`adapters/process/execute.ts`、`adapter-claude-local/server/execute.ts`), 兩邊對不上。bootstrap 仍寫這個 key (它是意圖, 也在 board 上看得見), 但實際落到 `agent:$PAPERCLIP_AGENT_ID` —— `PAPERCLIP_AGENT_ID` 才是每次 run 一定有的。
- **devenv-pg 是 pg18, volume 要掛 `/var/lib/postgresql` 而非其下的 `data`** — 沿用 pg17 的掛法 image 會拒絕啟動。
- **Claude cred 只鏡像 `.credentials.json` 一個檔** (`host-sync-claude` one-shot → `opc-prototyper-home` volume, 掛 paperclip `/agent-homes/prototyper`)。**這個 home 目前沒有被接上任何東西** — 原設計是拿 prototyper 的 `adapterConfig.env.HOME` 指過去, 但 `env.*` 送不到子行程 (見 devenv 那條), 而 agent 子行程實際繼承的是 paperclip server 的 `HOME=/paperclip`。正常路徑 (omp + `OPENAI_API_KEY`) 不受影響; 只有真的要改用 `claude` CLI 時才需要處理, 而那要動 compose 層的 HOME, 是全體 agent 共用的決定, 不是 per-agent 設定。host 的 `settings.json`(含 hook)、`plugins/`、`skills/`、`projects/`、`history.jsonl` 一律不進容器 — 容器內的 claude 是乾淨的。**OAuth refresh token 是單次使用**: 容器端刷新會讓 host 那份失效 (反之亦然), 壞了跑 `scripts/sync-claude-creds.sh` 重同步。`.env` 的 `ANTHROPIC_API_KEY` 若有值會蓋掉 OAuth (改用 API 計費), 想吃訂閱就留空。
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
- **`/keys` 的檔案是 `600 root`, 而 agent 與它的子行程是 uid 10000 —— 讀不到**。entrypoint 因此把兩把鑰匙鏡像進 `$HERMES_HOME`(`.agent.nsec` / `.paperclip-api.key`, 改 owner 為 runtime uid)。任何以 agent 身分跑的東西**都要讀鏡像那份**。症狀不會是「權限不足」: 讀到空字串之後, buzz 變成「no buzz identity」靜靜不送、paperclip 變成無限「GET failed (paperclip down?)」—— **watcher 會怪伺服器,而不是怪自己少了憑證**。而且這個 bug 躲在重啟後面: 由開機 sweep 啟動的 watcher 繼承 entrypoint 的 env 所以正常, 只有**由 agent 啟動**的那些會壞(tool 子行程被刻意剝掉 `BUZZ_PRIVATE_KEY`, GHSA-rhgp-j443)。
- **投遞失敗不可以標記成已投遞**: watcher 原本無論成敗都 `touch <id>.posted`, 於是 sweep(唯一的重送機制)永遠跳過它。一則通知就這樣永久消失。
- **`docker exec` 互動 session 不繼承 entrypoint runtime export 的 env** (GH_CONFIG_DIR / GIT_SSH_COMMAND / GIT_CONFIG_GLOBAL): 需手動 `. /usr/local/bin/opc-gh-seed.sh` 補上。mise shims (`/opt/mise/shims`) 已 bake 進 image ENV PATH 尾, 所以 exec 也吃得到 omp/rustc/cargo (volume seed 後)。

## 檔案地圖

- `docker-compose.yml` / `.env.example` / `SETUP.md` — 部署核心
- `patches/<proj>/` — 改寫的 Dockerfiles + entrypoints (唯一客製來源; 內容 = 各 repo 的 opc/ 目錄)
- `patches/nix-seed/` — nix seed build context (nix 2.35.2 + 12 工具, `cp -al` 成 `/nix-seed`); compose `nix-seed` 是 one-shot, 消費者 = 各 service Dockerfile 的 `COPY --from=nix-seed`
- `patches/{buzz,hermes}/SOUL.md` — agent 身分 + 「不自己實作」規則 (兩份必須相同; 唯一對所有 lane 都生效的位置)
- `patches/<proj>/opc-mise-seed.sh` — 每 project 一份, entrypoint source 的 mise bootstrap (空 volume 自動裝 node/rust/omp)
- `patches/hermes/opc-env-value.sh` — 唯一的 `.env` 讀取器。entrypoint `source` 它拿 `opc_env_value` 函式, `tests/scientist.sh` 在容器裡把**同一個檔**當 CLI 執行 (`opc-env-value.sh <file> <name>`)。寫的人與驗的人用同一份 parser, 否則 gate 會對著跟 gateway 不同的值變綠
- `patches/tencentdb-agent-memory/MemoryCore/` — tencentdb-core 的 opc Dockerfile (schema overlay: team/create + agent/create 接受顯式 id) + `opc-tencentdb-provision.sh` (meta-plane bootstrap)
- `patches/paperclip/skills/<slug>/` — vendor 的第三方 skill (SKILL.md + sibling 檔 + `SOURCE` 記 repo/SHA); image 內落在 `/opt/opc-skills/`, bootstrap 裝進 company library
- `patches/paperclip/templates/_layers/<name>/apply.sh` — 選配的 layer (`prototype layer add`)。**layer 之間必須獨立** — 需要知道另一個 layer 存在的 layer 是設計失敗, 它會讓測試從線性變成組合爆炸。用 script 而非複製檔案, 是因為 tailwind/shadcn 有自己的 installer, 複製快照等於凍結我們控制不了的版本
- `patches/paperclip/templates/<name>/` — `prototype create --template` 的 scaffold。**是程式碼不是文件**: env 覆蓋順序、`NODE_ENV`、`allowedDevOrigins`、valkey ready check 每一條都是一次除錯換來的, 讓 agent 照文件重打必然出錯 (已發生過)。改了跑 `tests/prototype-template.sh`
- `patches/paperclip/prototype/` — `prototype` CLI (paperclip-aware 的工作流層: project + git + 租約)。**刻意不放進 devenv** — devenv 是通用資源租約, 不該認識 paperclip; 它只多一個 `mark-exposed` 供 `devenv list` 標記
- `patches/paperclip/skills/{devenv,prototype-workspace}/` — first-party skill (租約用法 / prototype 工作流 + 覆寫 vendored `prototype` skill 的第 1、3、6 條規則)
- `patches/paperclip/devenv/` — `devenv` CLI + `providers/{postgres,valkey}.sh` + `bootstrap.sql`;
  image 內落在 `/usr/local/lib/devenv/`, symlink 到 `/usr/local/bin/devenv`。schema 由 `opc-devenv-seed.sh` 每次開機套用 (冪等, 後端不通只警告不擋 `up`)
- `scripts/prepare.sh` — 除了同步 patches, 還有**防漂移檢查**: 兩份 `paperclip-api` SKILL.md 與兩份 `SOUL.md` 必須逐字相同, 不同就中止 build (這條規則在本 repo 已經默默壞過三次)
- `scripts/` — 操作用的一次性工具: setup / prepare / upgrade / load-env (`.env` 讀取器, 被 `scripts/setup.sh`、`scripts/upgrade.sh` 與 `tests/*.sh` 共用); `host-sync.sh` (通用 host→volume 鏡像 CLI) + `host-sync-worker.sh` (容器側 engine, 唯一邏輯) + `hooks/` (per-source 轉換, ssh/gitconfig/claude-cred) + `sync-gh-creds.sh` / `sync-claude-creds.sh` (場景薄 wrapper); compose `host-sync` (gh) 與 `host-sync-claude` (Claude cred) 兩個 one-shot 每次 up 自動跑
- `tests/` — 測試與驗證腳本的慣例落腳處, 與 `scripts/` 分工: `scripts/` 是操作工具, `tests/` 是測試與驗證。移進來的檔案把冗餘的 `test-` 前綴拿掉 (目錄名已經說明性質了) —— 例外是 `tests/audit-bootstrap.sh` (本來就沒有前綴) 與 `tests/acp-smoke-test.mjs` (`-test` 是複合名稱的一部分而非前綴, 且它在 paperclip 容器內跑, 名稱與位置無關)。`tests/set-buzz-agent-owner.sh` 測的是 `scripts/set-buzz-agent-owner.sh` — 同名分屬 `scripts/`/`tests/` 兩個目錄是刻意的配對, 不是巧合, 其餘整合測試同理。三個 gate: `tests/audit-bootstrap.sh` (靜態: 每份狀態是否都有無人值守的產生者)、`tests/connectivity.sh` (live: 既有功能沒被弄壞)、`tests/scientist.sh` (live: 專家 lane 端到端); 外加偶爾才跑的 `tests/fresh-install.sh` (乾淨機器完整排練, 見「部署假設」一節)。這是慣例, 不是強制關卡 —— `scripts/prepare.sh` 不對它 gate。
- `upstream/<proj>/opc/` — prepare.sh 產物, 勿手改
- `tests/acp-smoke-test.mjs` — omp ACP handshake 驗證 script (在 paperclip 容器內跑)
- `patches/hermes/profiles/<name>/SOUL.md` — 專家 agent 的身分。**不是** `patches/hermes/SOUL.md` 的副本: 那份帶著「你不是實作者」, 而專家的工作就是自己動手, 套上去會切斷探索迴圈
- `tests/scientist.sh` — 專家 lane 的端到端 gate (volume → gateway → 身分 → 記憶 → board)
