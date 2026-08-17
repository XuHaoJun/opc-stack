# Host Config Sync — Design Spec

日期: 2026-08-17
狀態: approved (user, 設計討論後)

## 背景

`opc-gh-creds` volume 存放 host 鏡像過來的 GitHub credential (`~/.ssh`、`~/.config/gh`、`~/.gitconfig`), 由 compose one-shot `gh-creds-sync` 在每次 `up` 自動同步 (修復 `down -v` 後空 volume 導致 git push 失敗)。現行實作把「copy host 檔案進 named volume」這個通用需求寫死成 gh-creds: worker script 名稱、compose service 名稱、轉換邏輯全部綁 gh。

需求: 把機制抽象成「需要 copy host 資源的服務/script」, gh-creds 降為第一個使用案例。

## 目標

1. 通用 engine: 任何「host path → named volume」鏡像, 宣告式加 source 即可, engine 不改。
2. per-source 轉換可插拔 (hooks), gh 專屬邏輯 (ssh config 重寫、gitconfig 抽取、known_hosts) 搬出 engine。
3. 通用 host CLI + gh 場景薄 wrapper; compose one-shot 用通用名。
4. 行為不變: `up` 自動同步、冪等、缺 host source 大聲失敗、host cred 變更後手動重同步。

## 非目標

- 不 rename `opc-gh-creds` volume (內容就是 gh creds; 機制泛化不泛化資料名)。
- 不預先 wire 未來 use-case (YAGNI; 機制就緒即可)。
- 不改消費者 (`/creds` mount point、`opc-gh-seed.sh` env contract) — 對 paperclip/hermes/frontdoor/dashboard 完全透明。
- 不把 host 端 `ssh-keyscan` 搬進容器 (compose path 靠 host known_hosts 已含 github.com; 手動 path 才 keyscan)。

## 架構

```
scripts/
  host-sync-worker.sh   通用 engine (container-side, 唯一邏輯)
  host-sync.sh          通用 host CLI (組 binds → docker run worker)
  sync-gh-creds.sh      gh 場景薄 wrapper (參數組 + host 端 keyscan)
  hooks/
    ssh.sh              per-source 轉換: IdentityFile 重寫 / known_hosts / chmod
    gitconfig.sh        per-source 轉換: [user] 抽取 + defaultBranch
compose service: host-sync (取代 gh-creds-sync; 4 消費者 depends_on 同步改名)
```

### Worker contract (`host-sync-worker.sh`)

- env `HOST_SYNC_SOURCES` = space-separated source names (e.g. `ssh gh gitconfig`)。
- 對每個 name N (依序):
  1. `rm -rf /dst/N; mkdir -p /dst/N`
  2. `[ -d /src/N ]` → `cp -a /src/N/. /dst/N/`; `[ -f /src/N ]` → `cp -a /src/N /dst/N`
  3. `/hooks/N.sh` 存在 → 執行 (stdin 傳遞)
- 冪等: 每次全量重鏡像。exit 非零 = 同步失敗。

### Hooks

- `hooks/ssh.sh`: 現行 worker ssh block 原樣搬移 — `sed -i` IdentityFile 路徑重寫 (`~/.ssh/x` → `/creds/ssh/x`), config 無 IdentityFile 時補 github.com block, known_hosts 缺 github.com 時 append stdin (keyscan), 補 `UserKnownHostsFile`, chmod 700/600/644。
- `hooks/gitconfig.sh`: 現行 git block 原樣搬移 — `[user]` name/email 抽取 + `[init] defaultBranch = main`, 缺 name 時 WARN。
- `gh` 無 hook (純 copy)。
- 掛載: `/hooks/<name>.sh:ro`; worker 檢查存在才跑。

### 通用 CLI (`host-sync.sh`)

```
host-sync.sh --volume <compose-key> \
             --src <name>=<hostpath>... \
             [--hook <name>=<script>...]
```

- Worker 的寫入 target 固定 `/dst` — CLI 把 volume 掛在 `/dst` (throwaway 容器內部), 消費者掛 volume 的位置 (`/creds`) 由消費者自己決定, 與此無關。
- stdin 直接穿透給容器 (wrapper 把 `ssh-keyscan github.com` pipe 進來; ssh hook 在 known_hosts 缺 github.com 時才讀)。CLI 偵測 TTY 時餵 `/dev/null`, 避免 hook 的 `cat` 卡在互動輸入。
- `--volume` 用 compose 解析 project prefix (沿用現行 `opc_opc-gh-creds` 解析邏輯)。
- 組 binds: `volume:target`、各 `hostpath:/src/<name>:ro`、各 hook `script:/hooks/<name>.sh:ro`、worker `/worker.sh:ro`。
- `docker run --rm -i alpine:3.20 sh /worker.sh`; `--stdin <name>` 時把該 hook 的 stdin 餵給容器 (keyscan 用途 — worker 原樣轉交, 只有對應 hook 讀)。
- host 側: 缺 `--src` host path → WARN + 繼續同步其餘 + 最後 exit 非零 (沿用現語意)。

### gh wrapper (`sync-gh-creds.sh`)

薄參數組呼叫 `host-sync.sh`:

```
ssh-keyscan github.com | host-sync.sh --volume opc-gh-creds \
  --src ssh=$HOME/.ssh --src gh=$HOME/.config/gh --src gitconfig=$HOME/.gitconfig \
  --hook ssh=scripts/hooks/ssh.sh --hook gitconfig=scripts/hooks/gitconfig.sh
```

(keyscan `ssh-keyscan github.com` 在 wrapper 側產生, pipe 進 CLI 走 stdin 穿透。) 保留手動重同步語義與錯誤訊息。

### Compose (`host-sync` service)

```yaml
  host-sync:
    image: alpine:3.20
    restart: "no"
    entrypoint: ["sh", "/worker.sh"]
    environment:
      HOST_SYNC_SOURCES: "ssh gh gitconfig"
    volumes:
      - opc-gh-creds:/dst
      - ${HOME}/.ssh:/src/ssh:ro
      - ${HOME}/.config/gh:/src/gh:ro
      - ${HOME}/.gitconfig:/src/gitconfig:ro
      - ./scripts/host-sync-worker.sh:/worker.sh:ro
      - ./scripts/hooks/ssh.sh:/hooks/ssh.sh:ro
      - ./scripts/hooks/gitconfig.sh:/hooks/gitconfig.sh:ro
```

- 內部 target `/dst` 只是 worker 暫存; 消費者照舊掛 `opc-gh-creds:/creds`, 零改動。
- `frontdoor` / `hermes` / `hermes-dashboard` / `paperclip` 的 `depends_on: gh-creds-sync` → `host-sync`。
- 缺 host source → bind 失敗 → `up` 大聲失敗 (不變)。

## 未來 use-case 擴充 (機制能力展示, 不實作)

新需求 (e.g. copy `~/.aws` 進 volume 給 agent): 寫一個 `hooks/aws.sh` (或純 copy 連 hook 都不用) → compose 加一個 service 宣告 (static binds 是 compose 本質限制, 一個 use-case 一個 service) → `depends_on` 接上。engine/CLI 零改動。

## 錯誤處理

| 情境 | 行為 |
|---|---|
| host 缺 source (compose path) | bind 失敗, `up` 大聲失敗 |
| host 缺 source (CLI path) | WARN + 同步其餘 + exit 非零 |
| known_hosts 缺 github.com | append stdin keyscan (手動 path); compose path 靠 host known_hosts 既有 entry |
| `.gitconfig` 無 `[user] name` | WARN (容器內 git 需手動設身份) |

## 驗證計畫

1. `docker compose config` → `host-sync` service 正確渲染 (HOME 展開、4 消費者 depends_on 指向 `host-sync`)。
2. 空 volume 測試: temp volume + 通用 CLI (`host-sync.sh`) 全參數組跑 → exit 0, `/dst/ssh|gh|gitconfig` 內容正確 (IdentityFile 重寫、UserKnownHostsFile、known_hosts 3 key、git config name/email/defaultBranch)。
3. `scripts/sync-gh-creds.sh` (wrapper) → exit 0, 冪等重跑。
4. `docker compose up -d --force-recreate <4 消費者>` → 全 healthy, one-shot exit 0。
5. 容器內: `gh auth status` ✓、`ssh -T git@github.com` ✓、`git ls-remote` ✓。
6. `git status` clean (除 spec/實作檔)。
