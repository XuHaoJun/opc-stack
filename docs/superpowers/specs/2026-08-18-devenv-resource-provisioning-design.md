# Devenv Resource Provisioning — Design Spec

日期: 2026-08-18
狀態: 已實作 (compose + CLI + bootstrap; paperclip UI 的 skill/agent 步驟未做)

## 背景

Paperclip 的 agent 需要後端資源才能真的把東西跑起來 (dev server 起得來、e2e 跑得過)。
直接觸發這件事的是 prototyper agent: 未來的實驗多半跟 LLM 相關, pgvector 幾乎是必備。

考慮過三條路並排除:

- **給 agent docker 能力** (掛 `docker.sock` / privileged DinD): 破壞不變量 6 (無 host mount /
  privileged)。掛 socket 等於給以 `--yolo` 執行的 agent host root。
- **rootless podman sidecar**: 不破壞不變量 (host 已確認具備條件: `max_user_namespaces=94964`、
  `/dev/fuse`、cgroup v2、`subuid/subgid` 已設), 但需要 `seccomp=unconfined` + fuse-overlayfs +
  跨容器共用 volume 對齊路徑, 是一整層巢狀執行環境。
- **在 compose 裡直接架共用服務, 靠 multi-tenant / namespace 切分**: 選這條。省掉整層巢狀,
  且需要時 expose port 進去查資料很容易。

代價是**不能測試「容器拓撲本身」** (Dockerfile build、compose 起不起得來)。對 LLM 原型與一般
應用開發可接受; 真的需要時再回頭評估 podman sidecar。

## 目標

1. Agent 用**一個指令**取得隔離的後端資源, 產出寫進 workspace `.env`, 用標準變數名。
2. 資源分配對同一個 key **冪等** — 重跑、重試、換 session 都拿到同一組值。
3. 介面對所有 agent 通用 (不是 prototype 專屬), 但**載入仍是 per-agent opt-in**, 正職
   engineer agent 預設看不到任何相關 context。
4. Resource provider 可插拔 — 加一種資源 = 加一支 provider, 不動 CLI 與登記表結構。

## 非目標

- 配額、排程、資源上限管理。
- 跨 agent 的共享協商 (同 key = 共享, 記錄於文件, 不做協商機制)。
- `ephemeral` lifecycle 的自動回收 (欄位保留, 本次不實作 — 見「Lifecycle」)。
- **任何自動回收與排程通知** (`gc`、對帳、壓力警告、Buzz 摘要)。回收一律手動
  `devenv release`; 本次只提供**可觀測性** (`devenv_usage` view) — 見「延後: 自動回收與通知」。
- 容器化資源 (任意 image)。需要時走 podman sidecar, 屬另一個 spec。
- 安全邊界。devenv 是**人體工學與防手滑**, 不是安全機制 (見「安全模型」)。

## 命名: 為什麼不是 `proto-*`

Engineer agent 跑真實 ticket 的 e2e 需要的是同一件事。`proto_` 前綴一旦被 engineer 使用就在
說謊 — 命名是設計洩漏。且 paperclip 自身已有 `/environments/:id/leases` 的 lease 詞彙, 往
「開發環境資源租約」靠攏不是發明新概念。

**通用工具 ≠ 噪音擴散**: paperclip 的 skill 載入由 agent 自己的
`adapterConfig.paperclipSkillSync.desiredSkills` 決定, 沒宣告該欄位就是零 skill
(`readPaperclipSkillSyncPreference()`: `explicit = hasOwnProperty(raw, "desiredSkills")`,
不 explicit 直接回傳 `[]`)。工具做成通用的, engineer agent 依然什麼都看不到。

## 架構

```
compose 服務 (共用, 內部網路)
  devenv-pg      pgvector/pgvector:pg18     內部 devenv-pg:5432
  devenv-valkey  valkey/valkey:9.1.1-alpine 內部 devenv-valkey:6379
        ▲
        │ admin 連線 (只有 CLI 用)
        │
  devenv CLI  /usr/local/bin/devenv        baked 進 paperclip image
        │
        ├── 登記表 devenv_tenant (在 devenv-pg 的 devenv_control DB)
        └── 產出 <workspace>/.env          標準變數名
                    ▲
                    │ 只讀 .env, 不知道 devenv 存在
              agent 的應用程式
```

三個角色刻意分離:

| 角色 | 放哪 | 誰看得到 | 成本 |
|---|---|---|---|
| `devenv` 執行檔 | image `/usr/local/bin` | 全域存在, **沒人被告知** | 零 context |
| 「怎麼用 devenv」 | paperclip local skill `devenv` | 只有掛了的 agent | per-agent |
| prototype 方法論 | GitHub 匯入 skill `prototype` | 只有掛了的 agent | per-agent |

執行檔放全域是刻意的: 噪音的定義是「進 context 的東西」, 磁碟上一支沒人提及的執行檔零成本。
這也繞開 paperclip 的 trust level 限制 (見下)。

### Trust level 限制 (硬性, 來自 upstream)

skill 的 trust level 由檔案內容推導, 不是自行宣告:

| level | 內容 |
|---|---|
| `markdown_only` | 只有 `.md` |
| `assets` | 加靜態檔 |
| `scripts_executables` | 任何 `.sh`/`.js`/`.py`/`.ts` |

> A skill that carries executable scripts **cannot be imported from an external source**
> (GitHub, skills.sh, or a raw URL) — only first-party bundled catalog skills are allowed
> to ship scripts.

且 Git 來源必須 pin 到 40 字元 commit SHA。

推論: `devenv` **不能**塞進 skill 一起匯入 → 必須 baked 進 image。這不是妥協, 剛好與
「零 context」一致。

### CLI 介面

```
devenv provision <key> [--with postgres,valkey] [--lifecycle keep] [--env-file PATH]
devenv release   <key>
devenv list
```

- `<key>`: tenant 識別碼。kebab-case, `^[a-z][a-z0-9-]{1,40}$`。
- `--with`: 預設 `postgres,valkey`。
- `--lifecycle`: 預設 `keep`。傳 `ephemeral` 回傳明確錯誤 (未實作)。
- `--env-file`: 預設 `$PWD/.env`。
- `list`: 直接查 `devenv_usage` view (見「監控」), 不自己算。
- **冪等**: 同 key 重跑回傳既有值, 不重建、不換密碼。
- 退出碼: 0 成功 / 2 參數錯 / 3 資源用罄 / 4 後端不可達。

`provision` 產出 (append/更新既有 `.env`, 只覆寫自己管的 key):

```dotenv
DEVENV_KEY=rag-test
DATABASE_URL=postgres://devenv_rag_test:<pw>@devenv-pg:5432/devenv_rag_test
VALKEY_URL=redis://devenv_rag_test:<pw>@devenv-valkey:6379/7
```

用**標準變數名**是核心設計: app 只讀 `DATABASE_URL` / `VALKEY_URL`, 對 devenv 無感。

### Resource provider 契約

每個 provider 一支 shell function, 三個動詞:

```
<provider>_provision <key> <slug>   # 冪等建立, stdout 輸出 KEY=VALUE 行
<provider>_release   <key> <slug>   # 冪等移除
<provider>_probe                    # 後端可達性檢查
```

`<slug>` = key 正規化後的識別碼 (`-` → `_`, 前綴 `devenv_`), 供需要合法 SQL 識別字的
provider 使用。新增資源種類 = 新增一支 provider + 在 `--with` 白名單註冊。

**postgres provider**
```sql
CREATE ROLE devenv_<slug> LOGIN PASSWORD '<random>';
CREATE DATABASE devenv_<slug> OWNER devenv_<slug>;
REVOKE CONNECT ON DATABASE devenv_<slug> FROM PUBLIC;
\c devenv_<slug>
CREATE EXTENSION IF NOT EXISTS vector;
```
輸出 `DATABASE_URL`。

**valkey provider**

Postgres 的租戶識別是**名字**, valkey 是**編號** — 這是兩者唯一的結構差異, 也是為什麼
需要登記表配號。

從登記表配一個未使用的 db 編號 (1..N-1, 0 保留給 CLI 自己), 然後:
```
ACL SETUSER devenv_<slug> on ><pw> resetdbs db=<n> ~* +@all -@dangerous
```

`db=<dbid>` 是 valkey 的 ACL 資料庫權限, 強制點在 `ACLSelectorCanAccessDb()`: selector 沒有
`ALLDBS` flag 時逐一比對 `selector->dbs` intset, 不在裡面直接拒。這是真隔離, 不是 key 前綴自律。

**版本下限 9.1.0** (實測 tag: `9.0.0` 無 `alldbs`, `9.1.0` 有)。Docker Hub 有
`valkey/valkey:9.1.1-alpine`。

`databases` 是 `IMMUTABLE_CONFIG`, range `1..INT_MAX`, 預設 16 — 啟動參數設 `--databases 64`,
即 63 個租戶上限。用罄時 `devenv provision` 以退出碼 3 明確失敗, 不靜默重用。

輸出 `VALKEY_URL`, 編號放在 URL path (`redis://…/7`) — 標準 redis URL 格式, 所有 client
library 都認, **agent 從頭到尾不需要知道自己是幾號**。

### 登記表

`devenv-pg` 的 `devenv_control` DB:

```sql
CREATE TABLE devenv_tenant (
  key         text PRIMARY KEY,
  slug        text NOT NULL UNIQUE,
  lifecycle   text NOT NULL DEFAULT 'keep'
              CHECK (lifecycle IN ('keep','ephemeral')),
  providers   text[] NOT NULL,
  valkey_db   int UNIQUE,          -- NULL = 未配 valkey
  created_by  text,                -- agent 識別, 供 list/稽核
  created_at  timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now()
);
```

- `UNIQUE(valkey_db)` 讓併發配號由 DB 擋, CLI 不需要鎖。
- 配號 = 挑最小未使用編號 insert, 撞了就重試。
- `lifecycle` 欄位本次只會寫入 `'keep'`; 欄位先留, 之後補 ephemeral 不需要 migration。
- `last_seen_at` 在**每次 `provision`** 更新 (含冪等重跑)。skill 已要求 agent 開工先跑
  `provision`, 所以這是零成本的「還有人在動這個」訊號, 不需額外埋點。它只是欄位, 沒有任何
  行為掛在上面。

### 監控 (`devenv_usage` view)

回收是手動的, 所以**唯一需要的自動化是「看得見」**。做成 view 而不是 dashboard 或通知器:
一份定義同時餵三種消費者, 不用各做各的。

```sql
CREATE OR REPLACE VIEW devenv_usage AS
SELECT t.key,
       t.created_by,
       t.created_at,
       t.last_seen_at,
       now() - t.last_seen_at                    AS idle,
       t.providers,
       t.valkey_db,
       pg_database_size(t.slug)                  AS pg_bytes,
       pg_size_pretty(pg_database_size(t.slug))  AS pg_size
FROM devenv_tenant t
ORDER BY pg_database_size(t.slug) DESC;
```

消費者:

| 誰 | 怎麼看 |
|---|---|
| 人 | SQL client (TablePlus / DBeaver / psql) 連 `127.0.0.1:${DEVENV_PG_PORT:-5433}` |
| CLI | `devenv list` 查同一個 view |
| 未來的自動化 | 同一個 view, 不需改結構 |

**排序刻意用 `pg_bytes` 遞減**: 兩種資源的失敗模式不對稱 —— valkey 槽位有硬上限 63, 用罄時
`provision` 以退出碼 3 自己喊出來, 且不破壞資料; postgres 磁碟則**無上限且不可見**, 一個裝了
embeddings 的 pgvector DB 可以數 GB, 塞爆會拖垮整個 stack。所以 view 第一眼要先回答
「誰在吃磁碟」。

`pg_database_size()` 對已被 `release` 但登記表殘留的列會拋錯 — `release` 是同一個交易裡刪列,
不會出現該狀態; 若人工介入造成漂移, view 會直接報錯而不是靜默給錯數字 (刻意 fail loud)。

### Lifecycle

| 值 | 語意 | 本次 |
|---|---|---|
| `keep` | 明確 `release` 前都在 | **實作** |
| `ephemeral` | run/workspace 結束回收 | 欄位保留, CLI 拒絕, 不實作 |

**回收一律手動** (`devenv release <key>`)。本次不做任何自動回收 —— 取而代之的是
`devenv_usage` view: 累積是看得見的, 什麼時候清由人決定。

不實作 ephemeral 的原因: 自動回收要接 paperclip execution workspace 的生命週期。名稱與資料
模型一次到位, 真的要做時只補回收邏輯, 不需要 migration。

### 延後: 自動回收與通知 (不實作, 記錄以免重新踩坑)

評估過但本次刻意不做。以下是已查證的事實, 供未來決定時直接使用:

**孤兒對帳不需要 hook。** 原本以為 `ephemeral` 卡在「找不到 workspace 生命週期 hook」, 但
`GET /companies/:companyId/execution-workspaces` 存在 —— 用**拉的對帳**即可: 登記表的
`created_by` / key 比對這份清單, workspace 不在了就是孤兒。push (hook) 換成 pull (對帳),
拿到 ephemeral 大部分的價值。

**「擁有者還在不在」比 TTL 正確。** 純 TTL 會刪掉下個月要回來看的原型; 時間只是代理指標。
若要做, 條件應是「孤兒」而非「過期」, `last_seen_at` 只當輔助排序。

**hermes 排程 + Buzz 通知的管線目前不通** (實測):

| | buzz CLI | psql | cron |
|---|---|---|---|
| hermes gateway (8642) | ✗ | ✗ | ✓ (cron 只在 gateway 執行) |
| frontdoor (參謀長, ACP) | ✓ | ✗ | ✗ |

能排程的沒有嘴巴, 有嘴巴的不能排程。要做得先幫 gateway 補 psql + 一條發 Buzz 的路 (它不是
已註冊的 buzz agent, frontdoor 才是)。

**更省的替代方案**: 把壓力提醒搭在 `provision` 上 (它本來就會碰登記表), 槽位或磁碟過門檻就在
輸出附上前幾名候選。零排程、零跨容器管線, 且時機天然正確 —— 只有 provision 才會累積資源。

### Compose 服務

```yaml
devenv-pg:
  image: pgvector/pgvector:pg18
  environment: { POSTGRES_PASSWORD: ${DEVENV_PG_PASSWORD:?set in .env}, ... }
  ports: ["127.0.0.1:${DEVENV_PG_PORT:-5433}:5432"]
  volumes: [devenv-pg-data:/var/lib/postgresql/data]
  healthcheck: pg_isready

devenv-valkey:
  image: valkey/valkey:9.1.1-alpine
  command: ["valkey-server", "--databases", "64",
            "--requirepass", "${DEVENV_VALKEY_PASSWORD:?set in .env}",
            "--appendonly", "yes"]
  ports: ["127.0.0.1:${DEVENV_VALKEY_PORT:-6380}:6379"]
  volumes: [devenv-valkey-data:/data]
  healthcheck: valkey-cli ping
```

- host 一律綁 `127.0.0.1`, 不對 LAN 開 (符合「容易 expose 進去查資料」但不擴大暴露面)。
- host 埠選 5433/6380 而非 5432/6379: 避開 host 上可能已存在的本機 postgres/redis
  (stack 內的 `buzz-db` / `buzz-redis` 並未 publish 埠, 不構成衝突, 但預留餘裕)。
- **不共用 `buzz-redis` / `buzz-minio`**: 那是 buzz 的營運存儲, 污染它會影響對話平面。
- paperclip `depends_on` 兩者 `service_healthy`。

### Bootstrap

`devenv-bootstrap` one-shot (或併入既有 paperclip bootstrap): 建 `devenv_control` DB +
`devenv_tenant` 表 + `devenv_usage` view (`CREATE OR REPLACE`, 故可安全重跑), 冪等。`docker compose down -v` 後自動重建。

登記表與資料同在 `devenv-pg` — `down -v` 時一起消失, 不會出現「登記表說有、DB 卻沒了」的漂移。

## Prototyper agent 設定

| 項目 | 值 |
|---|---|
| adapterType | `claude_local` |
| engine | `acp` |
| agentCommand | `omp acp --yolo` (與 engineer 一致; 未來換 claude 拿掉此行) |
| env.HOME | `/agent-homes/prototyper` (已存在, 帶 Claude cred) |
| model / effort | `cheap` profile |
| maxTurnsPerRun | 低 (相對 engineer) |
| workspaceStrategy | `git_worktree`, throwaway branchTemplate |
| paperclipSkillSync.desiredSkills | `["prototype", "devenv"]` |

**Engineer agent 完全不動** — 不宣告 `paperclipSkillSync` 即為零 skill。

### 兩個 skill

- **`prototype`** — 從 GitHub 匯入 `mattpocock/skills` 的 `skills/engineering/prototype`
  (markdown_only, 匯入時自動 pin commit SHA)。
  需在 agent instructions 補一句: 該 skill 假設原型緊鄰既有 production code (rule 1 與 6),
  若無對應 production code, 原型自成一個 workspace, rule 6 只保留「把結論寫下來」。
- **`devenv`** — 在 paperclip 內建立的 local skill (非外部匯入, 故不受 script 限制;
  本身仍只是 markdown)。內容三句:
  1. 需要 DB/cache 時第一步跑 `devenv provision <key>` (冪等, 可重跑)
  2. 連線只從 `.env` 讀 `DATABASE_URL` / `VALKEY_URL`, 不要自組連線字串
  3. `.env` 不 commit

## 安全模型 (明確聲明)

`devenv` 與 agent 跑在同一個容器, admin 憑證對 agent 技術上可讀。**這是人體工學, 不是安全
邊界** — 真正的邊界仍是容器本身 (不變量 6)。

ACL 與 per-tenant role 的價值在**防手滑** (tenant A 不會誤刪 tenant B 的資料), 不是防惡意。
共用實例 = 共用 blast radius: 這個 lane 不該放珍貴資料。

## 錯誤處理

| 情況 | 行為 |
|---|---|
| 後端不可達 | 退出碼 4, 訊息指出是 pg 還是 valkey, 不寫 `.env` |
| valkey 編號用罄 | 退出碼 3, 提示 `devenv list` + `devenv release` |
| key 格式非法 | 退出碼 2, 印出規則 |
| 同 key 重跑 | 成功, 回傳既有值, stdout 標註 `(existing)` |
| provision 中途失敗 | 已建資源保留 (冪等), 重跑補齊; 不做交易式 rollback |
| `release` 不存在的 key | 成功 (冪等), 標註 `(absent)` |

## 已知風險

1. ~~**omp 讀不讀得到 skill root**~~ — **已驗證通過, 風險解除 (2026-08-18)**。Prototyper agent
   (`claude_local` + `engine:acp` + `omp acp --yolo`, `desiredSkills:["devenv"]`) 收到一張
   **刻意不提 devenv** 的 ticket ("需要一個帶 pgvector 的 postgres, 自己想辦法取得"), omp 自行
   找到 skill 並執行 `devenv provision opc-2-smoke`, 回報 hostname、pgvector 0.8.6, 還自己多做
   了一次 L2 距離驗算。不需要 `--add-dir`, 也不需要把 skill root 搬進 agent HOME。
   同一次驗證確認 OMP Engineer 的 skill snapshot 是 `desired: []` — 噪音隔離成立。
2. **valkey `db=` ACL 很新** (9.1.x)。client 端無需改動 (就是 `SELECT n`), 但功能本身年輕。
3. **測不了容器拓撲** — 見「背景」。
4. **`.env` 覆寫** — CLI 只覆寫自己管的變數, 不整檔重寫; 需測既有 `.env` 內容不被清掉。

## 驗證計畫

1. `docker compose config --quiet`; 兩服務 healthy。
2. `devenv provision t1` → `.env` 三個變數齊全; `psql "$DATABASE_URL" -c 'SELECT 1'` 通過;
   `CREATE EXTENSION vector` 已就緒。
3. 冪等: 再跑一次 `devenv provision t1` → 值完全相同, 標註 `(existing)`; `last_seen_at` 有更新。
3b. 監控: 從 host `psql -h 127.0.0.1 -p 5433` 查 `SELECT * FROM devenv_usage` → 看得到 t1,
    `pg_size` 非空, `idle` 合理; 寫入約 100MB 資料後再查, `pg_bytes` 明顯上升。
3c. `devenv list` 輸出與 view 一致 (同資料來源, 不得各自計算)。
4. 隔離: `provision t2` 後, 以 t1 憑證連 t2 的 DB 應被拒; 以 t1 的 valkey user `SELECT` 到
   t2 的編號應被 ACL 拒。
5. 編號用罄: 登記表灌到 63 筆後 `provision` 退出碼 3。
6. `release t1` → DB/role/ACL user 皆消失, 編號回到可配; 該列從 `devenv_usage` 消失;
   重跑 `release t1` 仍成功。
7. `.env` 保護: 預先放入自訂變數, `provision` 後該變數仍在。
8. **per-agent 隔離 (關鍵)**: engineer agent 跑一次 heartbeat, 確認其 run log 沒有任何
   `Materialized … Paperclip skill` 記錄, 也沒有 skill root 的 prompt 前綴。
9. **風險 1 驗證**: prototyper 只掛 `devenv` 一個 skill, 下一個需要 DB 的任務, 確認它真的讀到
   SKILL.md 並執行了 `devenv provision`。
10. `docker compose down -v` → `up -d` → bootstrap 重建登記表與 view, `devenv list` 為空
    且不報錯; bootstrap 連跑兩次不報錯 (`CREATE OR REPLACE VIEW`)。

## 實作順序

1. compose 兩服務 + volume + `.env.example` 條目
2. `devenv` CLI + 兩支 provider → `patches/paperclip/`, Dockerfile COPY
3. bootstrap 建 `devenv_control` + `devenv_tenant` + `devenv_usage` view
4. 驗證 1~7 (含 3b/3c)、10
5. paperclip UI: 匯入 `prototype` skill、建立 `devenv` local skill
6. 建 Prototyper agent, **先只掛 `devenv`** → 驗證 9 (風險 1)
7. 通過後補掛 `prototype`, 驗證 8
8. AGENTS.md: 常用指令 / 已知坑 / 檔案地圖

## 實作偏差 (spec 寫定後在實作中修正)

1. **密碼用推導而非儲存**。spec 的 schema 沒有放 secret 的欄位, 但「冪等 = 回傳同一組憑證」必須讓
   密碼可重現。改成 `sha256(DEVENV_SECRET_SALT | key | provider)` — 冪等成立, 且登記表裡沒有明文
   密碼。代價: 換 salt 會讓所有已發出的 `.env` 失效 (已記在 `.env.example` 與 AGENTS.md)。
   連帶在 bootstrap 加 `REVOKE CONNECT ON DATABASE devenv_control FROM PUBLIC` — 新資料庫預設
   給 PUBLIC CONNECT, 不撤掉的話租戶角色讀得到登記表。
2. **`psql -w`**。密碼缺失時 psql 會互動式提示, 在非互動的 agent run 裡等於**無限掛住且沒有輸出**。
   實測踩到 (測試腳本 sed 取不到密碼 → 整個 exec 卡死)。`-w` 讓它立刻失敗。
3. **`client_min_messages=warning`**。冪等 DDL 每次重跑都噴 "already exists" NOTICE, 會蓋掉
   caller 真正要看的那一行。
4. **devenv-pg volume 掛 `/var/lib/postgresql`**, 不是 spec 寫的 `/var/lib/postgresql/data` —
   pg18 改了慣例, 沿用 pg17 掛法 image 直接拒絕啟動。
5. **所有 devenv 變數改成有預設值** (`:-` 而非 `:?`)。原本比照 stack 其他密碼用必填, 但這是 dev
   lane, 不該讓 `up` 因為它失敗。憑證弱是刻意的: loopback-only、放的是可丟棄的資料。
6. **`created_by` 優先序: `DEVENV_OWNER` → `agent:$PAPERCLIP_AGENT_ID` → `user@hostname`**。
   原本只認 adapterConfig 的 `env.DEVENV_OWNER`, 但實測那個值在 ACP lane 沒有到達 agent 進程
   (存成 `{"type":"plain","value":…}`, 而 env 迴圈 `typeof value !== "string"` 直接跳過), 租約
   被記成 `node@<container>`。`PAPERCLIP_AGENT_ID` 是 paperclip 每次 run 必注入的, 拿它當來源
   等於自動歸屬、無法忘記設定。

## 參考

- 前置作業: `6cd4b12` (Claude cred → `opc-prototyper-home`, 已完成)
- 機制同源: `docs/superpowers/specs/2026-08-17-host-config-sync-design.md`
- upstream: `packages/adapter-utils/src/server-utils.ts`
  (`readPaperclipSkillSyncPreference`)、`packages/adapter-utils/src/acpx-engine/execute.ts`
  (`prepareClaudeSkillRuntime`)、`docs/guides/agent-developer/skills-store.md` (trust levels)
- valkey ACL: `src/acl.c` (`ACLSetSelector` 的 `db=` op、`ACLSelectorCanAccessDb`)
- 孤兒對帳 (延後): paperclip `GET /companies/:companyId/execution-workspaces`
