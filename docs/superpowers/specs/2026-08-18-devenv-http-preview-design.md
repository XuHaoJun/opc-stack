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

1. 多個 prototype 並行,各自拿到穩定、host 連得到的 preview URL ——
   **URL 跨 session 不變,可以加書籤**。
2. Prototype 有名字、可列舉、說名字就能找到並繼續改。
3. Agent 一兩行指令搞定,不必手寫 JSON config、不必知道 port 怎麼來的。
4. 沿用 devenv 既有租約模型 —— 不新增第二套資源管理概念。
5. 出錯時錯在明處(尤其「顯示 healthy 但連不上」這種必須不可能發生)。
6. **刪除只在人明確要求時發生**,且是一個指令而非四個步驟。

## 版本說明

v1 假設 prototype 是拋棄式的,把生命週期綁在 issue 上。使用者澄清後那個前提不成立
(prototype 有價值就長期保留、只有人同意才刪),**v2 把模型從 issue 改成 project**。
受影響的不只是模型: `devenv expose` 的目標換層、`PAPERCLIP_WORKSPACE_ID` 從陷阱變正解、
自動回收從「延後」變成「永不」。詳見決策二與生命週期規則。

## 非目標

- 反向代理 / 單一 port 多路複用 / 自訂網域。單機單人,port 直通最簡單。
- HTTPS。
- 對外(公網)暴露。全部綁 host loopback。
- **任何形式的自動回收/自動刪除。** 這不是「延後」,是規則 —— 見「生命週期規則 1」。

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

## `http` provider (已實作)

### 分配

registry 欄位 `http_port_start` / `http_port_count`,一個租約持有**連續區間**
`[start, start+count)`。`--with http` 租 1 個,`--with http=3` 租 3 個。

⚠️ `http_port_start UNIQUE` **不足以防重疊**: A 租 21000+3、B 租 21001+1 起點不同卻相撞。
分配用 `LOCK TABLE devenv_tenant IN EXCLUSIVE MODE`(不是 row lock —— 見「實作偏差」1)。

⚠️ 既有 `--with` 是純逗號切分 + 白名單,`http=3` 會被判 unknown provider。
解析改成先切 `name=arg`,只有 `http` 接受 `=N`,其餘帶 `=` 一律報錯。

### 產出

```
DEV_PORT=21004
DEV_PORT_2=21005          # 只在 n > 1 時出現
DEV_URL=http://localhost:21004
HOST=0.0.0.0
```

**`HOST=0.0.0.0` 是本設計最重要的一行。**

vite / next / nuxt 預設綁 loopback。Docker publish 的流量從容器 eth0 進來,綁 loopback
就完全不通 —— 但 Paperclip 的 readiness 是**從容器內**打 `127.0.0.1`,照樣通過。
結果是 board 顯示綠色 live、點下去連不上,而所有健康指標都說沒問題。

實測確認過這個坑存在:

| | 容器內 readiness (127.0.0.1) | host 瀏覽器 |
|---|---|---|
| 綁 loopback | **200** | **連線被拒** |
| 綁 `0.0.0.0` | 200 | 200 |

provider 把正確預設寫進 `.env`,而不是寫進文件叫人記得。

`DEV_URL` 的 host 由 `DEVENV_HTTP_PUBLIC_HOST`(預設 `localhost`)決定,
要與 compose 的 bind 位址一起改。

### release

port 沒有伺服器端狀態要清(不像 valkey 要 FLUSHDB、postgres 要 DROP),
歸還由 registry row 刪除涵蓋。

但**若該 port 上還有 service 在跑**,下一個租戶會啟動失敗。`release` 會警告 ——
且**只能警告**: release 多半由人從 `docker exec` 跑,沒有 paperclip 憑證可以去停它。

---

## 決策二: prototype 是一個 Paperclip project (v2 修正)

### 原本的設計是錯的

v1 假設 prototype 是**拋棄式**的,於是把生命週期綁在 issue 上:一個 prototype =
一張 issue = 一個 execution workspace。理由是只有 execution workspace 這層有回收機制
(`ExecutionWorkspaceCloseReadiness` 會規劃 `stop_runtime_services` /
`git_worktree_remove` / `remove_local_directory`)。

使用者澄清後這個前提不成立:

> prototype 對我來說就是能快速開發出來, 但發現有價值或可能有潛力的話, 會持續保留
> …我只要說名字就能找到並正確持續更新
> …都是要經過我的同意才刪掉, 不會隨意刪除

拋棄式的假設一拿掉,v1 就從優點變成缺陷: issue 關掉,workspace 被回收,
「繼續更新」時那個東西已經不存在了。**回收機制在這裡是負債不是資產。**

### 修正後的模型

```
prototype「recipe-bot」
 ├ Paperclip project     name="recipe-bot"              ← 名字、可列舉、長期存在
 ├ project workspace     cwd=/prototypes/recipe-bot     ← 自己的 git init
 ├ devenv key            recipe-bot                     ← DATABASE_URL / DEV_PORT 固定
 ├ runtime service       掛在 PROJECT workspace 上       ← DEV_URL 跨 session 不變
 └ issue × N             每次「再改一下」= 新開一張, 掛同一個 project
```

Issue 降級為「一次變更請求」。關掉 issue 不動 workspace ——
策略用 `project_primary` / `shared_workspace`,close readiness 有
`isProjectPrimaryWorkspace` 保護旗標。

**不需要 git worktree。** v1 需要它是為了 per-issue 隔離;
現在每個 prototype 本來就有自己的目錄,`git init` 純粹給 agent 做版本控制,
這對「持續更新」反而是需要的。

`isolated_workspace` 只是 *mode*,決定隔離方式的是 *strategy*
(`execution-workspace-policy.ts:80`: 「Mode alone never implies git_worktree」)—— 兩者不要混淆。

### 同一個 prototype 的並行 issue

v2026.817.0 新增 `sharedWorkspaceConcurrency: "auto" | "serialize" | "allow"`。
共用目錄的兩張 issue 設 `serialize` 排隊。升版白撿到的。

---

## 生命週期規則 (硬性)

### 1. 永不自動刪除

使用者規則: **prototype 與正式 project 同級,只有人明確同意才刪。**

已驗證這在 upstream 是結構性成立而非靠自律: paperclip server 全部只有 5 個週期性
timer(heartbeat 排程 / DB 備份 / plugin log 保留 / external objects / plugin job 排程),
**沒有一個碰 workspace 或 project**。`cleanupEligibleAt` 只是標記欄位,沒有 reaper 讀它;
`workspace-instance-cleanup` 僅在明確 close 時呼叫。

⚠️ 前一份 devenv spec 有一節「**延後**: 自動回收與通知」。那個措辭暗示「以後會做」。
**改成規則**: 不是延後,是永遠不做。避免未來看到「延後」就順手實作。

### 2. 三件事必須分開

| | 內容 | 誰能動 |
|---|---|---|
| **租約** | 名字 / DATABASE_URL / port | 只有 `devenv destroy` |
| **程序** | dev server process | 隨時停起,**停了什麼都沒少** |
| **資料** | workspace 目錄 + 資料庫 | 只有 `devenv destroy` |

### 3. 閒置停止: prototype 7 天, 正式永不

`stopPolicy: {type: "idle_timeout", idleSeconds: 604800}`。

已驗證 `idle_timeout` 是實作而非只有 schema
(`workspace-runtime.ts:4632`,`setTimeout(idleSeconds * 1000)`);
7 天 = 604,800,000 ms,在 Node 的 2^31-1 (~24.8 天) 上限內。

**正式開發的 service 不得有 stopPolicy。** 這是 lane 差異,由 `expose --idle` 表達:
prototype 預設 `7d`,engineering lane 明確給 `never`。旋鈕做成中性參數而非
`--prototype` 旗標 —— devenv 是通用租約機制,不是 prototype 專用工具。

### 4. 「叫得回來」是硬需求

> 我要求重新架設起來讓我用, 能生出來就好

冷啟動必須可重現。這是把 service 宣告放在 **project workspace** 而非 execution workspace
的第二個理由: 沒有任何 issue 在跑的時候,宣告依然在,重啟只要一個 API 呼叫。

保證來自四樣東西都持久化:
- service 宣告 (command / cwd / port / env) → project workspace `runtimeConfig`
- port → devenv 租約 (URL 不變, 可加書籤)
- 資料 → tenant 資料庫
- 程式碼 → workspace 目錄

`setupCommand`(project workspace 既有欄位)記 `pnpm install` 之類,
讓放了幾週的 prototype 冷啟動能重建 node_modules。

✅ **已解決**(原本記為已知缺口)。讀 code 找不到 `desiredState` 的開機 reconciler,
實測證實為真 —— 而且比預期嚴重: 不只「重啟後要按一下」, 是**每次容器重建都靜悄悄死掉**,
board 一切正常只有 URL 是死的。補上 `prototype restore` + entrypoint 背景呼叫
(`opc-prototype-restore.sh`)。實測 `docker compose down && up` 後兩個 prototype 自行復原。

---

## `devenv expose` (v2 修正)

```
devenv expose <name> --command <cmd> [--key KEY] [--cwd DIR]
                     [--port-index N] [--idle 7d|never] [--start|--stop]
```

### 目標換層: project workspace

v1 打 execution workspace。**錯的** —— 服務必須跨 issue 存活。改打 project workspace:

```
PATCH /projects/:id/workspaces/:wsId                          ← 寫 runtimeConfig
POST  /projects/:id/workspaces/:wsId/runtime-services/start   ← 啟動
```

execution workspace 沒有自己的設定時會繼承 project workspace 的 `workspaceRuntime`
(`routes/execution-workspaces.ts:200`),所以 issue 執行期間看到的是同一個服務。

### `PAPERCLIP_WORKSPACE_ID` 從陷阱變成正解

v1 特地把它標為坑: 「它是 project workspace id,不是 execution workspace id,
拿去 PATCH execution workspace 會 404 或改到別人的」。

**在 v2 這正是需要的 id。** 連帶好處:
- 不再需要 `GET /issues/:id/heartbeat-context` 解析
- 不再依賴 `PAPERCLIP_TASK_ID` → `expose` 在沒有 issue 的 run 裡也能用

v1 那條「前置條件不滿足」表因此大幅縮小,只剩 `PAPERCLIP_API_KEY` 與 project id 解析。

### 寫入的宣告

```json
{
  "name": "<name>",
  "command": "<cmd>",
  "cwd": "<--cwd, 預設 .>",
  "port": 21004,
  "readiness": { "type": "http", "urlTemplate": "http://127.0.0.1:{{port}}" },
  "expose":    { "type": "url",  "urlTemplate": "http://localhost:{{port}}" },
  "lifecycle": "shared",
  "stopPolicy": { "type": "idle_timeout", "idleSeconds": 604800 }
}
```

`--idle never` 時整個 `stopPolicy` 省略。port 用明確值,**絕不用 `auto`** ——
`auto` 拿到的 port 沒被 publish。

⚠️ v2026.817.0 起 `WorkspaceRuntimeService.status` 多了 `"provisioning"`,
`--start` 後的等待邏輯不能只判斷 `!== "running"`。

---

## `devenv destroy <name>`

刪除是四個步驟(停 service → release 租約 → 刪目錄 → archive project),
**手動記四步遲早漏一步**,留下孤兒目錄或佔著的 port,
而那要等到下一個 prototype 起不來才會被發現。

正因為刪除稀有且不可逆,它該是一個指令:

1. 印出將要刪除的東西 —— 資料庫與其大小、port、workspace 目錄與其大小、project 名稱、issue 數
2. 要求**打一次 prototype 名字**確認(不是 y/N —— 那太容易手滑)
3. 依序執行,任一步失敗就停下並回報已完成到哪裡

`--yes` 旗標**不提供**。這個指令沒有需要自動化的情境,而它的存在會讓「永不自動刪除」
這條規則變成一行 script 就能繞過。

---

## 解析: 用名字找到 prototype

> 我只要說名字就能找到並正確持續更新

hermes 的演算法(建立與續作是**同一條路徑**,這是它可靠的原因):

1. `GET /companies/<id>/projects` → 用 `.name` 比對
2. 找到 → 用該 `projectId` 開新 issue
3. 找不到 → 建 project + workspace,再開 issue

這個 pattern 現有的 `paperclip-api` skill 已經在用了 —— 目前解析 lane 就是
「列 agents、用 `.name` 比對、取 `.id`」。同一招換個對象。

### 同一個 buzz thread 續作

thread → project 的對應必須**持久化在 work plane**,存 project workspace 的
`metadata`(`projectFields` 沒有 metadata,workspace 有)。

**不得存 TencentDB memory。** PRD 硬邊界: memory 只影響 reasoning。
而且記錯的後果是**改到別的 prototype** —— 這是正確性問題,不是便利性問題。

名字解析是主要機制(在 buzz / dashboard chat / 未來 telegram 一致有效),
thread 對應只是加速器,壞掉時退回報名字即可。

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
4. **Paperclip 升版改 `workspaceRuntime` schema 或 project-workspace route** —— `expose` 會壞,租約不受影響(這正是把 `provision` 與 `expose` 拆開的理由)。升版檢查清單加一條。
5. **prototype 名字同時是 project 名、devenv key、目錄名。** 三者必須一致,否則
   `devenv list` 與 project 清單會對不上。名字規則沿用既有 key 驗證
   (`^[a-z][a-z0-9-]{1,40}$`),建 project 時一併套用。
7. **冷啟動可能因為環境過期而失敗**(node_modules 不在、lockfile 對不上)。
   `setupCommand` 是緩解而非保證 —— 放了半年的 prototype 叫不回來是可能的,
   屆時是修而不是重建(資料與程式碼都還在)。

## 驗證計畫

**1-5 已通過**(步驟 1-4 實作完成時驗證):

1. ✅ `docker compose config` 在未改 `.env` 下通過(開箱即用)。
2. ✅ 重複 provision → 同一個 port,`.env` 不膨脹。
3. ✅ 並行 key 拿到不同 port;`http=2` 拿到連續兩個。釋放中間一格後,
   要 2 個會**跳過**那個洞,要 1 個才回頭用。
4. ✅ 池子租滿 → exit 3;五條錯誤路徑 exit code 全對;失敗的 provision 會回滾不留幽靈 row。
5. ✅ 綁 loopback → 容器內 200 / host 拒絕;綁 `0.0.0.0` → 兩邊都 200;
   從 host LAN IP 連不到(確認只綁 loopback)。

**待驗證**:

6. 建一個 prototype project + workspace(`local_path` + `git init`)→
   `devenv expose web --command "…" --start` → board 出現 service control bar + live URL,
   **host 瀏覽器實際開得起來**(這條要人看一眼)。
7. 開第二張 issue 掛同一個 project → 服務**沒有被重建**,URL 不變,
   issue 關掉後服務仍在(證明生命週期綁對層了)。
8. 重跑 `expose` 改 command → service 被更新而非新增第二筆。
9. 停掉服務再 `--start` → 同一個 URL 回來(「叫得回來」)。
10. `docker compose restart paperclip` → 記錄服務是否自己回來
    (預期**不會**,見生命週期規則 4 的已知項)。
11. `devenv destroy <name>` → 先列出、要求打名字、拒絕錯誤的名字;
    執行後 DB / port / 目錄 / project 都不在,且 port 可再配發。
12. hermes 用名字解析: 說一次名字建立、再說一次同名字 → 第二次**續作而非新建**。

## 實作順序

**已完成** (commit `2b35aa8`):

1. ✅ schema: `http_port_start` / `http_port_count` / `http_exposed_at` + view 三欄
2. ✅ `providers/http.sh`: 分配(`LOCK TABLE`)/ 產出 `.env` / release
3. ✅ compose: port range publish + `DEVENV_HTTP_*` env(全部 `:-` 預設)
4. ✅ `opc-devenv-seed.sh`: ephemeral range 重疊 + `BASE/COUNT/RANGE_END` 一致性檢查
5. ✅ `devenv list` 補 port 欄與 `!` 標記(原第 6 步,順手做掉)

**待做**:

6. `/prototypes` named volume + prototype project/workspace 的建立路徑
   (`local_path` + `git init` + `sharedWorkspaceConcurrency: serialize`)
7. `devenv expose`(打 project workspace;`--idle 7d|never`;`--start` / `--stop`)
8. `devenv destroy <name>`(先列出 → 打名字確認 → 依序執行;**不提供 `--yes`**)
9. `paperclip-api` skill: 用名字解析 prototype 的三步演算法
   (列 → 比對 → 找不到才建),**兩份 skill 要同步改**
10. prototype skill: provision → scaffold → expose,明講讀 `DEV_PORT` 不要 hardcode
11. AGENTS.md: 架構條目 + 已知坑(`{{port}}` 非 `${port}`、
    `PAPERCLIP_WORKSPACE_ID` 是 project workspace id、`RANGE_END` 一致性、
    prototype 永不自動刪除)

## 實作偏差 — v2 (步驟 6-8)

6. **`devenv expose` / `devenv destroy` 改成獨立的 `prototype` CLI。**
   不是風格選擇,是被步驟 6 逼出來的: 建立一個 prototype 需要**目錄 + git repo +
   Paperclip project**,這三樣沒有一樣是「開發資源租約」該知道的。
   叫它 `devenv` 會直接違反使用者已經核可的原則(「拆開比較乾淨…抽象一旦破了很難補回來」)。
   分層變成: **devenv = 通用租約, 完全不認識 paperclip;prototype = 工作流物件,
   認識 paperclip + 呼叫 devenv**。devenv 只多了一個 `mark-exposed`
   (由 prototype 呼叫,純粹記錄「有人 expose 過」供 `devenv list` 標記),不含任何 paperclip 知識。

7. **`setupCommand` 從來不會被執行。** upstream 只有 CRUD 讀寫它,沒有任何執行路徑。
   原本打算靠它做 `git init`,行不通。改由 `prototype create` 在容器內直接做。
   同理 **paperclip 不會建 `local_path` workspace 的 cwd**(`mkdir` 只出現在 worktree 路徑),
   所以目錄必須由 `prototype create` 先建好。

8. **board key 鏡像到 `/paperclip/.opc/board-api.key`。**
   agent run 會被注入 per-run 的 `PAPERCLIP_API_KEY`,但人用 `docker exec` 跑
   `prototype destroy` 時沒有。沒有選擇把 `opc-keys` 掛進 paperclip ——
   那個 volume 還放著 buzz 的 relay/agent nsec,paperclip 沒有理由讀得到它們。
   散播一個憑證好過散播四個。

9. **hermes 不建 project。** 原本 spec 讓 hermes 走「列→比對→找不到就建」。
   但建立需要容器內的檔案系統動作,hermes 只有 API。改成 hermes 照舊只開 issue,
   由 Prototyper 在第一次 run 跑 `prototype create <name>`(冪等)。
   已驗證**沒有 project 的 run 仍然可以執行**(跑在 agent home),所以不存在雞生蛋問題,
   而且 hermes 的路由層維持零改動。

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
