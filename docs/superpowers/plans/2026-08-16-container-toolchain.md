# 容器 toolchain (nix-seed + mise + gh) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 nix install 抽成共享 seed image (build 秒級), 並在 4 個容器內提供 mise 管理的 node@lts + rust stable, 以及 gh/just CLI。

**Architecture:** `patches/nix-seed/Dockerfile` 是唯一 nix install 處 (pin nix 2.35.2 + nixpkgs 8be7bd0c83f1 + 8 工具, `cp -al` hardlink seed); buzz/hermes/paperclip 三 Dockerfile 的 1.02–1.45GB nix RUN 換成 `COPY --from=opc/nix-seed:local /nix-seed /nix-seed (stage alias, 見 Task 3)」mise binary 從 nix profile 來, toolchain data 在 per-container `*-mise:/opt/mise` volume, entrypoint source 的 `opc-mise-seed.sh` 空狀態自動 `mise use -g node@lts` + `rust@stable`。PATH 尾掛 mise shims → hermes/paperclip 的 baked node 不受影響。

**Tech Stack:** Docker multi-stage, docker compose 5.x (service-level depends_on (nix-seed: condition service_completed_successfully)), nix 2.35.2, mise (node/rustup backend), shell (POSIX sh entrypoints)。

## Global Constraints

- 版本 pin: nix `2.35.2`、nixpkgs commit `8be7bd0c83f1`、omp flake rev `dac632fe2759854b901cbab78efdeca6343a6c0e` (spec §4.1)。
- PATH 尾掛 mise shims (`PATH="$PATH:.../shims"`) — **不可**放頭; hermes (node 26) / paperclip (node 24) daemon 的 baked node 必須保持優先 (spec §3 決策, 已確認)。
- seed 複製用 `cp -al` (hardlink), 不可改回 `cp -a` (layer 資料只存一份)。
- 尊重 `IMAGE_PREFIX`: compose build args 傳 `NIX_SEED_IMAGE=${IMAGE_PREFIX:-opc}/nix-seed:local`, Dockerfile ARG default `opc/nix-seed:local`。
- 改 `patches/<proj>/` 後 build 前必跑 `scripts/prepare.sh` (冪等, rsync 進 upstream/<proj>/opc/)。
- 不影響 hermes/paperclip 本體: 不刪 baked node、不改 CMD/ENTRYPOINT 鏈、不動 service 環境變數除新增 MISE_*。
- 既有 volume 不遷移內容; 新工具靠 self-heal (spec §4.6) 補齊, 不動已有 profile 內容。
- 所有 bash/sh 腳本 POSIX sh, entrypoint 內不可用 bashism。

---

### Task 1: nix-seed 共享 image

**Files:**
- Create: `patches/nix-seed/Dockerfile`

**Interfaces:**
- Produces: image `opc/nix-seed:local`, 內含 `/nix-seed` (nix 2.35.2 + ripgrep/jq/fd/htop/bat/just/mise/gh/omp, hardlink 一份資料)。Task 3-5 的 `COPY --from=opc/nix-seed:local /nix-seed /nix-seed` 依賴此 image 存在。

- [ ] **Step 1: Create the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7
#
# OPC shared nix seed — the ONE place nix gets installed. Produces
# /nix-seed (nix 2.35.2 + 8 pinned tools) which the buzz/hermes/paperclip
# images COPY in. Tool-list changes rebuild ONLY this image; service images
# just re-COPY the layer (seconds).
#
# omp is NOT here — its bun2nix derivation fails to build in image builds
# (bun isolated-linker EPERM, 334 packages; llm-agents.nix at any rev).
# omp ships via mise: `mise use -g github:can1357/oh-my-pi@17.3.5` (prebuilt
# GitHub release, ~170MB) in opc-mise-seed.sh.
#
# Build via compose service `nix-seed` (context ./patches/nix-seed) or:
#   docker build -t opc/nix-seed:local -f patches/nix-seed/Dockerfile patches/nix-seed

FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl xz-utils \
    && rm -rf /var/lib/apt/lists/*

# nix 2.35.2 — pinned installer URL for reproducible builds.
# nix.conf is written to THREE locations: single-user nix reads
# ~/.config/nix/nix.conf and /etc/nix/nix.conf (NOT /nix/etc/nix/nix.conf —
# that one is only for the runtime volume seed via NIX_USER_CONF_FILES).
RUN groupadd -r nixbld \
    && useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin nixbld1 \
    && gpasswd -a nixbld1 nixbld \
    && mkdir -m 0755 /nix \
    && HOME=/root sh -c 'curl -fsSL https://releases.nixos.org/nix/nix-2.35.2/install -o /tmp/nix-install.sh \
        && sh /tmp/nix-install.sh --no-daemon --yes \
        && rm -f /tmp/nix-install.sh' \
    && mkdir -p /nix/etc/nix /etc/nix /root/.config/nix \
    && printf 'experimental-features = nix-command flakes\nsandbox = false\naccept-flake-config = true\n' | tee /nix/etc/nix/nix.conf /etc/nix/nix.conf /root/.config/nix/nix.conf >/dev/null \
    && HOME=/root PATH="/nix/var/nix/profiles/default/bin:$PATH" \
        nix --extra-experimental-features 'nix-command flakes' \
        profile install --profile /nix/var/nix/profiles/per-user/root/profile \
        github:NixOS/nixpkgs/8be7bd0c83f1#ripgrep \
        github:NixOS/nixpkgs/8be7bd0c83f1#jq \
        github:NixOS/nixpkgs/8be7bd0c83f1#fd \
        github:NixOS/nixpkgs/8be7bd0c83f1#htop \
        github:NixOS/nixpkgs/8be7bd0c83f1#bat \
        github:NixOS/nixpkgs/8be7bd0c83f1#just \
        github:NixOS/nixpkgs/8be7bd0c83f1#mise \
        github:NixOS/nixpkgs/8be7bd0c83f1#gh \
    && cp -al /nix /nix-seed

CMD ["true"]
```

- [ ] **Step 2: Build it**

Run: `docker build -t opc/nix-seed:local -f patches/nix-seed/Dockerfile patches/nix-seed`
Expected: build succeeds. If `github:NixOS/nixpkgs/8be7bd0c83f1#mise` (or `#gh`) errors with "attribute not found", that commit lacks the package → fall back per spec §8: bump nixpkgs to the newest commit in `https://releases.nixos.org/nixpkgs/` that still satisfies the other 7 (record the new commit in this file and the spec).

- [ ] **Step 3: Verify /nix-seed contents + hardlink**

Run:
```bash
CID=$(docker run -d opc/nix-seed:local true)
docker exec "$CID" sh -c '
  P=/nix/var/nix/profiles/per-user/root/profile/bin
  for t in nix rg jq fd htop bat just mise gh; do
    [ -x "$P/$t" ] || { echo "MISSING $t"; exit 1; }
  done
  echo "all 9 binaries present"
  "$P/nix" --version
'
# hardlink check: file-level inode sharing between /nix/store and /nix-seed/store
# (dirs are recreated by cp -al, so compare a FILE's inode, not the dir's)
docker exec "$CID" sh -c '
  S=$(ls /nix/store | head -1)
  [ "$(stat -c %i "/nix/store/$S")" = "$(stat -c %i "/nix-seed/store/$S")" ] && echo HARDLINK-OK || echo NOT-HARDLINKED
'
docker rm -f "$CID" >/dev/null
```
Expected: all binaries present, nix 2.35.2, HARDLINK-OK.

- [ ] **Step 4: Commit**

```bash
git add patches/nix-seed/Dockerfile
git commit -m "feat: shared nix-seed image — pinned nix 2.35.2 + 8 tools (rg/jq/fd/htop/bat/just/mise/gh; omp via mise)"
```

---

### Task 2: compose — nix-seed service + depends_on + mise volumes

**Files:**
- Modify: `docker-compose.yml`

**Interfaces:**
- Consumes: Task 1 的 `opc/nix-seed:local` image tag。
- Produces: compose service `nix-seed` (one-shot); 5 個 build service 的 service-level `depends_on: { nix-seed: { condition: service_completed_successfully } }` (注意: `build.depends_on` 不是有效的 Compose key — 2026-08-17 驗證 compose 5.4 schema 拒絕; 用 service-level depends_on 保證 start 順序, build 順序靠 seed image 已存在或 `docker compose build --with-dependencies <svc>`); 4 個 `*-mise:/opt/mise` volume mount + 宣告。Task 3-5 build 時透過 compose 拿到 seed image。

- [ ] **Step 1: Add nix-seed service** (放在 `buzz-keys` 之前, 仿 one-shot 模式)

```yaml
  # Shared nix seed — builds opc/nix-seed:local (Task 1). One-shot: image is
  # consumed via COPY --from by the service Dockerfiles; the container itself
  # does nothing.
  nix-seed:
    build:
      context: ./patches/nix-seed
      dockerfile: Dockerfile
    image: ${IMAGE_PREFIX:-opc}/nix-seed:local
    restart: "no"
    command: ["true"]
```

- [ ] **Step 2: Add service-level depends_on + NIX_SEED_IMAGE arg to the 5 build services**

`buzz-keys`、`buzz`、`frontdoor` (三個同 context `./upstream/buzz`) 與 `hermes`、`paperclip` 各加 build args, 以及 service 層級 depends_on (放在 service 的 `depends_on:` 區塊, 與既有 depends_on 並列):
```yaml
    build:
      context: ./upstream/<proj>
      dockerfile: opc/Dockerfile
      args:
        NIX_SEED_IMAGE: ${IMAGE_PREFIX:-opc}/nix-seed:local
    depends_on:
      nix-seed:
        condition: service_completed_successfully
```
(frontdoor 保留原 target/無 target; buzz-keys/buzz 保留 `target: opc-relay`。注意: `build.depends_on` 不是有效 Compose key — 用 service-level depends_on; `docker compose build <svc>` 不會自動建 seed, 但 seed image 已在 Task 1 建立, fresh machine 用 `docker compose build --with-dependencies <svc>` 或先 `docker compose build nix-seed`。)

- [ ] **Step 3: Add mise volumes 到 4 個 service** (`buzz`、`frontdoor`、`hermes`、`paperclip` 的 volumes 區塊各加一行)

```yaml
      - buzz-mise:/opt/mise        # buzz
      - frontdoor-mise:/opt/mise   # frontdoor
      - hermes-mise:/opt/mise      # hermes
      - paperclip-mise:/opt/mise   # paperclip
```

- [ ] **Step 4: 宣告 volumes** (compose 底部 `volumes:` 區塊, 與 `paperclip-nix:` 同列)

```yaml
  buzz-mise:
  frontdoor-mise:
  hermes-mise:
  paperclip-mise:
```

- [ ] **Step 5: Validate + build seed via compose**

Run:
```bash
docker compose config --quiet && echo CONFIG-OK
docker compose build nix-seed && echo SEED-BUILD-OK
```
Expected: CONFIG-OK, SEED-BUILD-OK (layer cache 命中 Task 1, 秒級)。

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml
git commit -m "feat: compose — nix-seed one-shot service, depends_on, *-mise volumes"
```

---

### Task 3: buzz Dockerfile — COPY seed + mise ENV + mise-seed.sh

**Files:**
- Modify: `patches/buzz/Dockerfile`
- Create: `patches/buzz/opc-mise-seed.sh`

**Interfaces:**
- Consumes: seed image (Task 1); `opc-mise-seed.sh` (本 task 建立, Task 6 掛進 entrypoint)。
- Produces: `opc-relay`/`opc-frontdoor` target 內含 `/nix-seed` (COPY layer) + `MISE_*` ENV + `/usr/local/bin/opc-mise-seed.sh`。

- [ ] **Step 1: Create `patches/buzz/opc-mise-seed.sh`**

```sh
#!/bin/sh
# opc-mise-seed.sh — source from an OPC entrypoint AFTER opc-nix-seed.sh
# (mise binary comes from the nix profile, so nix PATH must be active first).
#
# Ensures the mise-managed toolchains exist on the persistent *-mise volume:
# node@lts, rust@stable, and omp (prebuilt from GitHub releases — the nix
# derivation for omp cannot build in image environments, bun EPERM). Installs
# only when a toolchain is missing (fresh volume / down -v); existing
# installs are left untouched. Per-tool check → a failed install retries on
# next boot without touching the others.
# PATH tail: baked node stays authoritative (hermes 26 / paperclip 24);
# mise fills gaps (cargo/rustc everywhere, node in buzz, omp).
opc_mise_seed() {
    export MISE_DATA_DIR="${MISE_DATA_DIR:-/opt/mise}"
    export MISE_CACHE_DIR="${MISE_CACHE_DIR:-/opt/mise/cache}"
    export MISE_CONFIG_DIR="${MISE_CONFIG_DIR:-/opt/mise/config}"
    export PATH="$PATH:$MISE_DATA_DIR/shims"

    if [ ! -d "$MISE_DATA_DIR/installs/node" ]; then
        echo "[mise] first boot: installing node@lts (global)"
        mise use -g node@lts || echo "[mise] node install failed (network?)" >&2
    fi
    if [ ! -d "$MISE_DATA_DIR/installs/rust" ]; then
        echo "[mise] first boot: installing rust@stable (global, rustup)"
        mise use -g rust@stable || echo "[mise] rust install failed (network?)" >&2
    fi
    if [ ! -d "$MISE_DATA_DIR/installs/github-can1357-oh-my-pi" ]; then
        echo "[mise] first boot: installing omp (prebuilt, github releases)"
        mise use -g github:can1357/oh-my-pi@17.3.5 || echo "[mise] omp install failed (network?)" >&2
    fi
}
```

- [ ] **Step 2: 換掉 nix RUN 區塊** — 在 `patches/buzz/Dockerfile` Stage 6 (opc-relay) 中, 把整個 `RUN groupadd -r nixbld ... && cp -a /nix /nix-seed` 區塊替換為:

```dockerfile
# NOTE: BuildKit does NOT expand variables in `COPY --from=${VAR}` — use the
# stage-alias workaround: global ARG (declared BEFORE any FROM, near the top
# of the Dockerfile) + `FROM ${NIX_SEED_IMAGE} AS nix-seed` stage alias.
# The seed stage is used only as a COPY source; it adds no runtime image.
FROM ${NIX_SEED_IMAGE} AS nix-seed
RUN groupadd -r nixbld \
    && useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin nixbld1 \
    && gpasswd -a nixbld1 nixbld \
    && mkdir -m 0755 /nix
# Shared seed (nix + 8 tools) built once in patches/nix-seed (compose
# service `nix-seed`); a tool-list change rebuilds only that image.
COPY --from=nix-seed /nix-seed /nix-seed
```
(global ARG: 在 Dockerfile 最上方 `ARG EXTRA_CA_CERTS=` 那區加 `ARG NIX_SEED_IMAGE=opc/nix-seed:local`。)

- [ ] **Step 3: 加 mise ENV** — 在既有 nix ENV block 後新增一行 (保留原有 NIX_* 不刪):

```dockerfile
ENV MISE_DATA_DIR=/opt/mise \
    MISE_CACHE_DIR=/opt/mise/cache \
    MISE_CONFIG_DIR=/opt/mise/config
```

- [ ] **Step 4: COPY mise-seed.sh** — 在 `COPY opc/opc-nix-seed.sh ...` 旁加 (檔案名 `opc-mise-seed.sh` 對應既有 `opc-nix-seed.sh` 慣例):

```dockerfile
COPY opc/opc-mise-seed.sh /usr/local/bin/opc-mise-seed.sh
```
並在 chmod RUN 的清單加 `/usr/local/bin/opc-mise-seed.sh`。

- [ ] **Step 5: prepare + build**

Run:
```bash
scripts/prepare.sh
docker compose build buzz
```
Expected: build 成功; nix 部分顯示為 COPY (秒級), **不出現** `profile install` RUN。若出現 nix install → 檢查 NIX_SEED_IMAGE arg 是否有傳 (compose Task 2 Step 2)。

- [ ] **Step 6: 驗證 image 內 seed**

Run:
```bash
CID=$(docker run -d --entrypoint sh opc/buzz:local -c 'sleep 5')
docker exec "$CID" sh -c 'ls /nix-seed/var/nix/profiles/per-user/root/profile/bin | head; test -x /usr/local/bin/opc-mise-seed.sh && echo SEED-SCRIPT-OK'
docker rm -f "$CID" >/dev/null
```
Expected: 列出 8 工具 bin, SEED-SCRIPT-OK。

- [ ] **Step 7: Commit**

```bash
git add patches/buzz/Dockerfile patches/buzz/opc-mise-seed.sh
git commit -m "feat: buzz image — COPY shared nix seed, mise ENV + mise-seed script"
```

---

### Task 4: hermes Dockerfile — 同 Task 3

**Files:**
- Modify: `patches/hermes/Dockerfile`
- Create: `patches/hermes/opc-mise-seed.sh` (內容與 Task 3 Step 1 完全相同)

**Interfaces:**
- Consumes: seed image (Task 1)。
- Produces: hermes image 內含 `/nix-seed` + `MISE_*` ENV + `opc-mise-seed.sh`。

- [ ] **Step 1: Create `patches/hermes/opc-mise-seed.sh`** (逐字複製 Task 3 Step 1 的內容)

- [ ] **Step 2: 換掉 nix RUN 區塊** — `patches/hermes/Dockerfile` OPC overlay 區塊, 把整個 `RUN groupadd -r nixbld ... && cp -a /nix /nix-seed` 替換為 (與 Task 3 Step 2 相同內容):

```dockerfile
RUN groupadd -r nixbld \
    && useradd -r -g nixbld -d /var/empty -s /usr/sbin/nologin nixbld1 \
    && gpasswd -a nixbld1 nixbld \
    && mkdir -m 0755 /nix
ARG NIX_SEED_IMAGE=opc/nix-seed:local
COPY --from=${NIX_SEED_IMAGE} /nix-seed /nix-seed
```

- [ ] **Step 3: 加 mise ENV** (與 Task 3 Step 3 相同三行)

- [ ] **Step 4: COPY mise-seed.sh + chmod** (與 Task 3 Step 4 相同; 加進既有 chmod 清單)

- [ ] **Step 5: prepare + build + 驗證**

Run:
```bash
scripts/prepare.sh
docker compose build hermes
CID=$(docker run -d --entrypoint sh opc/hermes:local -c 'sleep 5')
docker exec "$CID" sh -c 'test -x /nix-seed/var/nix/profiles/per-user/root/profile/bin/gh && echo GH-OK; test -x /usr/local/bin/opc-mise-seed.sh && echo SEED-SCRIPT-OK'
docker rm -f "$CID" >/dev/null
```
Expected: GH-OK, SEED-SCRIPT-OK (hermes 原本沒有 gh)。

- [ ] **Step 6: Commit**

```bash
git add patches/hermes/Dockerfile patches/hermes/opc-mise-seed.sh
git commit -m "feat: hermes image — COPY shared nix seed, mise ENV + mise-seed script"
```

---

### Task 5: paperclip Dockerfile — 同 Task 3

**Files:**
- Modify: `patches/paperclip/Dockerfile`
- Create: `patches/paperclip/opc-mise-seed.sh` (內容與 Task 3 Step 1 完全相同)

**Interfaces:**
- Consumes: seed image (Task 1)。
- Produces: paperclip image 內含 `/nix-seed` + `MISE_*` ENV + `opc-mise-seed.sh`。

- [ ] **Step 1: Create `patches/paperclip/opc-mise-seed.sh`** (逐字複製 Task 3 Step 1 的內容)

- [ ] **Step 2: 換掉 nix RUN 區塊** — 與 Task 3 Step 2 相同內容 (paperclip 的 nix RUN 有 `apt-get install xz-utils`, 連同那行一起移入 seed image, service 內不再需要)

- [ ] **Step 3: 加 mise ENV** (與 Task 3 Step 3 相同三行)

- [ ] **Step 4: COPY mise-seed.sh + chmod** (與 Task 3 Step 4 相同)

- [ ] **Step 5: prepare + build + 驗證**

Run:
```bash
scripts/prepare.sh
docker compose build paperclip
CID=$(docker run -d --entrypoint sh opc/paperclip:local -c 'sleep 5')
docker exec "$CID" sh -c 'test -x /nix-seed/var/nix/profiles/per-user/root/profile/bin/gh && echo GH-OK; test -x /usr/local/bin/opc-mise-seed.sh && echo SEED-SCRIPT-OK'
docker rm -f "$CID" >/dev/null
```
Expected: GH-OK, SEED-SCRIPT-OK。

- [ ] **Step 6: Commit**

```bash
git add patches/paperclip/Dockerfile patches/paperclip/opc-mise-seed.sh
git commit -m "feat: paperclip image — COPY shared nix seed, mise ENV + mise-seed script"
```

---

### Task 6: entrypoint 整合 (4 個) — opc_mise_seed 掛載

**Files:**
- Modify: `patches/buzz/buzz-entrypoint.sh`
- Modify: `patches/buzz/frontdoor-entrypoint.sh`
- Modify: `patches/hermes/hermes-entrypoint.sh`
- Modify: `patches/paperclip/nix-entrypoint.sh`

**Interfaces:**
- Consumes: Task 3-5 的 `/usr/local/bin/opc-mise-seed.sh` (image 內)。
- Produces: 4 個 entrypoint 在 `opc_nix_seed` 後啟動 mise bootstrap。mise 資料寫入 `*-mise` volume。

- [ ] **Step 1: 4 個 entrypoint 各加兩行** — 在 `. opc-nix-seed.sh` + `opc_nix_seed` 之後、任何 exec 之前插入:

```sh
. /usr/local/bin/opc-mise-seed.sh
opc_mise_seed
```

每個檔案的位置:
- `buzz-entrypoint.sh`: 在 `opc_nix_seed` 之後、`if [ -n "${BUZZ_KEYS_DIR:-}" ]` 之前。
- `frontdoor-entrypoint.sh`: 在 `opc_nix_seed` 之後、`. opc-gh-seed.sh` 之前。
- `hermes-entrypoint.sh`: 在 `opc_nix_seed` 之後、`. opc-gh-seed.sh` 之前。
- `nix-entrypoint.sh` (paperclip): 在 `opc_nix_seed` 之後、`. opc-gh-seed.sh` 之前 (mise PATH 需在 gosu node 前 export, env 會帶過去)。

- [ ] **Step 2: 語法檢查**

Run: `for f in patches/buzz/buzz-entrypoint.sh patches/buzz/frontdoor-entrypoint.sh patches/hermes/hermes-entrypoint.sh patches/paperclip/nix-entrypoint.sh; do sh -n "$f" || exit 1; done && echo SYNTAX-OK`
Expected: SYNTAX-OK。

- [ ] **Step 3: prepare + build + commit**

Run:
```bash
scripts/prepare.sh
docker compose build buzz frontdoor hermes paperclip
git add patches/buzz/buzz-entrypoint.sh patches/buzz/frontdoor-entrypoint.sh patches/hermes/hermes-entrypoint.sh patches/paperclip/nix-entrypoint.sh
git commit -m "feat: entrypoints — opc_mise_seed after opc_nix_seed (PATH-tail shims)"
```

---

### Task 7: self-heal 擴充 (既有 volume 補齊 just/mise/gh/omp)

**Files:**
- Modify: `patches/buzz/nix-seed.sh`
- Modify: `patches/hermes/nix-seed.sh`
- Modify: `patches/paperclip/nix-seed.sh` (三者內容相同, 逐一改)

**Interfaces:**
- Consumes: 無 (既有 nix-seed.sh)。
- Produces: 既有 /nix volume 在升級後自動補齊新工具, 讓 Task 6 的 `mise use -g` 找得到 mise binary。

- [ ] **Step 1: 替換 self-heal 區塊** — 在三個 `nix-seed.sh` 中, 把既有:

```sh
    if [ ! -e "$PROFILE/bin/rg" ]; then
        echo "[nix] default tools missing from profile; re-adding"
        HOME=/root PATH="/nix/var/nix/profiles/default/bin:$PATH" \
            nix profile add nixpkgs#ripgrep nixpkgs#jq nixpkgs#fd nixpkgs#htop nixpkgs#bat || true
    fi
```

替換為:

```sh
    # Self-heal: if any seed tool is missing (e.g. image upgraded with new
    # tools, or the deprecated `nix profile install` replaced the profile),
    # re-add the full seed list once. Unpinned nixpkgs here is the existing
    # behavior (seed image itself is pinned). omp is mise-managed, not nix.
    if [ ! -e "$PROFILE/bin/rg" ] || [ ! -e "$PROFILE/bin/mise" ] \
        || [ ! -e "$PROFILE/bin/just" ] || [ ! -e "$PROFILE/bin/gh" ]; then
        echo "[nix] seed tools missing from profile; re-adding"
        HOME=/root PATH="/nix/var/nix/profiles/default/bin:$PATH" \
            nix profile add \
                nixpkgs#ripgrep nixpkgs#jq nixpkgs#fd nixpkgs#htop nixpkgs#bat \
                nixpkgs#just nixpkgs#mise nixpkgs#gh || true
    fi
```

- [ ] **Step 2: 語法檢查**

Run: `for f in patches/buzz/nix-seed.sh patches/hermes/nix-seed.sh patches/paperclip/nix-seed.sh; do sh -n "$f" || exit 1; done && echo SYNTAX-OK`
Expected: SYNTAX-OK。

- [ ] **Step 3: prepare + commit**

Run:
```bash
scripts/prepare.sh
git add patches/buzz/nix-seed.sh patches/hermes/nix-seed.sh patches/paperclip/nix-seed.sh
git commit -m "feat: nix self-heal — re-add full seed (just/mise/gh/omp) on existing volumes"
```

---

### Task 8: 全量部署 + 冒煙驗證 (spec §7)

**Files:**
- 無新檔案; 驗證用的暫時 volume 名在 compose 外, 不動 repo。

**Interfaces:**
- Consumes: Task 1-7 全部。

- [ ] **Step 1: prepare + 全量 build**

Run: `scripts/prepare.sh && docker compose build`
Expected: 全部成功; 各 service 的 nix 部分為 COPY (無 profile install)。

- [ ] **Step 2: 全新 volume 冒煙測 (不碰既有 volume)**

Run (用臨時 compose override, 驗證後刪除):
```bash
cat > /tmp/mise-smoke.override.yml <<'EOF'
services:
  buzz:
    volumes:
      - smoke-mise:/opt/mise
  frontdoor:
    volumes:
      - smoke-mise:/opt/mise
  hermes:
    volumes:
      - smoke-mise:/opt/mise
  paperclip:
    volumes:
      - smoke-mise:/opt/mise
volumes:
  smoke-mise:
EOF
docker compose -f docker-compose.yml -f /tmp/mise-smoke.override.yml up -d buzz frontdoor hermes paperclip
# 等 first-boot mise bootstrap 完成 (node/rust 下載)
sleep 120
```
注意: 這會 recreat 既有容器 (image 已變) — 依 spec §11 調查, in-flight 工作會被優雅中斷並自動續跑, 資料零遺失。

- [ ] **Step 3: 驗證 toolchain (每容器)**

Run:
```bash
for c in opc-buzz-1 opc-frontdoor-1 opc-hermes-1 opc-paperclip-1; do
  echo "== $c"
  docker exec "$c" sh -c 'mise --version | head -1; mise ls 2>/dev/null | grep -E "node|rust|oh-my-pi"; rustc --version; cargo --version; just --version; gh --version | head -1; omp --version'
done
```
Expected: 每容器 mise 有 node@lts + rust@stable + oh-my-pi (global), rustc/cargo = stable, just/gh/omp 有版本輸出。

- [ ] **Step 4: 驗證 daemon 不受影響 (spec §11 核心承諾)**

Run:
```bash
docker exec opc-hermes-1 node -v    # 期望 v26.5.1 (baked, 非 mise)
docker exec opc-paperclip-1 node -v # 期望 v24.19.0 (baked)
docker exec opc-buzz-1 node -v      # 期望 LTS (mise 提供, buzz 原無 node)
for c in opc-buzz-1 opc-hermes-1 opc-paperclip-1; do
  docker inspect --format "{{.Name}} health={{.State.Health.Status}}" "$c"
done
docker compose ps | grep -E "hermes|paperclip|buzz|frontdoor"   # 全部 Up/healthy
```
Expected: hermes/paperclip node 版本與部署前相同; 各 service healthy。

- [ ] **Step 5: 驗證 gh/ssh config (hermes daemon env)**

Run:
```bash
docker exec opc-hermes-1 sh -c 'export GH_CONFIG_DIR=/creds/gh; gh auth status 2>&1 | head -3'
docker exec opc-hermes-1 sh -c 'export GIT_SSH_COMMAND="ssh -F /creds/ssh/config -o StrictHostKeyChecking=accept-new"; ssh -T -o BatchMode=yes git@github.com 2>&1 | head -2'
```
Expected: gh 顯示 logged in (hosts.yml 同步的帳號); ssh 顯示 github.com 認證成功。

- [ ] **Step 6: 既有 volume 升級驗證 (self-heal)**

Run:
```bash
docker exec opc-buzz-1 sh -c 'ls /nix/var/nix/profiles/per-user/root/profile/bin | grep -E "^(just|mise|gh|omp)$"'
```
Expected: 4 個都出現 (self-heal 補齊, 可能需等 entrypoint 跑過; 若缺, `docker restart opc-buzz-1` 再查)。

- [ ] **Step 7: 移除 smoke override + 收尾**

Run:
```bash
docker compose -f docker-compose.yml -f /tmp/mise-smoke.override.yml up -d buzz hermes paperclip  # 還原正式 volumes
rm /tmp/mise-smoke.override.yml
docker compose up -d    # 確保回到正式配置
docker compose ps
```

- [ ] **Step 8: 記錄驗證結果** — 把每個 step 的實際輸出貼進 commit message 或 PR description; 若有失敗, 修復後重跑對應 step (不要跳過)。

---

### Task 9: 文件更新

**Files:**
- Modify: `AGENTS.md`
- Modify: `SETUP.md`

**Interfaces:**
- Consumes: Task 1-8 的實際行為。

- [ ] **Step 1: AGENTS.md** — 在「已知坑」或「檔案地圖」補三件事:
1. `patches/nix-seed/` 是第一個不屬 submodule 的 build context (compose service `nix-seed`, one-shot); 改 seed 工具清單 = 改這個 Dockerfile, 只重裝 1 次。
2. 每個容器有 `*-mise:/opt/mise` volume; 空狀態首次開機自動裝 node@lts + rust stable; 日常加 toolchain = `docker exec <c> mise install <tool>`。
3. gh CLI 從 nix seed 提供 (全部容器); ssh/gh config 由 `scripts/sync-gh-creds.sh` 同步進 opc-gh-creds volume, entrypoint 以 env 指過去 (GH_CONFIG_DIR/GIT_SSH_COMMAND); `docker exec` 互動 session 不繼承 runtime export env (既有限制)。

- [ ] **Step 2: SETUP.md** — 補: 首次開機後 `docker exec opc-buzz-1 sh -c 'mise ls; gh --version'` 驗證 toolchain; nix-seed build 順序由 compose 自動處理, 無需手動步驟。

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md SETUP.md
git commit -m "docs: nix-seed build context, mise volumes, gh creds sync"
```

---

## 驗證對照 (spec §7 → 本 plan)

| spec 驗證項 | plan task |
|---|---|
| nix-seed 內容 8 工具 + hardlink | Task 1 Step 3 |
| patch script 編輯 → build 無 nix install | Task 3-5 Step 5 (build log) + Task 8 Step 1 |
| 全新 volume 冒煙: mise/node/rust/just/omp | Task 8 Step 2-3 |
| daemon 不變 (hermes 26 / paperclip 24) | Task 8 Step 4 |
| gh/ssh config 生效 | Task 8 Step 5 |
| healthcheck 通過 | Task 8 Step 4 |
| self-heal 補齊 | Task 8 Step 6 |
