# Devenv HTTP Preview — Design Spec

**日期**: 2026-08-18
**狀態**: approved, 待實作
**前置**: `2026-08-18-devenv-resource-provisioning-design.md` (devenv 租約機制)

## 背景

Prototype 做出來要**看得到**。目前 prototyper agent 跑完只留下 workspace 裡的 code —— 人要驗收得自己進容器、自己起 dev server、自己想辦法連。回饋迴圈斷在最後一哩。

需求(使用者原話): 「希望 prototype 是有個 dev 環境的 url 讓我看開發成果, 需要即時矯正/修改」, 且**確定會多個 prototype 並行**。

## Upstream 調查: Paperclip 原生有什麼

Paperclip **已經有**完整的 workspace runtime service 機制,不需要自己造:

| 能力 | 位置 |
|---|---|
| service 宣告 (`command`/`port`/`readiness`/`expose`/`stopPolicy`) | `config.workspaceRuntime.services[]`, 存在 execution workspace 的 metadata |
| 生命週期 + 狀態 (status/port/url/health) | `workspaceRuntimeServices` 表 |
| 啟停 API | `POST /execution-workspaces/:id/runtime-services/{start,stop,restart}` |
| UI (開停按鈕 / live URL / copy) | `ui/src/components/WorkspaceServiceControlBar.tsx` |
| Agent 端控制 | MCP `paperclipControlIssueWorkspaceServices` / `paperclipWaitForIssueWorkspaceService` |
| 掛到 issue 上供驗收 | work product type `preview_url` (`packages/shared/src/types/work-product.ts`) |

宣告長這樣:

```json
{ "workspaceRuntime": { "services": [{
    "name": "web",
    "command": "pnpm dev",
    "cwd": ".",
    "port": { "type": "auto" },
    "readiness": { "type": "http", "urlTemplate": "http://127.0.0.1:{{port}}" },
    "expose":    { "type": "url",  "urlTemplate": "http://localhost:{{port}}" },
    "lifecycle": "shared",
    "stopPolicy": { "type": "idle_timeout", "idleSeconds": 1800 }
}]}}
```

⚠️ `doc/plans/` 裡的範例寫 `${port}` 是**過期的**。實際 `renderTemplate()`
(`packages/adapter-utils/src/server-utils.ts:423`) 的 regex 是 `{{ }}`。照 plan doc 抄會得到未展開的字面字串。

### 缺口一: 沒有 reverse proxy

`expose.urlTemplate` 渲染出什麼,UI 就 `<a href>` 什麼 (`WorkspaceServiceControlBar.tsx:154`)。
Paperclip **不做任何 proxy 或 path 掛載** —— 沒有 `/preview/<id>/` 這種東西。
所以 URL 必須是使用者瀏覽器**直接連得到**的位址。

而 paperclip 容器目前只 publish 3100。`port.type: "auto"` 是容器內 `listen(0)`
(`server/src/services/workspace-runtime.ts:3297`) 拿到的隨機 port,沒被 publish —— 渲染出來的連結對 host 是死的。

### 缺口二: 沒有「設定 workspaceRuntime」的 agent 介面

MCP 只給了 start/stop/restart/wait,**沒有寫 config 的 tool**。唯一入口是
`PATCH /execution-workspaces/:id` 帶 `{config:{workspaceRuntime:…}}`
(`server/src/routes/execution-workspaces.ts:573`,validator 全欄位 optional 且 server 端做 merge)。

## 目標

1. 多個 prototype 並行,各自拿到穩定、host 連得到的 preview URL。
2. Agent 一兩行指令搞定,不必手寫 JSON config、不必知道 port 怎麼來的。
3. 沿用 devenv 既有租約模型 —— 不新增第二套資源管理概念。
4. 出錯時錯在明處(尤其「顯示 healthy 但連不上」這種必須不可能發生)。

## 非目標

- 反向代理 / 單一 port 多路複用 / 自訂網域。單機單人,port 直通最簡單。
- HTTPS。
- 對外(公網)暴露。全部綁 host loopback。
- 自動回收。跟既有 devenv 一致: 手動 `release`,累積靠 view 看見。

---

## 決策一: port range 必須靜態,base 必須低於 32768

### 為什麼靜態

Docker 的 port 發佈在**容器建立時**決定,執行中無法追加 mapping。所以「對 host 開放哪些 port」只能寫死在 compose,改了要 recreate 容器。這是硬限制,不是選擇。

**動態的是池子內部**: 哪個 prototype 拿到哪個 port,由 devenv 在 provision 當下配發。

Host 端該 port 已被佔用不需要偵測 —— `docker compose up` 會以
`port is already allocated` 明確失敗。

### 為什麼 base = 21000

```
$ cat /proc/sys/net/ipv4/ip_local_port_range
32768	60999
```

這是 kernel 的**隨機發放區**: 任何 `bind(port 0)` 的請求都從這裡挑。Paperclip 的
`allocatePort()` 正是這樣要 port。

若租約 range 落在裡面,情境是: 租戶 A 租了 47105 但 server 當下沒在 listen →
`auto` 模式的另一個 service 被 kernel 隨機分到 47105 → A 要啟動時撞車。
機率低,但症狀完全不像 port 衝突,查起來極貴。

偵測「現在誰空著」解決不了這個問題 —— 衝突發生在**未來**。
選 32768 以下,kernel 永遠不會主動發放,只有指名索取的程式拿得到。

### 但界線本身要動態檢查

`32768` 是預設值,可被 sysctl 改。且會撞車的 `allocatePort()` 跑在 **paperclip 容器內**,
容器有自己的 network namespace —— 要讀的是容器內的值。

`opc-devenv-seed.sh` 開機時比對,重疊則 warn(不擋 `up`,與既有風格一致):

```sh
read _lo _hi < /proc/sys/net/ipv4/ip_local_port_range
# [BASE, BASE+COUNT) 與 [_lo,_hi] 重疊 → 警告
```

### 池子大小

每個 published port 一個 `docker-proxy` 進程,實測 RSS ~2.5–5MB。
預設 **16** 個 slot (~50–80MB),`.env` 可調:

```
DEVENV_HTTP_PORT_BASE=21000
DEVENV_HTTP_PORT_COUNT=16
DEVENV_HTTP_PORT_RANGE_END=21015     # = BASE + COUNT - 1, 見下方警告
DEVENV_HTTP_PUBLIC_HOST=localhost    # DEV_URL 的 host 部分
```

compose 端:

```yaml
ports:
  - "${PAPERCLIP_PORT:-3100}:3100"
  - "127.0.0.1:${DEVENV_HTTP_PORT_BASE:-21000}-${DEVENV_HTTP_PORT_RANGE_END:-21015}:${DEVENV_HTTP_PORT_BASE:-21000}-${DEVENV_HTTP_PORT_RANGE_END:-21015}"
```

⚠️ compose 不會算術。`RANGE_END` 是**第二個**變數,與 `COUNT` 有一致性義務。
`opc-devenv-seed.sh` 一併檢查 `BASE + COUNT - 1 == RANGE_END`,不符就 warn ——
這是本設計最容易被改壞的地方。

綁 `127.0.0.1` 是刻意的: prototype dev server 沒有任何認證。要從別台機器看,
改成 `0.0.0.0` 是使用者的明確決定,不是預設。

---

## 決策二: `provision` 與 `expose` 拆成兩個 subcommand

考慮過併成 `provision --expose-service web="pnpm dev"`(agent 一步到位),否決,決定性理由是**時序**:

```
provision (拿 DB + port) → 寫入 .env → scaffold 專案 → 此時才知道 dev command
```

專案尚未建立時 agent 說不出 `pnpm dev`。合併版會逼它先猜再回頭改,而「改」在合併版
意味著重跑租約操作。拆開後 `expose` 天生可重跑,租約不被觸碰。

附帶好處:
- Paperclip 升版改 API shape,壞的是 `expose`,租約流程不受影響。
- 非 paperclip 情境(`docker exec` 手動操作)`provision` 照樣可用。

代價 —— agent 可能漏跑 `expose` —— 用 `devenv list` 標記補掉(見下)。

---

## `http` provider

### 分配

與 `valkey_db` 同構: registry 欄位 + UNIQUE 讓 DB 當仲裁者,並行呼叫互斥,輸家重試。

```sql
ALTER TABLE devenv_tenant
  ADD COLUMN IF NOT EXISTS http_port_start int UNIQUE,   -- NULL = 未租
  ADD COLUMN IF NOT EXISTS http_port_count int NOT NULL DEFAULT 0;
```

`--with http` 租 1 個;`--with http=3` 租**連續** 3 個(web + api + worker)。
連續配置讓「第 2 個 port」可預測,不必再查表。

⚠️ 既有的 `--with` 解析是純逗號切分 + 白名單比對
(`case "$prov" in postgres|valkey)`),`http=3` 會被判為 unknown provider。
解析要改成先切出 `name=arg`,只有 `http` 接受 `=N`(1..COUNT),其餘 provider 帶 `=` 一律報錯 ——
沉默忽略參數比拒絕更糟。

分配 = 找最小的 `p ∈ [BASE, BASE+COUNT)` 使 `[p, p+n)` 不與任何既有租約區間重疊。

⚠️ `http_port_start UNIQUE` 只擋得住起點相同,擋不住區間重疊
(A 租 21000+3、B 租 21001+1 起點不同但重疊)。所以 `n > 1` 時 **UNIQUE 不是充分的仲裁者** ——
分配 SQL 必須在單一 statement 內完成重疊檢查與 INSERT/UPDATE,或以
`SELECT … FOR UPDATE` 鎖住 registry。實作時採後者(range 表小,鎖成本可忽略)。

### 產出

```
DEV_PORT=21004
DEV_PORT_2=21005          # 只在 n > 1 時出現
DEV_URL=http://localhost:21004
HOST=0.0.0.0
```

**`HOST=0.0.0.0` 是本設計最重要的一行。**

vite / next / nuxt 預設綁 loopback。Docker publish 的流量從容器 eth0 進來,綁 loopback 就完全不通 ——
但 Paperclip 的 readiness 是**從容器內**打 `127.0.0.1`,照樣通過。
結果是 board 顯示綠色 live、點下去連不上,而所有健康指標都說沒問題。

provider 把正確預設直接寫進 `.env`,這個坑就不存在。這是 provider 該做的事:
讓正確的做法成為預設,而不是寫進文件叫人記得。

`DEV_URL` 的 host 部分由 `DEVENV_HTTP_PUBLIC_HOST`(預設 `localhost`)決定,
搭配 compose 的 bind 位址一起改。

### release

歸還 = registry 欄位清空(由既有的 `DELETE FROM devenv_tenant` 涵蓋)。
port 沒有需要清理的伺服器端狀態,不像 valkey 要 FLUSHDB。

但**若該 port 上還有 service 在跑**,release 後 port 會被重新配發給下一個租戶,
造成新租戶啟動失敗。`release` 先嘗試 `expose --stop`。

⚠️ 這一步經常會失敗,而且是預期內的: `release` 多半由人從 `docker exec` 跑,
沒有 `PAPERCLIP_TASK_ID` / `PAPERCLIP_API_KEY`,拿不到 execution workspace(見下方前置條件表)。
所以是 best-effort,**但失敗時要大聲 warn**,明講「port 已歸還,但可能還有 service 佔著,
請從 board 停掉 `<name>`」—— 這個殘留風險必須被看見,不能默默吞掉。

---

## `devenv expose`

```
devenv expose <name> --command <cmd> [--key KEY] [--cwd DIR] [--port-index N] [--start] [--stop]
```

把一個 service 宣告寫進**當前 execution workspace** 的 `config.workspaceRuntime.services[]`
(依 `name` upsert,不覆蓋其他 service),然後可選地啟動它。

- `--key` 指定用哪個租約的 port,省略則取 `.env` 的 `DEVENV_KEY`。
- `--port-index N` 在租了多個 port (`--with http=3`) 時挑第 N 個(0-based,預設 0)——
  一個 workspace 要同時 expose web 與 api 時用。

### 憑證與定位: 全部現成

Agent run 的環境裡已有(acpx 引擎 `packages/adapter-utils/src/acpx-engine/execute.ts:1036-1099`
統一注入,prototyper 的 `claude_local` + `engine:"acp"` 走的正是這條):

- `PAPERCLIP_API_URL` / `PAPERCLIP_API_KEY` —— API key 是 runtime 注入的 per-run token,
  且**明確禁止**從 adapterConfig 帶入。不需要為 devenv 發任何新憑證。
- `PAPERCLIP_TASK_ID` —— 當前 issue id。

### ⚠️ `PAPERCLIP_WORKSPACE_ID` 不能用

直覺會拿它去 PATCH,但它是 **project workspace id,不是 execution workspace id**。
證據: `heartbeat.ts:12932` 把 `executionWorkspace.workspaceId` 塞進去,而
`workspace-runtime.ts` 建 service record 時是 `projectWorkspaceId: input.workspace.workspaceId`。

拿它去 `PATCH /execution-workspaces/:id` 會 404,或更糟 —— 若 id 恰好撞上某個
execution workspace,會改到別人的 config。

正確解析路徑(與 MCP `getIssueWorkspaceRuntime()` 同一條,`packages/mcp-server/src/tools.ts:226`):

```
GET /api/issues/$PAPERCLIP_TASK_ID/heartbeat-context
  → .currentExecutionWorkspace.id
```

### 流程

```sh
BASE="${PAPERCLIP_API_URL%/}"; BASE="${BASE%/api}"     # 與 upstream prompt 同一套正規化

WS=$(GET  $BASE/api/issues/$PAPERCLIP_TASK_ID/heartbeat-context | jq -r .currentExecutionWorkspace.id)
     PATCH $BASE/api/execution-workspaces/$WS  {config:{workspaceRuntime:{services:[…]}}}
     POST  $BASE/api/execution-workspaces/$WS/runtime-services/start      # --start 時
```

寫入的 service 宣告(port 用**明確值**,絕不用 `auto` —— `auto` 拿到的 port 沒被 publish):

```json
{
  "name": "<name>",
  "command": "<cmd>",
  "cwd": "<--cwd, 預設 .>",
  "port": 21004,
  "readiness": { "type": "http", "urlTemplate": "http://127.0.0.1:{{port}}" },
  "expose":    { "type": "url",  "urlTemplate": "http://localhost:{{port}}" },
  "lifecycle": "shared",
  "stopPolicy": { "type": "idle_timeout", "idleSeconds": 1800 }
}
```

readiness 走容器內 `127.0.0.1`、expose 給人看的是 host 位址 —— 兩者本來就是分開的欄位,
語意剛好對上。

### 前置條件不滿足時

| 情況 | 行為 |
|---|---|
| `PAPERCLIP_TASK_ID` 未設(手動 `heartbeat/invoke`,非 issue 喚醒) | exit 2,明講「expose 需要 issue 情境」 |
| `PAPERCLIP_API_KEY` 未設(容器內手動 exec) | exit 2,建議改用 board UI 設定 |
| `heartbeat-context` 無 `currentExecutionWorkspace` | exit 2,「此 run 沒有 execution workspace」 |
| 該 key 沒租 http port | exit 2,「先跑 `devenv provision <key> --with http`」 |

一律不寫半套狀態。

---

## 監控

「這個租約有沒有真的 expose」devenv 無從直接得知 —— 那是 paperclip DB 的狀態。
不反查 paperclip,改由 **`expose` 成功時寫回 registry 的 `http_exposed_at timestamptz`** 近似:
devenv 自己知道自己做過什麼。

`devenv_usage` view 補三欄:

```sql
t.http_port_start,
t.http_port_count,
(t.http_port_start IS NOT NULL AND t.http_exposed_at IS NULL) AS http_unexposed
```

這是**近似**而非真相: 有人從 board UI 手改 config、或 service 後來被刪掉,
`http_exposed_at` 都不會反映。它的用途只是提醒 agent 漏跑一步,不是稽核。

`devenv list` 多印 `port` 與一個 `!` 標記(租了 port 卻沒 expose),
補上拆分 subcommand 的唯一缺點。

## 安全模型

- Preview 綁 host loopback,無認證。這是**開發用途**的明確取捨,寫進 skill 與 AGENTS.md。
- Prototype dev server 執行的是 agent 寫的 code —— 與既有 devenv 租約同一個信任等級(容器內 root 隨便折騰),不放大攻擊面。
- `expose` 只用 run 自帶的 per-run token,不引入長期憑證,不掛載 `/keys`。
- 不變量 6 (無 host mount / privileged) 不受影響: 新增的只是 port publish。

## 錯誤處理

沿用既有 exit code: `0` ok / `2` bad usage / `3` 資源耗盡 / `4` backend 不可達。
`3` 涵蓋「port 池用罄」,訊息帶 `devenv list` 提示與目前 cap,與 valkey 槽位用罄一致。

## 已知風險

1. **`RANGE_END` 與 `COUNT` 不同步** —— compose 無算術能力導致的重複來源。開機檢查 warn,但改壞了在下次 provision 才會炸。**這是本設計最脆弱處。**
2. **改 range 大小要 recreate paperclip 容器** —— docker 限制,寫進文件。
3. **prototype 之間互相 hardcode port** —— agent 可能把 `21004` 寫死進 code 而非讀 `.env`。skill 明講要讀 `DEV_PORT`。
4. **Paperclip 升版改 `workspaceRuntime` schema 或 heartbeat-context 形狀** —— `expose` 會壞,租約不受影響(這正是拆開的理由)。升版檢查清單加一條。
5. **`http_port_start UNIQUE` 不足以防區間重疊**(見上)—— 靠 `FOR UPDATE` 鎖,不能只靠約束。

## 驗證計畫

1. `docker compose config` 在**未改 `.env`** 的情況下通過(開箱即用,與既有 devenv 一致)。
2. `devenv provision p1 --with postgres,http` 兩次 → 同一個 port,`.env` 不重複膨脹。
3. 兩個 key 並行 provision → 拿到不同 port;`--with http=2` 拿到連續兩個且不與他人重疊。
4. 池子租滿 → exit 3,訊息可讀。
5. 起一個**綁 loopback** 的 dummy server → 確認 board 顯示 healthy 但 host 連不上(**證明這個坑真的存在**),再改 `0.0.0.0` → host 連得到。
6. `devenv expose web --command "…" --start` → board 出現 service control bar + 可點的 live URL;host 瀏覽器實際開得起來。
7. 重跑 `expose` 改 command → service 被更新而非新增第二筆。
8. 故意用 `PAPERCLIP_WORKSPACE_ID` 打 PATCH → 記錄實際回應,確認上面的判斷(這條是**驗證我的分析**,不是驗證功能)。
9. `devenv release p1` → port 歸還可再配發;`devenv list` 的 `!` 標記在未 expose 時出現。

## 實作順序

1. schema: `http_port_start` / `http_port_count` / `http_exposed_at` + view 三欄
2. `providers/http.sh`: 分配(`FOR UPDATE`)/ 產出 `.env` / release
3. compose: port range publish + `DEVENV_HTTP_*` env(全部 `:-` 預設)
4. `opc-devenv-seed.sh`: ephemeral range 重疊檢查 + `BASE/COUNT/RANGE_END` 一致性檢查
5. `devenv expose`(含 `--stop`,供 release 呼叫)
6. `devenv list` 補 port 欄與 `!` 標記
7. prototype skill: provision → scaffold → expose 三步,明講讀 `DEV_PORT`、不要 hardcode
8. AGENTS.md: 架構條目 + 已知坑(`{{port}}` 非 `${port}`、`WORKSPACE_ID` 是 project 不是 execution、`RANGE_END` 一致性)

## 實作偏差 (spec 寫定後在實作中修正)

1. **分配鎖不是 `SELECT … FOR UPDATE`,是 `LOCK TABLE … IN EXCLUSIVE MODE`。**
   spec 原文寫 FOR UPDATE,那是錯的: row lock 擋不住**並行 INSERT 一筆新的重疊租約**(phantom),
   而那正是這裡的 race。provision 罕見、表極小,粗鎖成本可忽略。

2. **`opc_devenv_check_port_pool` 不能用 `read a b < /proc/...`。**
   procfs 檔案 `st_size` 回報 0,dash 的 `read` builtin 處理不了 ——
   它吃掉一個 byte 就回傳 1(`32768\t60999` 讀成 `a="3"`)。entrypoint 跑在 `set -e` 下,
   結果是 **paperclip 無限 crash-loop**。改用 `set -- $(cat …)`。
   (bash 的 read 沒事,但 image 的 `/bin/sh` 是 dash。)
   連帶: 呼叫點加 `|| true` —— 這個檔案的契約是「never fatal」,
   一個**警告用途**的診斷絕不該有能力弄垮容器。

3. **`devenv_usage` view 對沒有 postgres 的租約會整個炸掉。**
   原本 `pg_database_size(t.slug)` 直接呼叫並刻意讓它 raise(「租約一定有 DB」)。
   `--with http` 讓這個前提不成立 —— 而且真正的問題是**一筆怪 row 會讓整個 view raise**,
   於是 `devenv list`(正是出事時你會用的工具)完全不能用。
   改成 `LEFT JOIN pg_database`,單一 cell 顯示 `MISSING` 而非整份清單掛掉。
   這是既有的潛在 bug,http provider 只是讓它變得容易踩到。

4. **provision 失敗會留下空殼 registry row。** register-before-create 是刻意的
   (row 才是 port block 的仲裁者),但 pool 用罄這種**正常失敗**會讓 row 永久留著,
   在 `devenv list` 顯示成一筆沒人解釋得了的租約。加了 EXIT trap 回滾,
   且**只回滾本次 invocation 建立的 row** —— 重跑既有租約時絕不能因為某個 provider 出錯
   就拆掉活著的資料庫。回滾走與 `release` 同一個 `devenv_teardown`,兩者不會漂移。

5. **`WorkspaceRuntimeService.status` 在 v2026.817.0 多了 `"provisioning"`。**
   `expose --start` 之後的等待邏輯不能只判斷 `!== "running"`。(尚未實作,記錄於此。)

## 參考

- `docs/superpowers/specs/2026-08-18-devenv-resource-provisioning-design.md`
- `upstream/paperclip/server/src/services/workspace-runtime.ts` (allocatePort / urlTemplate 展開)
- `upstream/paperclip/packages/adapter-utils/src/acpx-engine/execute.ts:1036-1099` (run env 注入)
- `upstream/paperclip/packages/mcp-server/src/tools.ts:226` (execution workspace 解析路徑)
- `upstream/paperclip/doc/plans/2026-03-10-workspace-strategy-and-git-worktrees.md` (原始設計意圖; port 範例語法已過期)
