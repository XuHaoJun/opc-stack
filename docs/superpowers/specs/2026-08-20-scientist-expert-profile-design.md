# Scientist — 探索型專家 agent

> **狀態: 設計定案, 未實作。** 2026-08-20 完成 brainstorm。原本阻塞它的
> 「agent 自主 nix 安裝」已於 `d29951e` 交付; 原先未決的容器形狀與溝通管道也已在
> 同日以實測定案 (§5)。下一步是 implementation plan。

## 1. 目標

在 Paperclip 加入一個「科學家」角色: 做探索性任務、持續累積記憶、把驗證過的
方法固化成自己的 skill。未來會有第三、第四個同類專家 (例: 市場研究), 而且
**可能會非常多** —— 這條在 §6.1 直接決定了架構。

硬需求 (使用者明確強調):

- **必須與既有的 frontdoor hermes (參謀長 / chief of staff) 隔離。**
- 科學家要能**自主使用任意程式工具** (按需 nix 安裝), 在自己的沙盒裡做出初步
  實驗證據, 而不是每缺一個工具就委派出去。
- 所有專家要能在**同一個 hermes dashboard、同一次登入**下被觀察。

## 2. 已定的決策

| 議題 | 決定 |
|---|---|
| 「自我進化」的範圍 | **memory 累積 + agent 自己寫 skill**。`SOUL.md` 由人維護, 不給 agent 改。 |
| 記憶層 | **雙層**: profile 私有實驗簿 (含失敗路徑) + TencentDB 公開知識。升格是顯式動作。 |
| 觸發模式 | **被派工 + 自主實驗隊列**。產出要被別人接手就必須 materialize 成 Paperclip issue。 |
| 實驗形態 | **自己做實驗直到有證據**, 交付才委派 (見 §3)。 |
| 隔離邊界 | **multiplex: 一個 gateway 行程服務所有專家 profile** (§6.1)。 |
| 溝通管道 | **push-out via Buzz (自己的 nsec) / pull-in via Paperclip 指派** (§6.2)。 |

## 3. 工作流程

委派的邊界畫在**生命週期**上, 不是**能力**上:

```
科學家 (自己的沙盒, 完全自主)
  │  按需裝任何工具 · 寫 code · 跑 · 丟掉
  │  實驗簿 memories/ 累積 (含失敗路徑)
  ▼
「有初步證據了」
  ├─→ Buzz / chat ──→ 人 + 參謀長 討論        ← 對話層 (Buzz owns)
  └─→ Paperclip issue @ status=backlog        ← 提案, 惰性
         │  人 / 參謀長 決定並指派             ← durable work 在此誕生
         ├─ 不做      → 關掉, 知識留在實驗簿
         ├─ prototype → Prototyper
         └─ 正式專案  → OMP Engineer
```

三個理由 (為什麼不是「缺工具就委派」):

1. **能力邊界會切斷探索迴圈** — 蒐證是迭代的, 每次委派都是一次有損交接。
2. **丟棄式實驗程式碼不是 durable work** — 為跑完就刪的 script 開 issue 是在污染
   work plane。PRD 的規則是「durable work 的 writer 只能是 Paperclip」, 不是
   「hermes 不准跑程式」。
3. **「hermes 不自己實作」不適用於它** — 那條住在 `SOUL.md`, 而 SOUL.md 是
   **per-home** 的, 約束的是 frontdoor 那個 triage 角色。科學家有自己的 SOUL.md。

**gate 機制已經存在, 不用新建**: `issue-assignment-wakeup.ts` 只在
`status != "backlog"` 時叫醒 agent。所以科學家自己開的 backlog issue 是惰性提案,
不會叫醒任何人 — 自主性給足, 單一 writer 規則不破。

## 4. 已驗證的技術事實

全部實測或讀 code 確認過 (pin 的 tag: hermes `v2026.8.16` /
paperclip `canary/v2026.722.1-canary.0`)。

### 4.1 Hermes profile 的隔離性

- Profile = 完整獨立的 `HERMES_HOME`, 位於 `<root>/profiles/<name>/`, 各自擁有
  `config.yaml` / `.env` / `SOUL.md` / `memories/` / `sessions/` / `skills/` /
  `plugins/` / `cron/` / `logs/` / `plans/` / `workspace/` / `state.db` / gateway
  (`hermes_cli/profiles.py:1-20`)。
- **profiles 的根錨在 `HERMES_HOME`, 不是 `~/.hermes`** (`profiles.py:271-282`,
  Docker 部署的明文特例)。這條是 §6.1 整個佈局的支點: 「dashboard 看不看得到某個
  專家」完全由「那個 profile 目錄在不在 dashboard 掛的 volume 上」決定, 與**誰的
  行程在跑它無關**。
- 選 profile: `hermes -p <name> <任何子命令>`。`-p` 在 argparse **之前**被
  pre-parse 並直接設 `HERMES_HOME` (`hermes_cli/main.py:518`,
  `_apply_profile_override`), 所以 `hermes -p X acp` 也吃得到。
- **不是 security boundary**: cross-profile 寫入只有 soft guard, 範圍限
  `skills/plugins/cron/memories` (`agent/file_safety.py:443`), 模型可帶
  `cross_profile=True` 繞過, terminal tool 完全不經過。上游原話: *"Treat the guard
  as a confusion-reducer, not a security boundary."* 它是因為 **2026-05 的真實事故**
  才加的 — 一個 `hermes-security` profile 的 session 同時改了自己與 default 的 skills。
  **這條是 §6.1「專家之間不隔離」那個取捨的來源。**
- **credential 有共用 fallback**: profile 自己的 auth 優先, 沒設就 fallback 到
  root 層的 global auth store (`hermes_cli/auth.py:1100`, read-only)。
- **`HERMES_HOME` fallback 陷阱** (上游 issue #18594): `HERMES_HOME` 未設但
  `active_profile` 指向別的 profile 時, 資料**靜靜寫進 default**, 只有一行 stderr
  (`hermes_constants.py:75`)。註解明講 spawner 必須顯式傳 `HERMES_HOME`。

### 4.2 Gateway multiplex — 已 smoke test

- 開關: `GATEWAY_MULTIPLEX_PROFILES=1` (env 優先於 config.yaml; 空字串視為未設,
  不會蓋掉 config 的 opt-in — `gateway/config.py:93-117`, 預設 `False` at `:972`)。
  另有 `gateway.multiplex_profile_allowlist` 可限定服務哪些 profile
  (`config.py:40-79`; `None` = 全服務, 格式壞掉時 fail-safe 成「只服務 default」)。
- **每個路由都有 `/p/<profile>/` 鏡像**: `api_server.py:7440-7441` 對 route table
  裡每一條同時註冊裸路徑與 `/p/{profile}` 版本。`/v1/runs`、`/v1/runs/{id}/events`
  等都在表裡 (`:2094-2098`), 不是只有 chat/completions。
- **per-profile `API_SERVER_KEY`, fail-closed** (`api_server.py:1759-1777`)。
- secret scope 在 multiplex 下是 authoritative — 缺 key 不 fallback 去讀
  `os.environ` (那裡可能有別的 profile 的值), `agent/secret_scope.py:137-152`。
  每個 profile 的 secrets 來自它自己的 `<home>/.env` overlay。
- ⚠️ **provider key 的隔離是 per-variable-name, 不是 per-profile, 而且機制未證實**
  (2026-08-20 實測, Task 2 fix round)。量到的是三件事:
  - profile `config.yaml` 裡的 `${VAR}` **確實**讀得到只存在於該 profile 自己
    `.env` 的變數 (`profiles/agt-scientist/.env` 裡的變數可以正常解析)。
  - 但兩個 profile 用**同一個變數名、不同的值**時, **重啟後先接到請求的那個 profile 會
    污染另一條路由** (實測: 另一邊直接 401)。
  - 換成**不同的變數名**則兩邊乾淨。
  這三件量到的事**不足以證明**「`${VAR}` 是對著該 profile 自己的 `.env` 解析」這個
  因果 —— 讀 source 反而指向相反方向: `config.py::_env_expand_match` (~2591-2637)
  只從 `os.environ` 解析 `${VAR}`, 解不到就留字面不動; `gateway/run.py:1963-1975`
  在 multiplex 下明確拒絕把 profile 的 `.env` load 進 `os.environ`;
  `_profile_runtime_scope` (`gateway/run.py:2067-2100`) 建的是完全不動
  `os.environ` 的隔離 dict。沒找到能讓「per-profile `.env` 解析」這個說法成立的路徑
  —— 真正在解析的可能是某個共用的 credential pool, 或另一個 global, 目前不知道是
  哪個。**操作規則不受這個因果影響**: 「每個專家一把自己的 provider key」目前
  **做不到** —— 全棧共用一把 `OPENAI_API_KEY` 是現況也是前提。真要分開, 得給每個
  profile **不同的變數名**; 這裡的憑證行為要靠量測驗證, 不要只靠讀 source 判斷。
- **profile 的 `config.yaml` 不能省略 `model.api_key`**(這件事獨立, 已證實): 拿掉之後
  profile 直接 401。原因是 `runtime_provider.py:1325-1335` 把 `OPENAI_API_KEY` 這個
  候選來源 **host-gate 到 openai.com**, 而我們的 base_url 是 opencode.ai, 於是一路
  落到 `"no-key-required"`。這與 commit `1881e40` 對 default profile 修的是同一件事,
  每個 profile 都要各自寫一份。
- cron 在 multiplex 下是 **per-profile ticking** (`cron/scheduler_provider.py:436`)。
- **terminal 子行程拿得到正確的 per-profile `HERMES_HOME`**: contextvar override 由
  `tools/environments/local.py:497` `_inject_context_hermes_home()` 橋接進 child env。
  這是「共用行程也能有 per-profile Buzz 身分」的根據 —— wrapper 讀
  `$HERMES_HOME/.agent.nsec` 會拿到對的那把。
- ⚠️ 上游 `docs/design/multiplexing-gateway.md` 被 code 引用但**不存在**於我們 pin
  的 tag。所以 2026-08-20 實跑了 smoke test (`GATEWAY_MULTIPLEX_PROFILES=1` +
  5 個假 profile, `docker compose run` 起一個 probe 容器):

  ```
  bare  /v1/health   -> 200
  /p/p1/v1/health    -> 200
  /p/nope/v1/health  -> 404
  ```

  **功能可用。** 實驗後容器與假 profile 全部清除, `scripts/test-connectivity.sh`
  23 pass / 0 fail。

### 4.3 Paperclip 端的接法

- `hermes_gateway` 與 `hermes_local` 都是 **built-in**
  (`server/src/adapters/builtin-adapter-types.ts:12-13`), 不需安裝任何東西。
- `hermes_gateway` 必填 `apiBaseUrl` + `apiKey`; 選填 `sessionKeyStrategy`
  (`issue`|`agent`|`run`|`none`, 預設 `issue`)、`paperclipApiUrl`、`timeoutSec`。
- `normalizeBaseUrl` **保留路徑** (只砍尾斜線; 只有 dashboard port 9119 的特例會
  改寫成 `/api`) — `gateway/server/execute.ts:121-140`, 而 `apiUrl()` 是字串串接
  (`:142-145`)。所以 `apiBaseUrl: http://hermes:8642/p/agt-scientist` **可行**。
- **`sessionKeyStrategy: "agent"`** → `paperclip:company:<c>:agent:<a>`
  (`execute.ts:159-161`), 純由 companyId+agentId 決定, 跨 issue/run 穩定 =
  一條連續 session。upstream 註解: 「除非刻意要 shared agent memory, 否則別動預設」
  — 對科學家而言那正是需求。
- `hermes_local` **不適用**: paperclip 容器裡沒有 hermes (`hermes: not found`), 且
  該 adapter 不認識 profile / `HERMES_HOME` (grep 零命中)。

### 4.4 `NousResearch/hermes-paperclip-adapter` — 不要用

調查結論: 它是我們 pin 的 Paperclip 內建 adapter 的**祖先**, 已被取代。

| | Nous repo | 我們 pin 的 built-in |
|---|---|---|
| 最後 commit | 2026-04-03 | npm 2026.817.0 |
| 測試 | 0 | 8 檔 ~1.5k 行 |
| `createServerAdapter()` | 無 → **裝不進 plugin loader** (`plugin-loader.ts:145-160` 要求) | 有 |
| `onSpawn` 轉發 | 無 → Paperclip **無法從 board 停掉 run**, 收不了孤兒行程 | 有 |
| 預設 model | 硬寫 `anthropic/claude-sonnet-4` → 推導成 `--provider anthropic` | `"auto"` |

最後一項在我們的 OpenCode Zen / `OPENAI_API_KEY` 棧上會**靜靜把流量導去 Anthropic
並忽略 `OPENAI_BASE_URL`**。且它註冊的 key 就叫 `hermes_local` — 裝下去會覆蓋掉
維護中的 built-in。它同樣**沒有 profile 支援**, 解決不了隔離需求。

### 4.5 容器現況 (2026-08-20 實測)

- 參謀長跑在 **`frontdoor`** 容器 (volume `frontdoor-hermes`); `hermes` gateway 是
  **另一個容器** (volume `hermes-data`)。兩者已經是容器級隔離。
- `hermes` 容器已有 `API_SERVER_ENABLED=true` + `API_SERVER_KEY` on 8642,
  `command: ["gateway", "run"]`, `HERMES_HOME=/opt/data`, agent 跑在 uid 10000。
- **`hermes:8642` 目前零消費者** — 全 repo grep 只有 compose、healthcheck 與
  SETUP.md 的「可選」說明。它是一台空轉的 gateway, 所以 §6.1 讓它變成專家宿主
  不需要遷移任何既有流量。
- `hermes-dashboard` 掛的是 **`frontdoor-hermes`** (參謀長的 home), 不是 `hermes-data`。
- **agent uid 10000 現在可以自主裝 nix 套件**: `nix-add` / `nix-list` 在
  paperclip / hermes / frontdoor / buzz 四個容器都以 runtime user 可用
  (`groups=…,3000(nixagents)`)。`/opt/mise` 仍是 root-only, 但那符合
  `container-tools` skill 的規則 (語言 runtime 以外一律走 nix)。
- Paperclip 現有 agent: `OMP Engineer` / `Prototyper`, 兩者 `role=general`、
  `reportsTo=null` (全扁平, 無 CEO)。

### 4.6 記憶體量測 (2026-08-20, 決定 §6.1 的數據)

`hermes gateway run` 的常駐 python 行程:

```
VmRSS   118416 kB
RssAnon 110812 kB   ← Python heap, 每個行程私有, 容器間不共享
RssFile   7604 kB   ← 只有這 7.6 MB 是 image page cache, 多容器才共享
```

**所以「每個專家一個容器」的邊際成本是 ~111 MB 真實 RAM, 不是共享的。**

multiplex 的 scaling (同一個 image, `docker compose run` probe 容器, 假 profile):

| 設定 | 常駐 RSS |
|---|---|
| 非 multiplex, 只有 default | 118 MB |
| multiplex + 5 profiles | 192 MB |
| multiplex + 25 profiles | 373 MB |

→ **~148 MB 固定 + ~9.05 MB / profile**。而且是 **eager**: 重啟後一個 profile 都
沒觸碰就已經 373 MB (觸碰全部 25 個之後只多 8 KB), 所以 9 MB 是常駐成本, 不是用
到才長 —— 反過來說也代表它不會在使用時突然膨脹。

| | 公式 | N=3 | N=5 | N=10 | N=25 |
|---|---|---|---|---|---|
| 每專家一容器 | ~118 MB × N | 354 MB | 590 MB | 1.18 GB | **2.95 GB** |
| multiplex 單行程 | ~148 MB + ~9 MB × N | 175 MB | 193 MB | 238 MB | **373 MB** |

N=25 差 8 倍。「未來專家可能非常多」這個前提下, 這個差距是決定性的。

### 4.7 上游的 per-profile s6 逃生門

hermes image 有 `/etc/cont-init.d/02-reconcile-profiles` → `hermes_cli/container_boot.py`:
開機掃 `$HERMES_HOME/profiles/`, **per-profile 建一個 s6 service slot**, 只自動起
「上次記錄為 `running`」的那些 (`gateway_state.json` 的 `desired_state`)。

`container_boot.py:195` 的條件是 `not multiplex_profiles and prior_state in
_AUTOSTART_STATES` —— **multiplex 開著時它不會重複起**, 兩者由上游設計成互斥。

意義: §6.1 選 multiplex **不是不可逆的**。哪天某個專家特別會炸或特別吃記憶體,
把它從 multiplex allowlist 拿掉、`desired_state` 設成 `running`, 它就獨立成一個
受 s6 監督的行程 —— **profile 目錄 layout 完全一樣, 資料不用搬**。

### 4.8 dashboard 的 profile switcher

- `web_server.py` 每一個 read/write endpoint 都吃 `?profile=` query param, 由
  `_profile_scope()` 統一 scope config 與 skill 目錄解析。上游在 `:14358-14365`
  寫明這是為了修「切了 profile 卻寫進 dashboard 自己的 config」那個 bug 才做成全域的。
  涵蓋 sessions / logs / files / cron / skills / models / status。
- 列舉來源是 `list_profiles()` (`profiles.py:889`) 掃 `$HERMES_HOME/profiles/`,
  名字要合 `^[a-z0-9][a-z0-9_-]{0,63}$`。**實測**: 在 `frontdoor-hermes` 上放一個
  只有 `config.yaml` 的空目錄, dashboard 容器裡 `hermes profile list` 立刻列出它,
  零改動。
- ⚠️ **dashboard 容器必須被上游偵測為 dashboard, 否則會踩 flock storm。**
  `container_boot.py:353` `_is_dashboard_container()` 的 docstring 寫得很直白:
  gateway 與 dashboard 共用 HERMES_HOME 時, 兩邊搶 `logs/gateways/<profile>/lock`
  會產生 "Resource busy" 與 s6-log restart storm, 所以 dashboard 容器完全跳過
  reconcile。它從 `/proc/1/cmdline` 判斷 argv[0] == `dashboard`, **刻意不做成 flag**
  (原話: 旗標會被手寫的 compose/k8s manifest 忘記設, 於是重新引入它要防的 storm)。
  **我們現在是 `command: ["sleep", "infinity"]` —— 偵測不到。** volume 上一旦出現
  profile 就會中。這是 §5.1 必須連帶修掉的東西。
  ⚠️ **尚未驗證**: 我們用 `sleep infinity` 是因為真正幹活的是 s6 的 `dashboard`
  service (`HERMES_DASHBOARD=1`)。改成 argv[0]==`dashboard` 之後 s6 的 main program
  換人, 9119 是否照常起來**必須實測**, 這是 implementation plan 的第一步。備案是
  維持 `sleep infinity` 但不讓 dashboard 掛 `hermes-profiles` (代價: 專家要另開一個
  dashboard, 違反 §1 的「一次登入」)。

### 4.9 buzz CLI 跨 image 可攜

buzz CLI 是 Rust binary, 只在 buzz build 產出 (`patches/buzz/Dockerfile:73`),
hermes image 沒有。實測把 `/usr/local/bin/buzz.bin` 從 frontdoor 容器複製進 hermes
容器可以執行 (bookworm 建的 binary 在 trixie 上向前相容; 回的是 clap 的 flag 錯誤,
代表二進位本身跑起來了)。所以 `COPY --from` 取用可行, 沿用 nix-seed 的
`FROM ${IMAGE} AS <alias>` + `COPY --from=<alias>` pattern (BuildKit 的 `--from`
不展開變數)。

## 5. 架構決策

### 5.1 容器形狀: multiplex, 不新增 service

**那台空轉的 `hermes` gateway 直接變成專家宿主。**

```
frontdoor-hermes → frontdoor:/opt/data              參謀長 (default profile)
                 → hermes-dashboard:/opt/data       dashboard 的 HERMES_HOME
hermes-profiles  → hermes:/opt/data/profiles        全部專家 ← 新 volume
                 → hermes-dashboard:/opt/data/profiles
```

為什麼是這個佈局, 而不是讓 `hermes` 整顆掛 `frontdoor-hermes`:

`frontdoor-hermes` 的根目錄有 `.agent.nsec` (參謀長的 Buzz 私鑰, `600 uid 10000`)
與 `.paperclip-api.key`。專家跑在同一個 uid, 而 §4.1 已經確認 cross-profile guard
不涵蓋 terminal tool —— 整顆掛進去等於一行 `cat` 就拿到參謀長的身分。**專家容器
不掛 `frontdoor-hermes`**, 只掛 `hermes-profiles`, 所以參謀長的隔離是**容器級**的。

反過來 dashboard 兩顆都掛, 於是它的 switcher 一次看得到 default (參謀長) 與每一個
專家 —— **一個 URL、一次登入**。這正是「profiles 根錨在 HERMES_HOME」(§4.1) 換來的:
誰的行程在跑, 與誰看得到, 是兩件獨立的事。

**加第 N 個專家不需要動 compose** —— 建 profile 目錄即可 (其餘 nsec / add-member /
Paperclip agent 本來就要動 bootstrap script)。

### 5.2 已接受的取捨: 專家之間不隔離

同一個容器、同一個行程、同一個 uid。專家 A 的 terminal tool 可以
`cd ../agt-market-research` 讀它的實驗簿, 也讀得到它的 nsec (= 可以冒名發文)。

**這是換 8 倍記憶體的價錢, 顯式接受。** 參謀長那條硬邊界沒有破 (容器級),
專家彼此之間是榮譽制。需要對某個專家硬隔離時, 走 §4.7 的 per-profile s6 slot
或拉獨立容器, 資料不用搬。

同理, 一個行程也意味著**共用 blast radius**: 某個 profile 讓 gateway 行程崩潰會
影響全部專家 (s6 會自動重起)。但實驗本身是 terminal tool 的**子行程**, 有自己的
RSS, 所以 runaway 記憶體的第一個受害者是它自己而不是 gateway。

### 5.3 溝通管道: push-out via Buzz / pull-in via Paperclip

- **push**: 科學家有自己的 nsec (`$HERMES_HOME/.agent.nsec`) + `buzz-admin add-member`,
  用 buzz CLI 主動發文到頻道 (「我有初步證據了, 看這個」)。per-profile 身分成立的
  根據見 §4.2 最後一條 (contextvar 注入 `HERMES_HOME`)。
- **pull**: 要它做事就在 Paperclip 指派 —— assignment 本來就會叫醒 agent
  (`issue-assignment-wakeup.ts`)。
- **不做**: 同容器再跑一個 buzz-acp 讓人直接跟科學家對話。角色會糊 (它同時是 chat
  agent 又是 Paperclip executor), 且同一個 HERMES_HOME 上多一個 state.db writer。
  想要時再加。
- **絕不共用 `/keys/agent.nsec`** —— 那是參謀長的身分。

## 6. 待辦 (implementation plan 的輸入)

| 檔案 | 改什麼 |
|---|---|
| `docker-compose.yml` | 新 volume `hermes-profiles`; `hermes` 加 `GATEWAY_MULTIPLEX_PROFILES=1` + `hermes-profiles:/opt/data/profiles` + build arg `BUZZ_IMAGE=${IMAGE_PREFIX}/frontdoor:local` (以及讓 hermes 的 build 排在 frontdoor 之後, 同 nix-seed 的作法); `hermes-dashboard` 加同一個掛載, 並改 `command` (見下) |
| `patches/hermes/Dockerfile` | `FROM ${BUZZ_IMAGE} AS buzz-cli` + `COPY --from=buzz-cli` 取 buzz CLI (§4.9) |
| `patches/hermes/hermes-entrypoint.sh` | 開機 reconcile 專家 profile (目錄 / `.env` / SOUL.md / skills, 冪等); buzz wrapper 讀 `$HERMES_HOME/.agent.nsec` |
| `patches/hermes/profiles/agt-scientist/SOUL.md` | 新檔: 科學家身分 + 方法論紀律。**不套用「hermes 不自己實作」那條** (§3 理由 3) |
| `patches/buzz/generate-keys.sh` / `add-member.sh` | 每個專家一把 nsec + relay membership (注意不變量 1: community 綁 canonical host) |
| `patches/paperclip/opc-paperclip-bootstrap.sh` | 新增 Scientist agent, adapter `hermes_gateway`, `apiBaseUrl: http://hermes:8642/p/agt-scientist`, `sessionKeyStrategy: "agent"`; reconcile 而非 create-only (既有坑) |
| `patches/{buzz,hermes}/skills/paperclip-api/SKILL.md` | lane 表加 research → Scientist (**兩份逐字相同**, `prepare.sh` 會擋) |
| `opc-tencentdb-provision.sh` | 註冊 `agt-scientist` (**必須 `agt` 開頭** — 面板用 `lastIndexOf('-agt')` 解析) |
| `.env.example` | 專家的 `API_SERVER_KEY` (multiplex 下 per-profile fail-closed, §4.2) |
| devenv | 給科學家一個**常駐租約**, `DATABASE_URL`/`VALKEY_URL` 寫進它的 profile `.env` |
| `AGENTS.md` | 服務說明: `hermes` 從「空轉 gateway」變成專家宿主; 新增不變量: 專家容器不得掛 `frontdoor-hermes` |

**profile 命名必須是 `agt-*`**: memory plugin 的 `MEMORY_TENCENTDB_AGENT_ID` 讀
`os.environ` (`patches/hermes/memory_tencentdb/__init__.py:554-558`), 是 process-wide,
multiplex 下設不了 per-profile —— 只能靠它 fallback 到 `agent_identity` (= profile 名),
而面板要求 agent_id 以 `agt` 開頭。所以 profile 就叫 `agt-scientist`,
且 `hermes` 容器**不可以**設 `MEMORY_TENCENTDB_AGENT_ID` (目前正是未設, 維持)。

## 7. 已解除的阻塞

**「agent 自主 nix 安裝 + nix volume 持久化」** — 已於 `d29951e` 交付, 設計見
`docs/superpowers/specs/2026-08-20-agent-nix-self-install-design.md`。
uid 10000 現在可用 `nix-add` / `nix-rm` / `nix-list` (§4.5)。
