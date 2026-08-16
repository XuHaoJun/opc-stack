# 容器 toolchain 設計: 共享 nix-seed + mise (node/rust)

日期: 2026-08-16
狀態: 待審核

## 1. 背景與問題

`docker compose up -d --build` 每次都很久。量測結果 (2026-08-16):

- 完全不動 context 時 `docker compose build buzz` 全 CACHED, 3.7 秒 — 無系統性 cache 失效。
- 在 `patches/buzz/opc-gh-seed.sh` 加一行註解 → prepare → build → **3分16秒** (196s)。
- 原因: 三個 Dockerfile (buzz/hermes/paperclip) 的 nix install RUN (各 1.02–1.45GB layer) 都排在 `COPY opc/*.sh` 之後; 任何 patch script 內容變動 → nix 整層 invalidate → 每 image 重跑完整 nix install (installer + nixpkgs eval + 工具下載)。
- nix install 在三個 image 各跑一次 (base image 不同 → layer cache 無法共享)。
- nix 版本與 nixpkgs 皆未 pin (每次重跑抓最新)。
- `cp -a /nix /nix-seed` 讓 nix 內容在 layer 內 double (seed 是完整複製, 非 hardlink)。

現況 toolchain (2026-08-16 量測):

| | nix profile (volume) | node (baked) | rust | mise |
|---|---|---|---|---|
| buzz | rg/jq/fd/htop/bat + nix 2.35.2 | 無 | 無 | 無 |
| frontdoor | 同 buzz | v22.23.2 | 無 | 無 |
| hermes | 同 buzz | v26.5.1 | 無 | 無 |
| paperclip | 同 buzz + **omp 17.3.4** (llm-agents.nix) | v24.19.0 | 無 | 無 |

使用者常用 tech stack: nodejs + rust。期望: 容器內有 mise 管理的 node@lts + rust stable (rustup), 外加 just (make 替代)。

## 2. 目標 / 非目標

### 目標
1. patch script 編輯 → rebuild 秒級 (不再觸發 nix reinstall)。
2. seed 工具清單變更 → 只重裝 1 次 (不是 3×)。
3. 容器內 (全部 4 個) 有 mise 管理的 toolchain: `node@lts` global + `rust@stable` global (rustup backend), 空狀態自動 bootstrap。
4. 容器內有 `just`。
5. nix 版本 + nixpkgs pin, 可重現。
6. **不影響 hermes/paperclip 本體** — daemon 保留 baked node, 行為不變。

### 非目標
- 不把 nix 換成 mise (並存: nix 管 CLI 工具, mise 管 node/rust toolchain)。
- 不遷移既有 volume 內容 (seed 只作用於空 volume; 既有工具用 self-heal 補齊, 見 §5)。
- 不處理 host 端 mise。
- 不處理 cargo target cache mount (A') — 後續可選優化。

## 3. 設計總覽

```
patches/nix-seed/Dockerfile  ──build──►  opc/nix-seed:local  (含 /nix-seed, 9 工具, cp -al)
                                              │ COPY --from (3 個 service Dockerfile)
                                              ▼
        buzz / hermes / paperclip Dockerfile ──► /nix-seed (layer, 秒級)

mise:  binary 從 nix seed 來 (nixpkgs#mise)
       data 在 per-container volume  (*-mise:/opt/mise)
       bootstrap 由新 script opc-mise-seed.sh (entrypoint source) 空狀態自動裝:
         node@lts + rust@stable (mise use -g)
       PATH 尾掛 shims → baked node 不受影響 (hermes 26 / paperclip 24 照舊)
```

## 4. 元件詳述

### 4.1 `patches/nix-seed/Dockerfile` (新)

唯一 nix install 處。產出: `/nix-seed` (nix 2.35.2 + 9 工具)。

```
FROM debian:bookworm-slim
# apt: ca-certificates curl xz-utils
# nix.conf: experimental-features = nix-command flakes / sandbox = false / accept-flake-config = true
# nix 2.35.2 pin: https://releases.nixos.org/nix/nix-2.35.2/install (--no-daemon)
# profile install (pin nixpkgs + omp rev):
#   github:NixOS/nixpkgs/8be7bd0c83f1#ripgrep jq fd htop bat just mise gh
#   github:numtide/llm-agents.nix/dac632fe2759854b901cbab78efdeca6343a6c0e#omp
# cp -al /nix /nix-seed        ← hardlink, layer 資料只存一份
```

- 9 工具: ripgrep, jq, fd, htop, bat, **just**, **mise**, **gh** (nixpkgs) + **omp** (llm-agents.nix)。
- nixpkgs pin `8be7bd0c83f1` = 現有 volume 的 locked snapshot (`nixpkgs-26.11pre1054271.8be7bd0c83f1`), 版本與現況一致。
- nix 2.35.2 = 現有 volume 的版本。
- build context = `./patches/nix-seed` (不經過 prepare.sh; 第一個不屬 submodule 的 build context)。

### 4.2 compose 變更

```yaml
  nix-seed:
    build:
      context: ./patches/nix-seed
      dockerfile: Dockerfile
    image: ${IMAGE_PREFIX:-opc}/nix-seed:local
    restart: "no"
    command: ["true"]          # one-shot, 仿 buzz-keys 模式

  # buzz / buzz-keys / frontdoor / hermes / paperclip 各加:
  build:
    depends_on: [nix-seed]     # 保證 seed image 先 build (compose 5.4 支援)
```

- `build.depends_on` 加在**所有**會 build 出引用 seed 之 image 的 service: buzz, buzz-keys, frontdoor, hermes, paperclip (frontdoor/buzz-keys 與 buzz 同 context)。
- mise volume 掛載 (4 個): `buzz-mise:/opt/mise`, `frontdoor-mise:/opt/mise`, `hermes-mise:/opt/mise`, `paperclip-mise:/opt/mise`。
- volume 宣告: `buzz-mise`, `frontdoor-mise`, `hermes-mise`, `paperclip-mise` (空, named volume)。

### 4.3 service Dockerfile 變更 (buzz / hermes / paperclip)

- 1.02–1.45GB 的 nix RUN 區塊換成:
  ```dockerfile
  ARG NIX_SEED_IMAGE=opc/nix-seed:local   # compose 傳 ${IMAGE_PREFIX:-opc}/nix-seed:local
  COPY --from=${NIX_SEED_IMAGE} /nix-seed /nix-seed
  ```
- 保留: nixbld group/user (`groupadd nixbld` + `nixbld1`)、nix ENV block (PATH/NIX_PROFILES/NIX_USER_CONF_FILES/NIX_SSL_CERT_FILE)。
- 新增 mise ENV:
  ```dockerfile
  ENV MISE_DATA_DIR=/opt/mise MISE_CACHE_DIR=/opt/mise/cache MISE_CONFIG_DIR=/opt/mise/config
  ```
- 新增 `COPY opc/mise-seed.sh /usr/local/bin/opc-mise-seed.sh` + chmod。
- frontdoor (opc-frontdoor target) 繼承 opc-relay, 自動拿到。

### 4.4 `opc-mise-seed.sh` (新, 每 project 一份: patches/{buzz,hermes,paperclip}/)

```sh
opc_mise_seed() {
    export MISE_DATA_DIR="${MISE_DATA_DIR:-/opt/mise}"
    export MISE_CACHE_DIR="${MISE_CACHE_DIR:-/opt/mise/cache}"
    export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/opt/mise/config}"
    # 空狀態偵測: 個別 toolchain 缺才裝 (mise use -g 會自動下載)
    if [ ! -d "$MISE_DATA_DIR/installs/node" ]; then
        echo "[mise] first boot: installing node@lts (global)"
        mise use -g node@lts || echo "[mise] node install failed (network?)"
    fi
    if [ ! -d "$MISE_DATA_DIR/installs/rust" ]; then
        echo "[mise] first boot: installing rust@stable (global, rustup)"
        mise use -g rust@stable || echo "[mise] rust install failed (network?)"
    fi
    # PATH 尾: baked node 優先 (hermes 26 / paperclip 24 不變); mise 補缺 (cargo/rustc, buzz 的 node)
    export PATH="$PATH:$MISE_DATA_DIR/shims"
}
```

- 個別偵測 → node 裝成功、rust 失敗時, 下次開機只重試 rust。
- PATH 尾是「不影響 hermes/paperclip 本體」的關鍵決策 (§3 決策點, 已確認)。

### 4.5 entrypoint 整合 (4 個)

`opc_nix_seed` 之後加:

```sh
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed
```

- `patches/buzz/buzz-entrypoint.sh`
- `patches/buzz/frontdoor-entrypoint.sh`
- `patches/hermes/hermes-entrypoint.sh`
- `patches/paperclip/nix-entrypoint.sh` (exec "$@" → upstream docker-entrypoint → gosu node, env 帶過去)

### 4.6 `opc-nix-seed.sh` self-heal 擴充 (既有 volume 拿到新工具)

現有 self-heal 只檢查 `rg` 並重加 5 工具。擴充: 檢查 `rg`/`mise`/`just`/`gh`/`omp`, 缺任一 → 重加完整 9 工具清單 (含 `github:numtide/llm-agents.nix#omp`)。

- 必要: 既有 volume 沒有 mise binary 的話, `opc_mise_seed` 的 `mise use -g` 會失敗。
- 既有行為保持 unpinned nixpkgs (已知 tradeoff, 不在此設計修正)。

### 4.7 gh CLI + ssh/gh config 同步 (調查結論)

**現況: config 同步機制已完整存在, 唯一缺口是 gh binary。**
- 三個 project 的 `opc-gh-seed.sh` 完全相同 (env-based): `GIT_SSH_COMMAND=ssh -F /creds/ssh/config -o StrictHostKeyChecking=accept-new`、`GIT_CONFIG_GLOBAL=/creds/git/config`、`GH_CONFIG_DIR=/creds/gh` — 已 source 於 4 個 entrypoint。
- compose 已 mount `opc-gh-creds:/creds` 於 frontdoor(:203)/hermes(:257)/paperclip(:296); buzz 無 (relay 不需要, gh-seed 偵測無 /creds 自動停用)。
- host 端 `scripts/sync-gh-creds.sh` 鏡像 `~/.ssh` + `~/.config/gh` + `~/.gitconfig` 進 volume (IdentityFile 路徑重寫為 /creds/ssh/…), 冪等。
- 實測 (2026-08-16): 三容器 /creds 內容一致 (ssh: id_ed25519/known_hosts/config; gh: hosts.yml/config.yml; git: config)。
- **gh binary: 只有 paperclip 有 (apt 2.46.0)**; hermes/buzz/frontdoor 沒有 → 加入 nix seed (nixpkgs#gh) 後全部容器取得。
- 已知限制 (既有行為, 不在此設計修正): GH_CONFIG_DIR 等 env 是 entrypoint runtime export — daemon 有 (s6/gosu 帶過去), `docker exec` 互動 session 不會繼承 (除非 shell 自己 source)。

## 5. 行為語意

| 情境 | 行為 |
|---|---|
| 全新機器 / `down -v` 後 | nix-seed image build (一次 install) → 3 service COPY layer → 首次開機: nix volume seed + mise 裝 node@lts + rust@stable (~300MB 下載, 4 容器各自進行) |
| 既有 volume, image 升級 | nix volume 已存在 → seed 不重跑; self-heal 補 just/mise/gh/omp; mise volume 已存在 → 不重裝 |
| patch script 編輯 | `COPY opc/*.sh` invalidate → nix 不再陪葬 (COPY --from 是獨立 layer); cargo 重編照舊 (~1-2min) |
| seed 工具清單變更 | 只重裝 nix-seed image 1 次, 3 service 只是 COPY layer |
| docker exec 加工具 | 照舊: `nix profile add` / `mise install` (root 可寫 /opt/mise) |

## 6. 權限與安全性

- `/opt/mise` root 擁有、目錄 755; daemon 用戶 (hermes uid 10000、node uid 1000) 可讀可執行, 不可寫 → daemon 無法改 toolchain, 符合「不影響本體」。
- docker exec 預設 root → 可 `mise install` 新版本。
- 維持既有隔離不變量: 無 host mount、無 privileged。
- nix/rustup/mise 下載皆走 HTTPS (releases.nixos.org / cache.nixos.org / static.rust-lang.org / mise 後端)。

## 7. 驗證計畫

1. `docker compose build nix-seed` → 確認 `/nix-seed` 內容 (9 工具 + nix 2.35.2), `du` 確認 hardlink 生效 (seed 不 double 資料量)。
2. 改一個 patch script → `docker compose build buzz` 不再出現 nix install (殘餘時間 = cargo local crates 重編, ~1-2min, 比 196s 顯著下降)。
3. 全新 volume 冒煙測 (暫時移除 volume 或新 volume 名): 各容器開機後:
   - `mise --version` (nix profile 提供)
   - `mise ls` → node@lts + rust@stable global
   - `node -v` (buzz = LTS; hermes 仍 26.5.1; paperclip 仍 24.19.0 — daemon 不變)
   - `rustc --version` / `cargo --version` = stable
   - `just --version`
   - `gh --version` (全部容器都有; hermes 原本沒有)
   - `omp --version` (全部容器都有)
4. gh/ssh config 生效 (hermes/frontdoor/paperclip): 在 daemon env 下 `gh auth status` (GH_CONFIG_DIR=/creds/gh) + `ssh -T -F /creds/ssh/config git@github.com` 成功。
5. hermes/paperclip healthcheck 通過; buzz relay `_readiness` 200。
6. 既有 volume 升級: self-heal 補 just/mise/gh/omp, daemon 無感重啟。

## 8. 風險與緩解

| 風險 | 緩解 |
|---|---|
| `nixpkgs/8be7bd0c83f1` 無 `mise` 套件 | build 時會立即失敗; fallback: 改用相近較新 commit (版本可能與現況略異, 需重驗) |
| `COPY --from=<image>` 在全新機器 build 順序 | `build.depends_on` (compose 5.4 支援); 驗證: 清空 image 後從零 build |
| bookworm 建的 seed 拷進 trixie 基底 (hermes/paperclip) | nix static binary 自含; store 工具自帶 glibc; 驗證: 各容器實跑工具 |
| 首次開機 4 容器平行下載 rust (~300MB × 4) | `down -v` 罕見; 開機時間可接受; 失敗有 per-tool 重試 |
| self-heal unpinned nixpkgs 造成版本漂移 | 既有行為, 不在此設計修正; 記錄於 spec |
| mise 版本行為差異 (`use -g` 語法) | 實作時以 seed build + 冒煙測驗證; 若 `rust@stable` 語法不適用, 改用 `rustup toolchain install stable` + `mise use -g rust@stable` |

## 9. Rollback

- 全部變更在 `patches/` + `docker-compose.yml` (version controlled); revert commit → `scripts/prepare.sh` → `docker compose up -d --build`。
- 既有 volume 不受影響 (seed 只作用於空 volume); self-heal 只加工具不刪。
- 若有 volume 需重建: `docker compose down` + 移除對應 `*-mise` volume 即可重跑 bootstrap。

## 10. 驗證順序 (實作後)

1. spec self-review (本文件)
2. 實作: patches/nix-seed → compose → 3 Dockerfiles → mise-seed.sh → entrypoints → self-heal
3. 驗證計畫 (§7) 全數通過
4. AGENTS.md / SETUP.md 更新 (nix-seed 新 build context、mise volume、`docker compose up -d --build` 流程不變)

## 11. Rollout: 執行中 stack 的無縫接軌 (調查結論 2026-08-16)

三個 scout 調查 (hermes / paperclip / compose 機制, 詳見 `agent://HermesShutdownResume`、`agent://PaperclipShutdownResume`、`agent://ComposeRedeployMechanics`)。

### 11.1 Redeploy 機制

- `docker compose up -d --build`: build 後比對 image digest, 變更的才 recreate (stop→remove→create→start)。無 build 的 backing infra (buzz-db/redis/minio) **全程不中斷**。
- 全 repo 無 `stop_grace_period` → 全部容器 10s SIGTERM grace (docker 預設)。
- recreate 順序 = depends_on DAG (buzz chain 5 層序列化; hermes/paperclip/tencentdb 平行)。單容器 downtime ≈ 10s grace + recreate; 典型總體 ~30-60s。
- 所有資料在 named volumes (`opc_hermes-data`, `opc_paperclip-data`, `opc_*-nix` 等) — recreate 不丟資料。paperclip 的 DB 是 **embedded postgres** (`/paperclip/instances/default/db`), 也在 volume 上。

### 11.2 Hermes — graceful shutdown + auto-resume: YES

- in-flight 工作 = `$HERMES_HOME/sessions/sessions.json` (含 active_turn_token, 精確標記進行中 turn) + `state.db` (SQLite, per-turn transcript, WAL)。
- SIGTERM → s6 (shutdownd -g 3000) → gateway handler → **先 pre-mark resume_pending 再 drain** (marker 先寫, SIGKILL 也安全) → interrupt tool subprocess → clean exit。
- 重啟: `_recover_unclean_sessions` (active_turn_token ≤1h) + `_schedule_resume_pending_sessions` → 同 session_id 合成 continuation turn, model 收到 "[System note: previous turn was interrupted...]" 續跑。
- `--replace` = stale-lock takeover, 新容器乾淨接管舊 gateway。
- cron in-flight runs: shutdown 時標 interrupted, **不 requeue** — 依 schedule 下個 tick。
- 10s grace 內 drain 用 restart_drain_timeout=0 (立即 interrupt); 即使 SIGKILL, pre-drain marker 保證 resume。

### 11.3 Paperclip — graceful shutdown + auto-resume: YES

- SIGTERM → tini (init:true) → node server → `drainRunningRunsForShutdown` (heartbeat.ts:9040): 終止 adapter child (SIGTERM→SIGKILL), run 標 `interrupted` (`server_shutdown_interrupted`), **queue retry** (`enqueueProcessLossRetry`), 停 embedded postgres, exit 0。
- 重啟: `reapOrphanedRuns` (stuck running → failed/process_lost, `processLossRetryCount<1` 且 tracked-local-child → retry 一次) + `resumeQueuedRuns` → **auto-resume YES** (從 persisted session 重新執行, 非同一 process)。
- 5-min periodic reaper 為 backstop。
- 調查當下有一個 live run (`[acpx] spawning agent: omp acp --yolo` 15:45) — redeploy 時會被 interrupt + retry, 不遺失。

### 11.4 One-shots recreate 重跑

- buzz-keys / buzz-bootstrap / tencentdb-bootstrap: **idempotent, 安全** (verified; DB 層 ON CONFLICT DO NOTHING / 檔案存在即 skip / 409 accepted)。
- paperclip-bootstrap: 上次 **Exited(1)** — `[pc-bootstrap] bootstrap/claim failed: HTTP 403` (舊 image 行為)。**已修復**: commit `7a32927` (skip claim when admin exists) 在 patches 中, 尚未部署; key 檔案已存在 (`/keys/paperclip-api.key` 在 opc-keys volume, 已確認) 且無 service depends_on 它 → **benign**; redeploy 後以修復版重跑, 預期 exit 0。

### 11.5 Wedge 風險 (既有, 非本變更引入)

- buzz chain: buzz healthcheck 失敗 (~10min worst) → buzz-bootstrap/frontdoor 不啟動, `up -d` 阻塞。
- tencentdb-core image-level HEALTHCHECK → 3 個 dependent 阻塞。
- 無 circular dependency; hermes 完全獨立。

### 11.6 本變更對 rollout 的影響

- 新增 `nix-seed` one-shot (command: true) — 無害。
- 既有 nix volume: seed 不重跑 (非空), self-heal 補 just/mise/gh/omp。
- 新 `*-mise` volumes: 空 → 首次開機各容器裝 node@lts + rust@stable (~1-3 min/容器, 平行) — daemon 不受影響 (PATH 尾)。
- 結論: **可以在執行中 stack 直接 redeploy**; hermes/paperclip 的 in-flight 工作會被優雅中斷並自動續跑, 資料零遺失。
