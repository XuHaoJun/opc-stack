# Agent 自主 nix 安裝 — 單一 store、共用 profile

## 目標

1. 所有 agent 容器裡的 **agent (非 root)** 能自己裝 nix 套件。
2. 裝過的工具在**所有容器**都看得到 —— 單一共用 profile。
3. 持久化靠 nix volume (不是 container layer)。
4. 系統 seed 工具 (11 個) 仍然只有 root 能改。
5. agent 由 skill / AGENTS.md / SOUL.md 告知: **優先 nix, 不要 apt**。

第 5 點的理由是硬的, 不是風格偏好: **apt 裝的東西在 container layer,
`up -d --build` 或 recreate 就消失**; nix 裝的在 volume, 活得下來。

## 現況與差距

`docs/superpowers/specs/2026-08-16-container-toolchain-design.md` §6 明確決定
「`/opt/mise` root 擁有 … daemon 用戶不可寫 → daemon 無法改 toolchain, 符合
『不影響本體』」。當時的需求是**工具持久化**, 不是 agent 自主安裝。

實測 (2026-08-20, 四個容器一致):

| 項目 | 現況 |
|---|---|
| nix 安裝模式 | **single-user** (`--no-daemon`), `/nix` `root:root` |
| daemon socket | **不存在** |
| 非 root 執行 nix | `error: opening lock file "/nix/var/nix/db/big-lock": Permission denied` |
| `/opt/mise` | `root:root 755` → runtime user 連 `touch` 都不行 |
| nix volume | **四個獨立**: `opc_buzz-nix` / `opc_frontdoor-nix` / `opc_hermes-nix` (hermes + hermes-dashboard 共用) / `opc_paperclip-nix` |
| runtime uid | frontdoor/hermes **10000**, paperclip **1000**, buzz 全 root |

所以「裝一次全部容器都有」目前**不成立** —— 共用的是 nix-seed **image**
(build 時 `COPY --from=nix-seed`), 不是 runtime volume。

## 已驗證的可行性 (全部實測過, 環境已還原)

| 驗證 | 結果 |
|---|---|
| `nix-daemon` binary | 已在 image 內 (`/nix/var/nix/profiles/default/bin/nix-daemon`) |
| `nixbld` group + build user | **image 裡已經有了** (`patches/*/Dockerfile`) — multi-user 前置條件早就備妥 |
| 非 root 連 daemon | **自動偵測 socket**, 不需要 `NIX_REMOTE` |
| 非 root 實際安裝 | `nix profile add github:NixOS/nixpkgs/8be7bd0c83f1#hello` → **成功, 21 秒** (含首次抓 flake) |
| root 系統 profile | **完全沒被動到** (59 個 bin 不變) |
| GC root | **自動註冊** → agent 裝的工具不會被 GC 掉 |
| **跨容器 daemon** | daemon 在 `hermes`, 從 **`hermes-dashboard` 以 uid 10000** 連上 → `Store URL: daemon` / `Trusted: 0`。**unix socket 放共用 volume 上可以跨容器連。** |
| `--profile` 是否留下逃逸 symlink | **不會** — 見下方「為什麼一定要用 wrapper」 |

關鍵結論: **multi-user nix 不是撤銷 2026-08-16 的決定, 是它的正確實作方式。**
系統 profile 仍然 root-only; agent 只能寫自己的層。

## 架構

```
opc-nix  (單一 volume, 取代現在四個)
  /nix/store                            ← 全部容器共用 (去重, 裝過不用重下載)
  /nix/var/nix/daemon-socket/socket     ← 一個 daemon 服務所有容器
  /nix/var/nix/profiles/
        per-user/root/profile           ← 系統層: 11 個 seed 工具, root only
        opc-agents/profile              ← agent 共用層: 誰裝大家都有

nix-daemon : 獨立 compose service, restart: unless-stopped, 掛 opc-nix
消費者     : buzz / frontdoor / hermes / hermes-dashboard / paperclip 都掛 opc-nix
             (不需要各自跑 daemon)
```

### PATH 順序 (image ENV)

```
<seed root profile>/bin : /nix/var/nix/profiles/opc-agents/bin : <既有> : /opt/mise/shims
```

**seed 在前**: agent 不能 shadow 系統工具。這保留了「不影響本體」的實質。
代價是 agent 重裝 seed 裡已有的 11 個工具會**沒有效果** —— 要換版本就是改 seed
清單 (`patches/nix-seed/Dockerfile`), 那本來就是系統級決定。此例外要寫進 skill,
否則會變成無聲的困惑。

自癒不會被騙: `nix-seed.sh` 的偵測是**直接檢查 root profile 的路徑**
(`[ ! -e "$PROFILE/bin/rg" ]`), 不是 `command -v`。

## 安裝介面: 必須走 wrapper

所有容器一致:

```sh
/usr/local/bin/nix-add   → nix profile add    --profile /nix/var/nix/profiles/opc-agents/profile "$@"
/usr/local/bin/nix-rm    → nix profile remove --profile /nix/var/nix/profiles/opc-agents/profile "$@"
/usr/local/bin/nix-list  → nix profile list   --profile /nix/var/nix/profiles/opc-agents/profile
```

### 為什麼一定要用 wrapper (而不是裸 `nix profile add`)

hermes-dashboard 的 Files page 對 frontdoor 的 home (`/opt/data`) 有一個真實地雷:

| 位置 | 內容 |
|---|---|
| `hermes_cli/web_server.py:2562-2567` | `GET /api/files` 用 **list comprehension** 逐一建 entry, **沒有 per-entry try/except** (只 catch `PermissionError`/`OSError`) |
| `:2425-2426` | 任何 entry `resolve()` 後不在 `locked_root` 底下 → `raise HTTPException(403)`, 會直接穿出整個請求 |
| `:2366-2368` | `_default_hermes_root_is_opt_data()` 為真 → `locked_root=/opt/data`。我們 dashboard 的 `HERMES_HOME=/opt/data` → **這條在我們的部署是啟用的** |
| `:2014-2016` | 跳過清單只有 `.env*` / `.envrc` + credential 目錄 — **`.nix-profile` 不在裡面** |
| `patches/buzz/opc-hermes-acp.sh:24` | `export HOME="${HERMES_HOME:-/opt/data}"` — agent 的 HOME 就是 `/opt/data` |

實測差異:

- **裸 `nix profile add`** → `~/.nix-profile` → `$HOME/.local/state/nix/profiles/profile`
  → `profile-N-link` → `/nix/store/...`。整條鏈 resolve 得出去 → **`/opt/data` 的
  Files listing 整個 403**。設 `XDG_STATE_HOME` 也擋不住 (symlink 改指 `/nix/...`,
  一樣逃逸)。
- **`nix profile add --profile <path>`** → `~/.nix-profile` 仍被建, 但指向
  **HOME 內尚未存在的** XDG 路徑, `Path.resolve()` 停在 HOME 裡面 → **不逃逸, 無 403**。

爆炸半徑界定 (比 AGENTS.md 的描述精確): 壞的只有 dashboard 的 **Files page**,
且只壞**含有該 symlink 的那一層目錄**。agent 本身 / chat / gateway / Logs page
不受影響。

**額外保險**: frontdoor entrypoint 開機檢查 `/opt/data/.nix-profile`, 若 resolve
到 `/opt/data` 之外就刪除 → 誤用最多壞到下次重啟, 不是永久。

## 權限

- 新增 group `nixagents`, **固定 gid 3000**, 每個 image 建立, runtime user 加入
  (跨 image 必須同 gid, 因為共用 volume 上比對的是數字)。
- `/nix/var/nix/profiles/opc-agents/` → `root:nixagents`, mode **2775** (setgid),
  由 daemon service 的 entrypoint 冪等建立。
- store 寫入全部由 daemon 以 root 執行 → store 仍是 root 所有, agent 碰不到。
- **不把 agent 加進 `trusted-users`** — 那會讓它能指定任意 substituter, 等於能往
  store 注入任何東西。代價只是警告訊息, 用下面的 conf 拆分解掉。

## nix.conf 拆兩份

現在 client 讀的 `/nix/etc/nix/nix.conf` 含 `sandbox = false`, 對非 trusted user
是 restricted setting → **每次 nix 呼叫都噴一行 warning**, 是 agent 的噪音。

- **client** (`NIX_USER_CONF_FILES`): 只留 `experimental-features = nix-command flakes`
- **daemon** (`/etc/nix/nix.conf`): `sandbox = false`、`experimental-features`、
  `max-jobs`、`trusted-users = root`

## build users

`nixbld1` → `nixbld1..nixbld8`。現在只有 1 個, 最多 1 個並行 build。多數安裝走
binary cache 不 build, 但真要 build 時會卡。

## 遷移 (破壞性, 需明確同意)

nix volume 的內容**本來就是可重建的** (image 內的 `/nix-seed`), 所以不需要
`down -v`:

```bash
docker compose down
docker volume rm opc_buzz-nix opc_frontdoor-nix opc_hermes-nix opc_paperclip-nix
docker compose up -d --build       # 新的單一 opc-nix 從 seed 重建
```

其他 volume (資料、home、mise) 全部保留。

## 要改的檔案

| 檔案 | 改什麼 |
|---|---|
| `patches/nix-seed/Dockerfile` | nix.conf 拆 client/daemon 兩份; build users 1→8 |
| `docker-compose.yml` | 新增 `nix-daemon` service; 四個 `*-nix` volume 併成 `opc-nix`; 五個消費者改掛 |
| `patches/{buzz,hermes,paperclip}/Dockerfile` | `nixagents` gid 3000 + runtime user 入組; PATH 加 `opc-agents/bin`; `nix-add`/`nix-rm`/`nix-list` wrapper |
| `patches/{buzz,hermes,paperclip}/nix-seed.sh` | 不再各自 seed volume (改由 daemon service 負責); 保留 self-heal; 冪等建立 `opc-agents` profile 目錄 |
| `patches/buzz/frontdoor-entrypoint` | 開機清除逃逸的 `/opt/data/.nix-profile` |
| `patches/{buzz,hermes}/SOUL.md` | 「裝工具用 `nix-add`, 不要 apt」(兩份必須逐字相同) |
| `patches/paperclip/skills/` | 同上, 給 omp agent |
| `AGENTS.md` | 更新不變量 3 (單一 volume + 兩層 profile + wrapper) |
| `docs/superpowers/specs/2026-08-16-container-toolchain-design.md` | 顯式註記 §6 被本設計修訂 |

## 風險

| 風險 | 嚴重度 | 處置 |
|---|---|---|
| 共用 profile 版本衝突 | **中** | `nix profile add` 會報 file conflict (例: A 裝 `nodejs_22`、B 要 `nodejs_20`)。寫進 skill: 衝突時用自己的 profile 或回報人類 |
| store 只增不減 | **中** | 需要維運出口 (`nix store gc`); GC 必須避開 `opc-agents` 的 gcroot |
| 跨容器 socket | **低** | 任何掛 `opc-nix` 的容器都能連 daemon。目前全是我們的容器 |
| agent 可裝任意軟體 | **低** | 不變量 6: 無 host mount、無 privileged → 爆炸半徑就是容器 |
| `sandbox = false` + 非 root 觸發 build | **低** | build script 以 `nixbld*` 跑, 不是 root |
| 單點故障 | **中** | daemon service 掛掉 → 所有容器都不能裝 (但已裝的照常用, 因為 PATH 指向 store 路徑) |

## 決策紀錄

- **單層共用 profile** (而非「共用層 + 個人層」兩層): 使用者明確選擇, 理由是概念
  最簡單 —— 一個地方、大家共用。已知代價是版本衝突與缺乏歸屬, 記於上表。
- **PATH 上 seed 在 agent 層之前**: 保留「agent 不能改系統工具」, 也讓自癒邏輯
  維持有效。

---

## 實作與驗收 (2026-08-20, 已上線)

遷移照計畫執行: `down` → 移除四個 `*-nix` volume → `up -d --build`。資料 / home /
mise / keys volume 全部保留, 未使用 `down -v`。

驗收結果:

| 驗證 | 結果 |
|---|---|
| 14 個服務啟動, `nix-daemon` healthy | PASS |
| `scripts/test-connectivity.sh` | **23 pass / 0 fail** |
| 共用 profile 目錄權限 | `drwxrwsr-x root:nixagents` (setgid) |
| client nix.conf | 只有 `experimental-features` — **安裝時不再有 restricted-setting 警告** |
| paperclip agent (`gosu node`) 安裝 | `groups=1000(node),3000(nixagents)`, `nix-add nixpkgs#hello` 成功 |
| hermes agent (`s6-setuidgid hermes`) 安裝 | `groups=10000(hermes),3000(nixagents)`, `nix-add nixpkgs#cowsay` 成功 |
| frontdoor agent (`setpriv --groups 3000`) | 取得 gid 3000, 讀得到共用 profile |
| **跨容器可見性** | paperclip 裝的 `hello` → hermes / frontdoor / buzz / hermes-dashboard **全部可用**; hermes 裝的 `cowsay` 同理; `nix-rm` 也同步生效 |
| 系統 11 工具未被 shadow | `rg jq fd bat just mise gh` 全部解析到 `per-user/root` |
| dashboard managed-root 守衛 | `/opt/data` 41 個 entry, **無逃逸項** → Files page 不會 403 |
| frontdoor `.nix-profile` | `-> /opt/data/.local/state/nix/profiles/profile` (**留在 HOME 內**), 重啟後開機清除邏輯正確地未誤刪 |

### 實作中發現並一併修掉的既有問題

**login shell 會丟掉 nix PATH。** `/etc/profile` 重新推導 PATH, 蓋掉 image ENV。
這是**既有**缺陷 —— 在本次改動之前, `bash -lc 'jq --version'` 在 hermes 就已經
失敗 (`jq=LOST gh=LOST mise=LOST nix=LOST`), 只是沒人踩到。它會讓 `nix-add` 也
一起消失, 症狀是「明明裝了卻找不到」。修法是每個 image 加一份
`/etc/profile.d/opc-nix.sh` 冪等補回同一組路徑。修後四個容器 login shell 皆
`rg/jq/gh/mise/nix/nix-add` 全數 ok。

### 與設計的差異

無。設計階段預測的兩件事都被實測確認: `--profile` 不會產生逃逸 symlink, 以及
單一 daemon 可跨容器服務。
