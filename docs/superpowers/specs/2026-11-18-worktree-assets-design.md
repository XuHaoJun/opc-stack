# Paperclip Worktree Assets — 設計規格

日期：2026-11-18 · 狀態：設計稿，未實作

## 問題與選擇

Git linked worktree 不會帶入主 checkout 的未追蹤檔案。讓新 worktree 取得這些檔案是常見需求：[Claude Code 的 `.worktreeinclude`](https://code.claude.com/docs/en/worktrees#copy-gitignored-files-into-worktrees) 和 [Worktrunk 的 `copy-ignored`](https://worktrunk.dev/step) 都提供這類功能。**常見的是補齊本機輸入，不是讓每個 worktree 永遠讀最新資料。**

`champi-survivor` 有約 5 GB 的本機遊戲來源資料與 194 MB 的可寫抽取樣板。來源不應放進 Git、上傳遠端或由 CI 分發；既有工具讀 `assets/Data`、寫 `assets/game`。要讓每個 worktree 使用與程式碼相容的同一版輸入、不複製 5 GB，並避免抽取改到其他 worktree。隔離單位是 **execution worktree**，不是 issue ID；若多個 issue 共用同一個 worktree，衍生物也共用。

| 方案 | 適用範圍 |
|---|---|
| 普通複製／worktree 工具 | 小量未追蹤檔案優先採用；每個 worktree 複製 5 GB 不合適，另裝 Git hook 也不能取代 Paperclip 的 reuse 入口。 |
| [Git LFS](https://git-lfs.com/)／既有 artifact registry | 可分發且已有存取控管的素材優先沿用；這案的素材只留在 operator 管理的本機。 |
| **本機不可變素材 + worktree 自有衍生物** | 採用。Git 固定 revision，Paperclip provision 在既有工具路徑建出唯讀 link 與可寫 clone。 |

## 支援邊界

- 以現有 Paperclip `v2026.1106.0` 開發，不以升版為前置條件。只支援**可信任專案、同一 task 使用專案預設來源、在 Paperclip 容器本機執行的 linked Git execution worktree**。project clone、prototype、外部 `existing` 選擇／copy-only、SSH／sandbox／plugin，以及 CI 素材配送，不在支援範圍。
- Compose 建立 `opc-assets` named volume，只以 `:ro` 掛給 `paperclip` 的 `/opt/opc-assets`。只有 operator 的一次性管理容器可寫入。不用 host bind mount、privileged、Docker socket、常駐服務；不 patch Paperclip、不改專案抽取工具。
- `:ro` 是寫保護，**不是專案間存取控制**。同一容器內能讀掛載的程式可讀所有 store。不同信任範圍用不同部署；勿將憑證或跨專案受限資料放入共同掛載。
- 不做 `current` alias、共享可寫快取、衍生物 promote、網路下載或自動 GC。`SETUP.md` 記錄匯入、備份與退役；乾淨 `setup.sh` 不會自行抓私有資料。

### 啟用、停用與空載成本

- **專案預設不使用**：要同時接入 provision wrapper 與提交 `.worktree-assets.json`，才會在該 worktree 嘗試 provision。沒有 manifest 的專案不建 `assets/` 或 state；已 provision 的 worktree 不可用移除 manifest 的方式停用，仍會判為衝突。
- **全 stack 暫停 provision**：既定 Compose 掛載與 CLI 保持安裝；`WORKTREE_ASSETS_ENABLED=false` 停止新的 provision，未設定或 `true` 允許 opt-in 專案使用。此變數由 Compose 明確傳給 `paperclip`；改 .env 後需重建容器配置（`docker compose up -d paperclip`），不需重建 image。停用不卸載 volume、不拔既有 link、不清已存在的 clone 或 revision；host 管理指令不受影響。恢復啟用後下一次符合條件的 reuse 可補建。
- **開關本身不預留素材容量**：沒匯入任何素材時，只有 image 中的 CLI 和空 named volume 的固定開銷；不建樣板副本、不啟動背景程序。就算已接入 manifest，找不到指定 revision 也不落地任何 worktree 產物。容量是在匯入 revision，以及 worktree 實際 clone／寫入後才增加。停用不回收既有用量。

### Paperclip 的另一組開關：Git cache expiration／restore points

OPC-assets 的支援配置要求 `PAPERCLIP_GIT_CACHE_EXPIRATION_ENABLED` 和 `PAPERCLIP_GIT_RESTORE_POINTS_ENABLED` 都未設定或設為 `false`；目前 pin 與 [v2026.1117.0](https://github.com/paperclipai/paperclip/blob/v2026.1117.0/server/src/config.ts#L389-L416) 都要明確設 `true` 才開啟。這不關掉正常的 terminal reaper。已接入素材的 worktree 若遇到不相容設定，啟用中的 CLI 要報錯而非照常 provision；未接入的專案不受 CLI 阻擋。

嚴格的 Git cache expiration 可能因有 ignored 檔而保留 worktree；[v2026.1117.0 的 restore points](https://github.com/paperclipai/paperclip/pull/17290) 可把部分 ignored 檔（如 `assets/game`、binding、state）存進設定的 storage（可能是 S3），重開時[先還原再 provision](https://github.com/paperclipai/paperclip/blob/v2026.1117.0/server/src/services/workspace-runtime.ts#L4238-L4252)。`assets/Data` 只會記 symlink 目標，不會複製來源的 5 GB。開 restore points 本身不預留固定空間，但符合條件的**其他** worktree 即使不用 OPC-assets 也可能產生快照。停用 OPC-assets provision 不會阻止 Paperclip 捕捉既有素材檔；已接入的 stack 不應打開這兩個 Paperclip 選項。

## 固定素材版本

```text
/opt/opc-assets/<store>/revisions/<sha256>/
  inventory.json
  payload/
```

`revision` 是 `sha256:<64 個小寫 hex>`；磁碟路徑只用 hex。發布後不覆寫。從同一份備份重匯要得到相同 ID：

- 以 `payload` 內的 POSIX 相對路徑為準。目錄也入清單（含空目錄，不含 `payload` 根目錄）。檔名用有效 UTF-8，不做 Unicode 正規化，排序用 UTF-8 byte order。
- `inventory.json` 是以標準 `JSON.stringify` 產生的 UTF-8 JSON 陣列，無 BOM、縮排或末尾換行。目錄列為 `["d",path]`，檔案列為 `["f",path,sha256hex]`；revision 是這份 inventory bytes 的 SHA-256。只在匯入時 hash 檔案內容，不在每次 provision 重讀素材。
- 只接受普通檔案及真目錄；拒絕 symlink、hardlink、特殊檔案，且不保留 ACL、owner、時間戳或執行位。發布資料的檔案為 0644、目錄為 0755；容器內由唯讀掛載保護。來源在匯入期間必須停止變動。

Git 記錄 `(store, revision)`，同一 worktree 的 link 與 clone 一定來自同一 revision。換版順序是**先匯入、再提交 manifest**；既有 worktree 不原地換版。舊分支與 reopen 仍以各自 worktree 的 manifest 為準，不追全域最新版。

## 專案端契約

根目錄提交 `.worktree-assets.json`：

```json
{
  "version": 1,
  "store": "champi-survivor",
  "revision": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "entries": [
    { "target": "Data", "source": "Data", "mode": "link" },
    { "target": "game", "source": "game", "mode": "clone" }
  ]
}
```

- 範例 digest 僅示意。manifest 只接受版本 `1`、非空 entries 與已宣告欄位；所有欄位必填。固定使用 **`assets/` 專用目錄**，不可夾帶 tracked 檔或其他工具的資料；已有 tracked `assets/` 的專案不適用此契約。`target` 是 `assets/` 的直接子項且唯一。`store`、`target` 均為單段，以 ASCII 英數起始，其餘限英數、`.`、`_`、`-`；store 只用小寫。專案不得用 Paperclip compaction 候選目錄名命名 clone target。
- `source` 相對於 revision 的 `payload/`；拒絕絕對路徑、空段、`.`、`..`、Git metadata 或 symlink 路徑。`link` 接收檔案或目錄，指向固定 revision；`clone` 只接受目錄，建出 runtime user 可寫的真目錄。沒有逐項 optional，不建半可用的素材環境。
- 提交根 `.gitignore` 的 `/assets/` 和 `/.worktree-assets-state/`，兩者都是真目錄。驗證實際命中的規則來自 tracked 根 `.gitignore`，且涵蓋整棵樹；另用 Git index 拒絕兩棵樹內的 tracked 檔、submodule。不能只信全域 exclude，或只測尚不存在的裸路徑。
- `assets/` 內保留 `.opc-assets-binding.json`，記錄實際 provision 的完整 manifest。專案工具只處理各自的 target，不碰 binding 或 state；需要交付的產物不能只留在這棵樹。

## Provision 與恢復

`worktree-assets` 裝進 Paperclip image，以 agent 的 runtime user 執行。只有 `init`（可寫）與 `status`（只讀）；從 worktree root 讀 manifest，用 Git root、git-dir／common-dir 和 linked-worktree metadata 判定，不單靠 `.git` 是否為檔案。執行時固定 store root，不提供任意路徑覆寫。

| 狀態 | `init` | `status` |
|---|---|---|
| `not-configured`／`not-worktree` | 不寫，exit 0 | exit 0，報狀態 |
| `disabled`：stack 暫停 provision，worktree 已接入 | 不寫，報停用，exit 0 | exit 1，報停用，不視為 ready |
| `ready` | 建好或保留既有 binding，exit 0 | exit 0，報 store、revision |
| `not-provisioned`：revision 在，尚無 binding | 建立整組，成功 exit 0 | exit 1 |
| `missing-revision`：尚未 provision，指定版本也未匯入 | 不寫，報缺哪個 store/revision，exit 1 | exit 1 |
| `conflict`／`invalid` | 不覆蓋、不刪資料，exit 2 | exit 2 |
| `io-error`／掛載缺失 | 明確報部署或 IO 錯誤，exit 3 | exit 3 |

1. 先辨識 linked worktree 與專案是否接入（manifest 或既有 state）；非適用路徑直接退出。已接入且 stack 停用則回 `disabled`，不碰 store 或 worktree 產物；否則先檢查 Paperclip 兩個開關，再驗宣告、掛載、Git、既有 root 與來源。任何一個 Paperclip 開關為 `true` 回 `invalid`，訊息要點名不相容設定。拒絕 manifest、root 或 state 本身為 symlink、陌生既有 root。只有**尚未發布**的 revision 可降級；已發布但缺 inventory/entry、已有 binding 的 revision 消失、或已有 state 而 manifest 消失，都是錯誤。
2. `/.worktree-assets-state/` 有固定 lock 與專用 staging。`flock` 串行同 worktree 的 `init`；拿鎖後重驗。寫 staging 的複製子程序也須受同一把鎖保護。鎖等待超時明確失敗，不以 PID 或時間強搶，不 unlink lock inode。只在持鎖時回收 CLI 保留的 staging。
3. 在同一棵 staging 建所有 target 和 binding，然後**同 filesystem、不覆蓋已存在目的地、不 fallback 到 move-copy**地 rename 為 `assets/`。現行 image 的 GNU `mv` 支援 `-T --no-copy --update=none-fail`。中斷只會留下隱藏 staging 或完整 root；不能用 `exists` 後接可覆蓋的 rename。
4. 重跑時比對已驗證的 manifest（entry 順序不算差異），確認 link 仍指向指定來源、clone 仍是真目錄；不遍歷或重寫 clone 的內容。binding 不符、target 被換掉或缺失就報衝突。升版、重建請用新 execution worktree；沒有 `reset` 或 `--force`。
5. `clone` 預設用 `cp --reflink=always`，不默默改成整份複製。operator 評估容量後可在 Paperclip 部署設 `WORKTREE_ASSETS_ALLOW_FULL_COPY=1`，允許 `--reflink=auto`；最壞是每個 worktree 一份完整樣板，沒有時間承諾。已用目前 image、runtime UID、兩顆暫存 Docker volume（來源 `:ro`）實測跨 mount reflink 成功；[Btrfs 文件](https://btrfs.readthedocs.io/en/latest/Reflink.html) 說明這不是任意 filesystem 或 mount 的保證。

### Paperclip 入口

在專案的 `scripts/provision-worktree.sh` 或現有的 `workspaceStrategy.provisionCommand` 中組合這個步驟，不覆寫既有 provision。單獨使用的 wrapper：

```sh
#!/bin/sh
if ! command -v worktree-assets >/dev/null 2>&1; then
    if [ -e .worktree-assets.json ] || [ -L .worktree-assets.json ] ||
       [ -e .worktree-assets-state ] || [ -L .worktree-assets-state ]; then
        echo 'worktree-assets CLI missing from the Paperclip image' >&2
        exit 3
    fi
    exit 0
fi

rc=0
worktree-assets init || rc=$?
[ "$rc" -eq 1 ] && exit 0  # init 已記錄 missing-revision
exit "$rc"
```

上游[從主 checkout 解析 script](../../../upstream/paperclip/server/src/services/workspace-runtime.ts#L3016)，[以 execution worktree 為 cwd](../../../upstream/paperclip/server/src/services/workspace-runtime.ts#L3247)，[reuse 也呼叫](../../../upstream/paperclip/server/src/services/workspace-runtime.ts#L3487)；[部分環境及 source-trust 選擇會跳過](../../../upstream/paperclip/server/src/services/heartbeat/workspace-preparation.ts#L426)。只提交在 task branch 的 wrapper 不會自動啟用。wrapper 保持薄，CLI 對尚可 reopen 的 manifest 保持相容；不把遠端 provision 的 300 秒套成本機保證。素材補匯入後，下一次符合條件的 reuse 或 runtime user 手動 `init` 才能補建。新版 [v2026.1117.0](https://github.com/paperclipai/paperclip/pull/19860) 的子任務不再繼承父任務 checkout；用 `git_worktree` 策略時，每個實際建立的子任務 worktree 都要算一份可寫樣板的容量。

專案文件要求在素材相關工作前跑 `status`；缺料時仍跑不需素材的檢查，明確標出哪項未驗證。**需要素材的驗收不能以 skip 充當通過**：一般 CI 可標記不適用，專門驗素材的命令遇到缺輸入應失敗。

## Host 管理介面

以下命令在 `opc-stack` 的 host checkout 執行，不用進互動 container shell：

| 指令 | 契約 |
|---|---|
| `./scripts/opc-assets import <store> <host-source-dir> <entry> [<entry> ...]` | 發布一版，成功印 digest。 |
| `./scripts/opc-assets list [<store>]` | 唯讀列出已發布的 store、revision 與容量；標示是邏輯資料量還是實際配置用量。 |
| `./scripts/opc-assets retire <store> <revision>` | 維護窗口內只退役完整指定的一版；先顯示部署、store、digest、容量，要求 operator 確認備份、引用及無進行中的消費／匯入，並輸入完整 digest 確認。沒有批次刪除、「無 live link 就安全」或 project delete hook。 |

匯入明確選一個 host 目錄下的頂層檔案／目錄，保留原名，不 sweep 來源、不接收任意 tar 檔、不做路徑改名：

```sh
./scripts/opc-assets import champi-survivor \
  "$HOME/champi-survivor-worktrees/_shared/assets" Data game
```

1. 由 Compose 實際解析的 project 名和 volume label 找唯一的 `opc-assets` volume；缺失或不唯一便拒絕，不能默默新增一顆。用已建好的 Paperclip image 作一次性 helper：覆寫 entrypoint、不轉送服務環境、無網路、只掛這顆 volume。初次只用 root 建匯入目錄與設定 runtime UID，解包與發布用非 root。
2. Host 驗證來源，將生成的 tar stream 傳至 volume 內唯一 token 的 staging。解包只允許 `payload/` 內的普通檔案與真目錄；拒絕重複路徑、link、特殊檔與逃出 staging 的路徑，不將 archive metadata 套到既有資料。解包、正規化與 inventory 計算完成後，helper 只回報 staging token 與 digest，**不得發布**。
3. Host 確認 producer 與 consumer 都成功才另呼叫 publish。`pipefail` 只能偵測錯誤，不能收回 consumer 先前的副作用。publish 驗 token 與完成標記，使用同 volume 不覆蓋的 rename；同 digest 併發只會有一方寫入，另一方回報已存在、清自己的 staging。不重新寫既有 revision。正常錯誤處理自己的 token；被 kill 留下的 staging 由 operator 在確認沒有匯入進行時處理。
4. 成功才印出可提交到 Git 的 `sha256:…`。保留能重現每個仍需支援的 revision 的來源備份；還原時比對匯入輸出的 digest。不使用 worktree 衍生物重建共享樣板。`down -v` 會移除 volume，不能把它當唯一備份。

首個專案只匯入 `Data`（約 5 GB，link）和 `game`（約 194 MB，clone）。`Data2026.rar`、`evidence`、`source` 不匯入。

專案現有 `tools/worktree.ts` 已在 host 做 link + 每個 worktree 一份 clone；它繼續只服務 host 流程，Paperclip 不呼叫它。實查 `assets/` 在專案 Git index 沒有 tracked 路徑，現有 host ignore 來自 `.git/info/exclude`；接入時要提交上述兩條 `.gitignore` 與 provision wrapper，不能依賴那份本機 exclude。既有 host 的 `assets/` 不自動接管或刪除；實際接入再跑專案的 extractor／素材驗收，確認消費路徑無須修改。

## 清理與容量

- **實體 worktree 成功移除時**，衍生物、binding、staging／lock 一起消失。[Paperclip 一般 terminal reaper](../../../upstream/paperclip/server/src/services/execution-workspaces.ts#L3456) 要求 issue tree 已終止、已交付、Git clean、冷卻期已過且沒有阻擋執行。done／cancelled 或一度標成 archived 不保證目錄已移除；卡住的 worktree 由 Paperclip 清理／診斷，不加第二個刪除者。
- [Compaction 會遞迴找候選目錄](../../../upstream/paperclip/server/src/services/workspace-compaction.ts#L125)，`assets/game/build` 等子目錄仍可能提前消失。整棵樹只放可再生資料；從已移除的 worktree reopen 時重建樣板，不還原舊衍生物。
- 每個 revision 計入素材 volume 容量；沒有自動 prune。Paperclip project delete 不是退役訊號，也不會碰這顆唯讀 volume。先備份並確認沒有仍支援的 ref／可恢復的 workspace 依賴，再於維護窗口用 `retire` 移除指定版本；不能只數現存 symlink。查不清就保留。`SETUP.md` 記錄用量查詢、退役、失敗 staging 與重新匯入。

## 驗收（實作門檻）

| 情境 | 需看到的結果 |
|---|---|
| 版本釘選 | 發布 B 後，既有 worktree A 的 link 與 clone 仍用 A，新 worktree 用其宣告的 B；在 A 改 manifest 報衝突。 |
| 安全與隔離 | 兩個 worktree 寫同名 clone 檔互不影響，來源 `:ro`；拒絕陌生既有目錄、symlink、tracked 子項、忽略規則缺失與壞來源。兩顆 volume 實測 reflink；另驗不支援時只在 opt-in 後才允許複製。 |
| Worktree 交易 | 競爭 init、clone 中止、rename 前目的地出現，不覆寫、不留半套；重跑只清自己的 staging。正常與中斷後的 `git status --porcelain --untracked-files=all` 不因工具暫存變髒。 |
| Import 交易 | producer 寫完有效 tar 後 exit 非零、殺掉中途流程、錯誤輸入時，不得發布新 revision 或更動已發布版；同 digest 併發或重匯只產生一份。備份重匯 digest 相同，改動任一檔案內容後 digest 不同。 |
| 開關與空載 | 未採用專案不寫檔；已接入但空 volume 只報缺 revision，不建立 `assets/` 或 state；stack 停用回 `disabled`，不改既有檔案或 revision，恢復後可補建。開任一 Paperclip 不相容選項時，僅已接入且啟用的 worktree provision 拒絕執行。 |
| Paperclip 真實路徑 | 先驗目前 pin，再在隔離環境驗新版。兩個版本都用同一 task 的可信任本機預設 Git 來源，且 cache expiration／restore points 關閉。經真實 create → 匯入後 reuse → 一般 terminal reaper → reopen：空 volume 時 run 能繼續；補匯入後整組就緒；清理後實體 worktree 消失但共享 revision 不變；reopen 按實際 checkout 的 manifest 重建。Compose 靜態檢查只掛給 Paperclip 且 `:ro`。 |
| 素材退役 | `list` 不寫入；`retire` 未確認時不刪除，確認後只移除完整指定的 revision，其他 revision 不受影響。Paperclip 刪除專案或 workspace 不觸發 `retire`。 |
