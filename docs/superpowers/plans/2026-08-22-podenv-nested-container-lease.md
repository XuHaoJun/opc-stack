# Podenv — Nested Container Lease Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 給 OPC stack 一條巢狀容器租約 lane, 讓 paperclip agent 自助取得「devenv 蓋不到」的 daemon (不能 multi-tenant 的、或超舊版本的 image), 不破壞不變量 6。

**Architecture:** 一個新的 compose service `podenv` 跑 **rootless podman** 的 API service (`quay.io/podman/stable`), socket 放共用 volume; paperclip 掛那顆 volume, 以 uid 1000 連上去 (socket 保持 podman 自己的 0600, 存取閘就是 owner uid)。Agent 手上是**完整 podman** (寬介面) 加一層與 devenv 同形的 `podenv` lease CLI, 登記在 devenv 的 control DB 裡自己一張表。

**Tech Stack:** POSIX shell (`/bin/sh` 是 dash — 見 Global Constraints)、PostgreSQL (devenv_control)、docker compose、podman 5.8.4 / pasta / crun。

## Global Constraints

設計依據: `docs/superpowers/specs/2026-08-22-podenv-nested-container-lease-design.md`。
以下每一條的值都逐字來自那份 spec, 每個 task 都隱含包含本節。

- **image pin**: `quay.io/podman/stable@sha256:8923deffca4caa8338b5dd4f553a86736f2aab424a4743827fccce632fecd750` (podman 5.8.4)。
- **runtime uid 必須是 1000** —— 等於 paperclip 的 `node`。這是 socket 的存取閘 (spec 量測 §3)。
- **`containers.conf` 是最小差異覆蓋**: 只改 `netns` 一行, `userns="host"`、`cgroups="disabled"`、`cgroup_manager="cgroupfs"`、`log_driver`、`events_logger`、`runtime` 全部逐字保留 (spec 量測 §4、§7)。
- **compose 上只有三項宣告**: `security_opt: [seccomp=unconfined]`、`devices: [/dev/net/tun]`、`mem_limit`。**沒有** `privileged`、**沒有**任何 host bind mount、**沒有** `apparmor=unconfined`、**沒有** `label=disable`、**沒有** `/dev/fuse`。
- **沒有 `--memory` 旗標。** per-lease 上限不可交付 (spec 量測 §4)。唯一的旋鈕是 compose 的 `mem_limit`。
- **port pool**: `PODENV_PORT_BASE=23000`、`PODENV_PORT_COUNT=16`、`PODENV_PORT_RANGE_END=23015`。base **必須 < 32768**。發佈只綁 `127.0.0.1`。
- **paperclip 不 `depends_on` podenv**, 一條邊都沒有 (spec「錯誤處理」第 1 條; 不變量 8 的教訓)。
- **exit codes**: 0 ok / 2 bad usage / 3 exhausted / 4 backend unreachable —— 與 devenv 相同。
- **`patches/podenv/` 是直接的 build context**, 照 `patches/nix-seed/` 的做法, **不經 `scripts/prepare.sh` 同步** (prepare.sh 只處理 submodule 的 `patches/<proj>/` → `upstream/<proj>/opc/`)。
- **`/bin/sh` 在這些 image 裡是 dash。** 不要用 bashism; 特別是 `read a b < /proc/...` 對 procfs 會壞 (`opc-devenv-seed.sh` 有這個傷疤的註解)。
- **URL 模板變數是 `{{name}}` 不是 `${name}`** —— 與 repo 既有的 `expose.urlTemplate` 一致 (AGENTS.md 記過 `${port}` 是過期範例)。
- 測試腳本落在 `tests/`, 慣例是「跑一個指令、比對輸出」, 沒有 unit-test framework (見 `tests/scientist.sh` 的檔頭)。

## File Structure

**新建**

| 檔案 | 責任 |
|---|---|
| `patches/podenv/Dockerfile` | podenv image: pin 上游 + uid 斷言 + 覆蓋 containers.conf + entrypoint |
| `patches/podenv/containers.conf` | 最小差異覆蓋 (只有 `netns`) |
| `patches/podenv/opc-podenv-entrypoint.sh` | root 交出三棵樹 → self-test → 寫診斷檔 → 降權 exec podman service |
| `patches/podenv/opc-podenv-restore.sh` | 背景把帶 lease label 的容器叫回來 |
| `patches/paperclip/devenv/shared.sh` | devenv 與 podenv **共用**的真相: env merge、密碼推導、owner、保留變數名、provider image 家族 |
| `patches/paperclip/podenv/podenv` | `podenv` CLI (provision / release / list) |
| `patches/paperclip/podenv/bootstrap.sql` | `podenv_lease` 表 + `podenv_usage` view |
| `patches/paperclip/opc-podenv-seed.sh` | 開機套 schema + 檢查 port pool (冪等, 永不致命) |
| `patches/paperclip/skills/podenv/SKILL.md` | 決策表**正本** + 用法 |
| `tests/podenv.sh` | 結構 + live 兩段 gate |

**修改**

| 檔案 | 改什麼 |
|---|---|
| `docker-compose.yml` | 新增 `podenv` service、兩顆 volume; paperclip 掛 socket volume + podenv env |
| `.env.example` | `PODENV_*` 四個變數 |
| `patches/paperclip/Dockerfile` | apt 裝 `podman-remote` client (量測後推翻了 `COPY --from=podenv` 的方案)、COPY podenv CLI/seed、symlink、`ENV CONTAINER_HOST` |
| `patches/paperclip/nix-entrypoint.sh` | source podenv seed |
| `patches/paperclip/devenv/devenv` | 改成 source `shared.sh`; `cmd_list` 尾巴加 guarded 的 podenv 段 |
| `patches/paperclip/skills/devenv/SKILL.md` | 一行前向指標 (**不複製決策表**) |
| `patches/paperclip/skills/container-tools/SKILL.md` | 一行指標 |
| `patches/paperclip/opc-paperclip-bootstrap.sh` | Prototyper 的 `desiredSkills` 加 `podenv` |
| `scripts/setup.sh` | 先單獨 build `podenv` (與 `nix-seed` 同理由) |
| `tests/fresh-install.sh` | podenv 的 port range 一起 +1000 |
| `SETUP.md` / `AGENTS.md` | 操作說明與不變量/坑 |
| spec 檔 | 「唯一要碰 devenv 的兩個地方」改成三個 (多了 `shared.sh`) |

---

### Task 1: podenv image 與 compose service

**Files:**
- Create: `patches/podenv/Dockerfile`
- Create: `patches/podenv/containers.conf`
- Create: `patches/podenv/opc-podenv-entrypoint.sh`
- Modify: `docker-compose.yml` (新增 service + 兩顆 volume)
- Modify: `.env.example`
- Test: `tests/podenv.sh` (新建)

**Interfaces:**
- Consumes: 無 (第一個 task)
- Produces: compose service `podenv`; volume `opc-podenv-sock` 上的 unix socket `/run/podenv/podman.sock` (owner uid 1000, mode 0600); volume `opc-podenv-store`; 掛在 `podenv` 上的 `opc-prototypes` mount (`/prototypes`, 讓 lease 可以 bind-mount 自己所屬的 project); 診斷檔 `/run/podenv/diagnosis` (可能為空); image `${IMAGE_PREFIX:-opc}/podenv:local`

- [ ] **Step 1: 寫失敗的測試**

建立 `tests/podenv.sh`:

```bash
#!/usr/bin/env bash
# podenv lane — 結構 + live gate。
#
# 從 repo root 對著跑著的 stack 執行: tests/podenv.sh
#
# 與 tests/scientist.sh 同慣例: 沒有 unit-test framework, 每條檢查都是「跑一個
# 指令、比對輸出」。順序是先結構後 live, 所以第一個失敗就告訴你是哪一層壞的 ——
# 結構檢查不需要 stack 在跑, live 檢查需要。
set -uo pipefail
cd "$(dirname "$0")/.."
. "$(dirname "$0")/../scripts/load-env.sh"; opc_load_env ./.env

PASS=0
FAIL=0
pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}
# expect <label> <expected> <cmd...> — pass when stdout trims to <expected>.
expect() {
    local label="$1" want="$2"; shift 2
    local got
    got="$("$@" 2>/dev/null | tr -d '\r' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    if [ "$got" = "$want" ]; then pass "$label"; else fail "$label (want '$want', got '$got')"; fi
}

echo "── structure ──"

# The whole security posture of this lane is three compose declarations and
# nothing else. Reading the RESOLVED config (not the file) is deliberate: an
# override file or an env default could add a fourth without touching
# docker-compose.yml.
CONF_JSON="$(docker compose config --format json 2>/dev/null)"
podenv_field() { printf '%s' "$CONF_JSON" | python3 -c "$1"; }

expect "security_opt is exactly [seccomp=unconfined]" "seccomp=unconfined" \
    podenv_field 'import json,sys; print(",".join(json.load(sys.stdin)["services"]["podenv"].get("security_opt",[])))'
expect "devices is exactly [/dev/net/tun]" "/dev/net/tun" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
d=s.get("devices",[])
print(",".join(x if isinstance(x,str) else x.get("source","?") for x in d))'
expect "not privileged" "False" \
    podenv_field 'import json,sys; print(json.load(sys.stdin)["services"]["podenv"].get("privileged",False))'
expect "no host bind mount" "" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(v.get("source","") for v in s.get("volumes",[]) if v.get("type")=="bind"))'
expect "mounts no secret volume" "" \
    podenv_field 'import json,sys
bad={"opc-keys","opc-gh-creds","opc-prototyper-home","frontdoor-hermes","hermes-profiles","hermes-data"}
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(sorted({v.get("source","") for v in s.get("volumes",[])} & bad)))'
expect "port range is published on 127.0.0.1 only" "127.0.0.1" \
    podenv_field 'import json,sys
s=json.load(sys.stdin)["services"]["podenv"]
print(",".join(sorted({p.get("host_ip","") for p in s.get("ports",[])})))'

# compose cannot do arithmetic, so the pool bounds are stated twice. The same
# hazard is already documented for DEVENV_HTTP_PORT_RANGE_END.
BASE="${PODENV_PORT_BASE:-23000}"; COUNT="${PODENV_PORT_COUNT:-16}"
END="${PODENV_PORT_RANGE_END:-23015}"
expect "PODENV_PORT_RANGE_END == BASE + COUNT - 1" "$((BASE + COUNT - 1))" echo "$END"
check "port base is below the ephemeral range" test "$BASE" -lt 32768

echo "── live ──"

check "podenv container is running" \
    sh -c 'docker compose ps --format "{{.Service}} {{.State}}" | grep -q "^podenv running$"'
check "socket exists" docker compose exec -T podenv test -S /run/podenv/podman.sock
expect "socket owner uid == paperclip node uid" \
    "$(docker compose exec -T paperclip id -u node 2>/dev/null | tr -d '\r')" \
    docker compose exec -T podenv stat -c %u /run/podenv/podman.sock
expect "self-test left no diagnosis" "" \
    docker compose exec -T podenv sh -c 'cat /run/podenv/diagnosis 2>/dev/null'
expect "nested podman run works" "NESTED_OK" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    podman run --rm docker.io/library/alpine:3.20 echo NESTED_OK
expect "default netns is pasta, not the upstream host" "pasta" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    sh -c 'podman run -d --name podenv-netns-probe docker.io/library/alpine:3.20 sleep 30 >/dev/null 2>&1
           podman inspect podenv-netns-probe --format "{{.HostConfig.NetworkMode}}"
           podman rm -f podenv-netns-probe >/dev/null 2>&1'
# userns must stay host: dropping it moves nested-created files into the subuid
# range and /prototypes replays the invariant-3b ownership pain.
expect "userns stays host (file ownership on /prototypes)" "1000" \
    docker compose exec -T -u 1000 -e HOME=/home/podman -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
    sh -c 'podman run --rm -v /prototypes:/p docker.io/library/alpine:3.20 \
             sh -c "touch /p/.podenv-probe" >/dev/null 2>&1
           stat -c %u /prototypes/.podenv-probe; rm -f /prototypes/.podenv-probe'
# mem_limit is the ONLY memory knob that works (spec measurement 4). Read
# podenv's OWN cgroup file — the nested one is always `max`, so asserting
# there would make this check green in the wrong place.
check "mem_limit is actually applied to the podenv container" \
    sh -c 'v=$(docker compose exec -T podenv cat /sys/fs/cgroup/memory.max 2>/dev/null | tr -d "\r"); [ -n "$v" ] && [ "$v" != "max" ]'

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
chmod +x tests/podenv.sh && tests/podenv.sh
```

Expected: 結構檢查全 FAIL (`KeyError: 'podenv'` 讓 `expect` 拿到空字串), live 檢查全 FAIL。最後一行 `passed 0, failed 13`, exit 1。

- [ ] **Step 3: 寫 containers.conf**

`patches/podenv/containers.conf` —— 逐字複製上游那份, **只改 `netns` 一行**:

```ini
# Minimal-diff override of the upstream /etc/containers/containers.conf that
# ships in quay.io/podman/stable. Exactly ONE line differs from upstream:
# netns, host -> pasta. Everything else is copied verbatim and must stay that
# way; the two that matter most are measured facts, not preferences:
#
#   userns="host"       Nested containers share the sidecar's user namespace,
#                       so files they create under /prototypes land as uid
#                       1000 (= paperclip's `node`). Give them their own
#                       userns and the files land in the subuid range
#                       (/etc/subuid gives podman 1:999 and 1001:64535) and
#                       /prototypes replays the invariant-3b ownership pain.
#                       The cost, stated plainly: nested containers are barely
#                       isolated from one another. That is consistent with the
#                       declared boundary being the OUTER docker container.
#   cgroups="disabled"  One of the two measured reasons `podman run --memory`
#                       is silently ignored (the other is /sys/fs/cgroup being
#                       a read-only mount). Removing it does NOT buy per-lease
#                       limits; the ro mount alone is enough to block cgroup
#                       delegation, and delegation needs a host mount, which
#                       invariant 6 forbids.
#
# Why netns changes: with netns="host" a nested daemon lands in the sidecar's
# network namespace and `-p` is DISCARDED WITHOUT A WARNING (`podman ps` just
# shows an empty Ports column), so two leases of the same image can never
# coexist. pasta gives real per-container netns plus working port remapping,
# and needs /dev/net/tun — which the compose service grants.
[containers]
netns="pasta"
userns="host"
ipcns="host"
utsns="host"
cgroupns="host"
cgroups="disabled"
log_driver = "k8s-file"
[engine]
cgroup_manager = "cgroupfs"
events_logger="file"
runtime="crun"
```

- [ ] **Step 4: 寫 entrypoint**

`patches/podenv/opc-podenv-entrypoint.sh`:

```sh
#!/bin/sh
# opc-podenv-entrypoint.sh — the podenv lane's runtime host.
#
# Starts the rootless podman API service that `podenv` (in the paperclip
# image) leases containers from. Root only long enough to hand three trees to
# the runtime user, then drops for good.
#
# The socket keeps podman's OWN 0600 mode and we do not fight it. Its access
# gate is the OWNER uid, deliberately aligned with paperclip's `node` (uid
# 1000). Measured: podman re-chmods the socket to 0600 AFTER creating the
# listener, so granting group access races and loses — a retry loop was
# observed reporting success (stat really did read 660) and then being
# reverted. See the spec's measurement 3.
set -eu

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
PODENV_SOCK_DIR="${PODENV_SOCK_DIR:-/run/podenv}"
PODENV_STORE="${PODENV_STORE:-/home/podman/.local/share/containers}"
PODENV_RUNTIME_DIR="/run/user/${PODENV_UID}"
PODENV_DIAG="${PODENV_SOCK_DIR}/diagnosis"

mkdir -p "$PODENV_SOCK_DIR" "$PODENV_STORE" "$PODENV_RUNTIME_DIR"
chown "$PODENV_UID:$PODENV_GID" "$PODENV_SOCK_DIR" "$PODENV_STORE" "$PODENV_RUNTIME_DIR"
# 0700: a second, independent gate. Measured — a process with the right uid but
# no traverse on this directory is refused before the socket mode matters.
chmod 0700 "$PODENV_SOCK_DIR"

as_runtime_user() {
    setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups --inh-caps=-all \
        env HOME=/home/podman XDG_RUNTIME_DIR="$PODENV_RUNTIME_DIR" "$@"
}

# Self-test, and WRITE THE VERDICT DOWN. A nested runtime that cannot start
# produces errors that mean nothing to the caller ("cannot clone: Operation not
# permitted", "Failed to open() /dev/net/tun"); the CLI reads this file so the
# operator gets one sentence instead of a nested stack trace.
#
# Never fatal. podenv is an optional lane and paperclip has no depends_on edge
# to it: a broken runtime host must degrade to "leases fail when used", not to
# "the stack does not come up" (invariant 8's lesson).
: > "$PODENV_DIAG"
chown "$PODENV_UID:$PODENV_GID" "$PODENV_DIAG"

if ! _st_out="$(as_runtime_user podman unshare true 2>&1)"; then
    printf 'userns nesting failed: %s\n' "$_st_out" > "$PODENV_DIAG"
    echo "[podenv] WARNING userns nesting failed — every lease will fail." >&2
    echo "[podenv] WARNING   $_st_out" >&2
    echo "[podenv] WARNING   Check that this service still has security_opt: [seccomp=unconfined]," >&2
    echo "[podenv] WARNING   and that the host allows unprivileged user namespaces." >&2
elif [ ! -c /dev/net/tun ]; then
    printf 'no /dev/net/tun: pasta unavailable, leases must pass --netns host\n' > "$PODENV_DIAG"
    echo "[podenv] WARNING /dev/net/tun is missing — pasta cannot start, so port" >&2
    echo "[podenv] WARNING   remapping (-p) is unavailable. Leases must pass --netns host." >&2
    echo "[podenv] WARNING   No silent fallback: a lease that thinks it has its own netns" >&2
    echo "[podenv] WARNING   but shares the sidecar's would collide invisibly." >&2
fi

# Spelled out rather than reusing as_runtime_user(): `exec` cannot run a shell
# function, and this process must be REPLACED — a setpriv running under a
# surviving shell would make the shell PID 1, so podman would not receive the
# signals docker sends it on `compose stop`.
exec setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups --inh-caps=-all \
    env HOME=/home/podman XDG_RUNTIME_DIR="$PODENV_RUNTIME_DIR" \
    podman system service --time=0 "unix://${PODENV_SOCK_DIR}/podman.sock"
```

- [ ] **Step 5: 寫 Dockerfile**

`patches/podenv/Dockerfile`:

```dockerfile
# syntax=docker/dockerfile:1.7
#
# OPC podenv — the nested container lease lane's runtime host.
#
# Deliberately does NOT copy the shared nix seed. AGENTS.md records that the
# seed costs one layer per image (`COPY --from=nix-seed /nix-seed /nix-seed`
# is paid per service image, not just once on the shared volume), and nobody
# shells into this container to work: it is a runtime host, not a work
# environment.
#
# Build via compose service `podenv` (context ./patches/podenv) or:
#   docker build -t opc/podenv:local -f patches/podenv/Dockerfile patches/podenv
FROM quay.io/podman/stable@sha256:8923deffca4caa8338b5dd4f553a86736f2aab424a4743827fccce632fecd750

# The socket's access gate is its OWNER uid, which must equal paperclip's
# runtime `node` user. Assert it at BUILD time so an upstream image that
# renumbers its user fails here, loudly, instead of at socket-connect time
# where the symptom is an opaque "permission denied" from a CLI that looks
# like it should work.
#
# This does NOT contradict the paperclip Dockerfile's "Unifying the runtime
# UIDs instead was rejected" — that rejected CHANGING an existing image's uid
# (paperclip's 1000 comes from the upstream node base image, and its home
# volumes are owned by the current uids — invariant 3b). This is a brand new
# image with no existing volume, aligning itself to the established 1000.
RUN test "$(id -u podman)" = "1000" \
    || { echo "ERROR: podman uid is $(id -u podman), expected 1000 (paperclip's node uid)"; exit 1; }

# Minimal-diff override — see the file's own header for what must not change.
COPY containers.conf /etc/containers/containers.conf

COPY opc-podenv-entrypoint.sh /usr/local/bin/opc-podenv-entrypoint.sh
RUN chmod +x /usr/local/bin/opc-podenv-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/opc-podenv-entrypoint.sh"]
```

- [ ] **Step 6: 加 compose service 與 volume**

在 `docker-compose.yml` 的 devenv 區塊**之後**插入 (讓兩條資源 lane 相鄰):

```yaml
  # ══════════════════════ podenv (巢狀容器租約) ══════════════════════
  # devenv 蓋不到的那一半: 不能 multi-tenant 的 daemon, 以及很老舊的版本。
  # 設計 (含七條量測): docs/superpowers/specs/
  # 2026-08-22-podenv-nested-container-lease-design.md
  #
  # Rootless podman inside docker. Invariant 6's two prohibitions both hold:
  # no host mount, no privileged. The three declarations below are the ENTIRE
  # security posture of this lane and each one is a measured necessity:
  #
  #   seccomp=unconfined  docker's default profile blocks clone() with
  #                       CLONE_NEWUSER, so rootless podman cannot start at
  #                       all. Measured both ways: with it, nested `podman
  #                       run` works; without it, "cannot clone: Operation not
  #                       permitted". It relaxes the syscall filter and grants
  #                       NOTHING on the host filesystem — far smaller than
  #                       privileged, which is what DinD needs (even the
  #                       official dind-rootless image documents --privileged).
  #                       It is confined to THIS service on purpose: paperclip
  #                       holds /keys, gh creds, the board API key and every
  #                       prototype; this container holds nothing.
  #   /dev/net/tun        pasta needs it to create its tap device. Without it
  #                       nested containers fall back to the sidecar's netns
  #                       and `-p` is discarded WITHOUT A WARNING. bridge /
  #                       netavark is not an option at all: it writes
  #                       /proc/sys, which docker mounts read-only.
  #   mem_limit           The ONLY memory knob that works. Per-lease
  #                       --memory is silently ignored (measured: memory.max
  #                       stays `max`, no warning) and cannot be fixed without
  #                       mounting the host's /sys/fs/cgroup.
  #
  # NOT needed here, measured on this host — do not "helpfully" add them:
  # apparmor=unconfined (AppArmor is not loaded), label=disable (no SELinux),
  # /dev/fuse (kernel 7.2 gives native rootless overlay).
  podenv:
    build:
      context: ./patches/podenv
      dockerfile: Dockerfile
    image: ${IMAGE_PREFIX:-opc}/podenv:local
    # podman itself is PID 1 and never wait()s on reparented children — every
    # nested `podman run`/`podman build` leaves a (pasta.avx2) and a (conmon)
    # zombie behind (measured: 5 nested runs -> 10 zombies, ppid 1). init:
    # true swaps in docker-init as PID 1, which reaps them and still forwards
    # signals through to podman on `compose stop`. Same precedent as
    # buzz/frontdoor/paperclip above.
    init: true
    restart: unless-stopped
    security_opt:
      - seccomp=unconfined
    devices:
      - /dev/net/tun
    mem_limit: ${PODENV_MEM_LIMIT:-4g}
    environment:
      # Must equal paperclip's `node` uid: the socket stays 0600 and its owner
      # IS the access gate. Asserted at build time in the Dockerfile and by
      # tests/podenv.sh against the running paperclip.
      PODENV_UID: "1000"
      PODENV_GID: "1000"
      PODENV_SOCK_DIR: /run/podenv
    # Published for the OPERATOR only (127.0.0.1), same stance as devenv-pg:
    # the point is that YOU can point a client at a leased daemon, not that
    # the LAN can. In-stack consumers do not need this at all — they reach a
    # lease at podenv:<port> over docker DNS.
    #
    # BASE and RANGE_END are stated twice (here and in the CLI's pool) because
    # compose cannot do arithmetic; opc-podenv-seed.sh will warn when they
    # drift once the paperclip-side seed lands in Task 2, and tests/podenv.sh
    # fails on it in the meantime.
    ports:
      - "127.0.0.1:${PODENV_PORT_BASE:-23000}-${PODENV_PORT_RANGE_END:-23015}:${PODENV_PORT_BASE:-23000}-${PODENV_PORT_RANGE_END:-23015}"
    volumes:
      - opc-podenv-sock:/run/podenv
      - opc-podenv-store:/home/podman/.local/share/containers
      # Lets a lease bind-mount the project it belongs to. No new exposure:
      # the agent already reads this whole tree from paperclip.
      - opc-prototypes:/prototypes
    healthcheck:
      # `test -S` only proves the socket FILE exists, not that anything is
      # listening — measured: a stale socket from a previous run (or one
      # created by anything else) still passes `test -S` with nobody home.
      # Prove the API actually answers instead, as the uid that will use it.
      test: ["CMD-SHELL", "setpriv --reuid 1000 --regid 1000 --clear-groups --inh-caps=-all env HOME=/home/podman XDG_RUNTIME_DIR=/run/user/1000 podman --remote --url unix:///run/podenv/podman.sock version >/dev/null 2>&1"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 60s
```

在 `volumes:` 區段 `opc-prototypes:` 之後加:

```yaml
  # podenv: the API socket (shared with paperclip — a unix socket on a shared
  # volume is reachable across containers, the same mechanism nix-daemon uses)
  # and the image/container store.
  opc-podenv-sock:
  opc-podenv-store:
```

- [ ] **Step 7: 加 .env.example 條目**

在 `.env.example` 的 devenv 區塊之後加:

```sh
# ── podenv (巢狀容器租約) ──────────────────────────────────────────────
# devenv 蓋不到的那一半: 不能 multi-tenant 的 daemon、超舊版本的 image。
# 這些 port 只發佈到 127.0.0.1, 供你拿 client 直接連租到的 daemon。
# PODENV_PORT_RANGE_END 必須 = BASE + COUNT - 1 (compose 不會算術), 而
# BASE 必須低於 32768 (kernel ephemeral range) —— 與 DEVENV_HTTP_* 同一個坑。
PODENV_PORT_BASE=23000
PODENV_PORT_COUNT=16
PODENV_PORT_RANGE_END=23015
# 整條 lane 的記憶體上限。per-lease 上限做不到 (podman 的 --memory 在這個拓撲
# 下會被靜靜忽略), 所以這是唯一真的生效的旋鈕。
PODENV_MEM_LIMIT=4g
```

- [ ] **Step 8: build 起來並跑測試**

```bash
docker compose build podenv && docker compose up -d podenv && sleep 15 && tests/podenv.sh
```

Expected: `passed 13, failed 0`, exit 0。若 `default netns is pasta` 那條 FAIL, 檢查 `containers.conf` 是否真的被 COPY 進 `/etc/containers/containers.conf` (`docker compose exec podenv head -20 /etc/containers/containers.conf`)。

- [ ] **Step 9: commit**

```bash
git add patches/podenv/ tests/podenv.sh docker-compose.yml .env.example
git commit -m "feat: podenv 的 runtime host — rootless podman, 無 privileged 無 host mount"
```

---

### Task 2: 登記表、共用真相、`podenv list`

**Files:**
- Create: `patches/paperclip/devenv/shared.sh`
- Create: `patches/paperclip/podenv/podenv`
- Create: `patches/paperclip/podenv/bootstrap.sql`
- Create: `patches/paperclip/opc-podenv-seed.sh`
- Modify: `patches/paperclip/devenv/devenv` (source shared.sh; cmd_list 加 guarded 段)
- Modify: `patches/paperclip/Dockerfile`
- Modify: `patches/paperclip/nix-entrypoint.sh`
- Modify: `docker-compose.yml` (paperclip 掛 socket volume + podenv env)
- Modify: `docs/superpowers/specs/2026-08-22-podenv-nested-container-lease-design.md`
- Test: `tests/podenv.sh`

**Interfaces:**
- Consumes: Task 1 的 socket `/run/podenv/podman.sock`
- Produces:
  - `shared.sh` 匯出 `devenv_env_merge <env_file> <new_file>`、`devenv_derive_password <key> <kind>` (印 32 字元 hex)、`devenv_owner` (印字串)、`devenv_reserved_env_names` (每行一個名字)、`devenv_provider_image_families` (每行一個 `family=provider`)
  - `podenv list` (exit 0)、`podenv` 的 exit code 2/4
  - 表 `podenv_lease`、view `podenv_usage` (在 `devenv_control`)
  - paperclip 容器內 `CONTAINER_HOST=unix:///run/podenv/podman.sock`, PATH 上有 `podman`。
    client 是 Debian 的 `podman-remote` package (apt, 5.4.2), `podman` 只是它的
    symlink — 不是從 podenv image `COPY --from` 出來的同build binary (量測後推翻,
    見 Step 9)。

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/podenv.sh` 的 `── live ──` 段尾:

```bash
echo "── cli ──"

# NOT a version-match check: the client (Debian's podman-remote) and the
# runtime host legitimately differ (5.4.2 vs 5.8.4), and that gap is measured
# to be fine. What matters is that the client can DRIVE the server — assert
# that directly: a non-empty server version AND a real nested operation
# succeeding. expect_ok (not expect) so a silently-failed half cannot read as
# a pass.
expect_ok "paperclip's podman client can drive the podenv server" "OK" \
    docker compose exec -T -u node paperclip sh -c \
    's=$(podman --remote version --format "{{.Server.Version}}" 2>/dev/null)
     [ -n "$s" ] || exit 1
     podman --remote run --rm docker.io/library/alpine:3.20 echo NESTED_OK >/dev/null 2>&1 || exit 1
     echo OK'
check "podenv list works" docker compose exec -T -u node paperclip podenv list
check "podenv_lease table exists" \
    docker compose exec -T paperclip sh -c \
    'PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$DEVENV_PG_HOST" -U "$DEVENV_PG_ADMIN_USER" \
       -d "${DEVENV_CONTROL_DB:-devenv_control}" -tAc "SELECT 1 FROM podenv_lease LIMIT 1" >/dev/null'
check "devenv list shows the podenv section" \
    sh -c 'docker compose exec -T -u node paperclip devenv list 2>&1 | grep -q "podenv leases"'
expect "bad usage is exit 2" "2" \
    docker compose exec -T -u node paperclip sh -c 'podenv provision 2>/dev/null; echo $?'
# The reserved-name list must have exactly one home. If podenv grew its own
# copy, this drifts silently and two tools write the same .env key.
expect "reserved env names come from devenv, not a second copy" "DATABASE_URL" \
    docker compose exec -T -u node paperclip sh -c \
    '. /usr/local/lib/devenv/shared.sh; devenv_reserved_env_names | grep -x DATABASE_URL'
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
tests/podenv.sh
```

Expected: `── cli ──` 六條全 FAIL (`podenv: not found` / `podman: not found`)。

- [ ] **Step 3: 抽出共用真相**

建立 `patches/paperclip/devenv/shared.sh`:

```sh
#!/bin/sh
# shared.sh — the truths `devenv` and `podenv` must not disagree about.
#
# Sourced by BOTH CLIs. This file exists because this repo has been burned at
# least three times by the same rule living in two places (two copies of the
# paperclip-api SKILL.md, two copies of SOUL.md, the nix seed tool list) —
# scripts/prepare.sh's drift checks are the scar tissue. Both CLIs ship in the
# same image, so sharing a file removes the drift class entirely instead of
# adding a fourth check for it.
#
# NOT here: psql connection plumbing. Each CLI keeps its own, because if that
# drifts the failure is loud (a connection error), whereas a drifted reserved
# name is silent (two tools writing the same .env key).

# Every .env variable name devenv owns. podenv REFUSES to write any of these,
# which is what makes "postgres from devenv + Milvus from podenv" the only
# possible shape rather than merely the recommended one.
#
# Derived by reading providers/*.sh: postgres.sh -> DATABASE_URL,
# valkey.sh -> VALKEY_URL, http.sh -> DEV_PORT, DEV_PORT_<n>, DEV_URL,
# DEV_HOST, HOST. DEV_PORT_ is a PREFIX rule, so callers must treat it as one
# (see devenv_env_name_reserved below).
devenv_reserved_env_names() {
    cat <<'NAMES'
DATABASE_URL
VALKEY_URL
DEV_PORT
DEV_URL
DEV_HOST
HOST
NAMES
}

# True when $1 is a name devenv owns, including the DEV_PORT_<n> family.
devenv_env_name_reserved() {
    devenv_reserved_env_names | grep -qx "$1" && return 0
    case "$1" in DEV_PORT_[0-9]*) return 0 ;; esac
    return 1
}

# Image families devenv already serves, as `family=provider` lines. podenv's
# route gate reads this so "devenv already provides it, so prefer devenv" is a
# mechanism and not just prose in a skill.
devenv_provider_image_families() {
    cat <<'FAMILIES'
postgres=postgres
pgvector=postgres
valkey=valkey
redis=valkey
FAMILIES
}

# Derived, not stored: a re-run must hand back the credential a stale .env
# already holds, and derivation achieves that without plaintext secrets at rest.
devenv_derive_password() {
    [ -n "${DEVENV_SECRET_SALT:-}" ] || {
        echo "DEVENV_SECRET_SALT is unset — set it in .env" >&2; return 1; }
    printf '%s|%s|%s' "$DEVENV_SECRET_SALT" "$1" "$2" | sha256sum | cut -c1-32
}

# Owner attribution, in order of specificity. PAPERCLIP_AGENT_ID is injected
# by paperclip on every agent run, so leases are attributed automatically.
devenv_owner() {
    if [ -n "${DEVENV_OWNER:-}" ]; then
        echo "$DEVENV_OWNER"
    elif [ -n "${PAPERCLIP_AGENT_ID:-}" ]; then
        echo "agent:${PAPERCLIP_AGENT_ID}"
    else
        echo "$(id -un)@$(hostname)"
    fi
}

# Rewrite only the keys the caller is about to write; anything else in the file
# is preserved. Both arguments are files so KEY=VALUE lines never go through
# word splitting. This is the mechanism that lets a devenv lease and a podenv
# lease share one .env.
devenv_env_merge() {
    _env_file="$1"; _env_new="$2"
    _env_tmp="${_env_file}.envmerge.$$"
    : > "$_env_tmp"
    if [ -f "$_env_file" ]; then
        _env_drop="$(sed 's/=.*//' "$_env_new" | paste -sd'|' -)"
        grep -Ev "^(${_env_drop})=" "$_env_file" >> "$_env_tmp" || true
    fi
    cat "$_env_new" >> "$_env_tmp"
    mv "$_env_tmp" "$_env_file"
}
```

- [ ] **Step 4: 讓 devenv 用 shared.sh (刪掉它自己那三份)**

在 `patches/paperclip/devenv/devenv` 的 `DEVENV_LIB` 定義之後加一行 source:

```sh
DEVENV_LIB="${DEVENV_LIB:-/usr/local/lib/devenv}"

# Truths devenv shares with podenv (env merge, password derivation, owner
# attribution, the reserved .env names, the provider image families). One
# file, two CLIs — see shared.sh's header for why.
. "$DEVENV_LIB/shared.sh"
```

然後從 `devenv` **刪掉**這三個函式的定義 (它們現在住在 `shared.sh`, 內容逐字相同):
`devenv_derive_password`、`devenv_owner`、`devenv_env_merge`。
`devenv_slug`、`devenv_psql*`、`die`、`note` **留在原處**。

**注意 provider 載入迴圈**: `for _p in "$DEVENV_LIB"/providers/*.sh` 只掃 `providers/`, 所以 `shared.sh` 放在 `devenv/` 根目錄不會被誤當 provider 載入。

- [ ] **Step 5: cmd_list 尾巴加 guarded 的 podenv 段**

在 `patches/paperclip/devenv/devenv` 的 `cmd_list` 裡, 現有 `note "  ports '!' = ..."` 之後加:

```sh
    # podenv leases live in the same database in their own table (devenv_tenant
    # is one-column-per-provider; carrying podenv's columns here would make
    # devenv's schema hold podenv's concepts). Guarded by to_regclass so devenv
    # keeps working unchanged when podenv is not installed — this is the ONE
    # line of coupling that buys a single place to look at what is occupied.
    if [ "$(devenv_psql_control -tAc \
            "SELECT to_regclass('podenv_lease') IS NOT NULL" 2>/dev/null \
            | tr -d '[:space:]')" = "t" ]; then
        echo
        echo "podenv leases (nested containers):"
        devenv_psql_control -c \
            "SELECT key, image, netns, host_port, env_var,
                    CASE WHEN dedicated_reason IS NULL THEN ''
                         ELSE 'dedicated: ' || dedicated_reason END AS dedicated,
                    date_trunc('second', idle) AS idle
             FROM podenv_usage"
    fi
```

- [ ] **Step 6: 寫登記 schema**

`patches/paperclip/podenv/bootstrap.sql`:

```sql
-- podenv control schema. Idempotent — re-applied on every paperclip boot.
--
-- Lives in the SAME database as devenv (devenv_control) so there is one place
-- to look and one `docker compose down -v` story, but in its OWN table.
-- devenv_tenant is one-column-per-provider (valkey_db, http_port_start,
-- http_port_count, http_exposed_at); adding OCI columns there would make
-- devenv's schema carry podenv's concepts, and would duplicate the table-lock
-- machinery http.sh needs for contiguous blocks.
CREATE TABLE IF NOT EXISTS podenv_lease (
  key              text PRIMARY KEY,
  slug             text NOT NULL UNIQUE,
  image            text NOT NULL,
  -- 'pasta' gives the lease its own netns and working -p remapping; 'host'
  -- shares the runtime host's netns and has no remapping at all, so the
  -- lease's container_port must already be collision-free.
  netns            text NOT NULL DEFAULT 'pasta' CHECK (netns IN ('pasta','host')),
  container_port   int  NOT NULL,
  -- UNIQUE is sufficient here, unlike devenv's http_port_start: a podenv lease
  -- holds ONE port, not a contiguous block, so there is no "different starts
  -- that still overlap" case and no table lock is needed. The DB is the
  -- arbiter; concurrent callers race harmlessly and the loser retries.
  host_port        int  NOT NULL UNIQUE,
  -- The .env variable name this lease writes. Never one of
  -- devenv_reserved_env_names (enforced in the CLI).
  env_var          text NOT NULL,
  -- Non-NULL means the caller overrode the route gate: the image family is one
  -- devenv already serves, and this is the reason they gave. Persisted and
  -- listed on purpose — that is what keeps --dedicated from being a rubber
  -- stamp, the same reasoning that keeps `prototype destroy` from having
  -- a --yes flag.
  dedicated_reason text,
  created_by       text,
  created_at       timestamptz NOT NULL DEFAULT now(),
  last_seen_at     timestamptz NOT NULL DEFAULT now()
);

-- DROP + CREATE rather than CREATE OR REPLACE: replacing a view may only
-- APPEND columns. Nothing depends on this view (it is rebuilt every boot).
--
-- No disk column: a lease's disk lives in podman's store, which SQL cannot
-- see. `podenv list` prints `podman system df` alongside this.
DROP VIEW IF EXISTS podenv_usage;
CREATE VIEW podenv_usage AS
SELECT key,
       image,
       netns,
       container_port,
       host_port,
       env_var,
       dedicated_reason,
       created_by,
       created_at,
       last_seen_at,
       now() - last_seen_at AS idle
FROM podenv_lease
ORDER BY created_at;
```

- [ ] **Step 7: 寫開機 seed**

`patches/paperclip/opc-podenv-seed.sh`:

```sh
#!/bin/sh
# opc-podenv-seed.sh — source from the paperclip entrypoint.
#
# Applies the podenv control schema (podenv_lease + podenv_usage) into the
# devenv control database on every boot, and warns about a misconfigured port
# pool. Idempotent.
#
# Never fatal, for the same reason opc-devenv-seed.sh is not: podenv is an
# optional lane. An unreachable backend means the CLI reports exit 4 when used,
# not that paperclip fails to start. paperclip has no depends_on edge to the
# podenv service either — invariant 8's lesson, where `hermes` waiting on a
# one-shot meant any non-zero exit took down the whole agent runtime.
opc_podenv_seed() {
    opc_podenv_seed_schema || true
    opc_podenv_check_port_pool || true
}

opc_podenv_seed_schema() {
    _pe_host="${DEVENV_PG_HOST:-devenv-pg}"
    _pe_port="${DEVENV_PG_PORT:-5432}"
    _pe_user="${DEVENV_PG_ADMIN_USER:-postgres}"
    _pe_db="${DEVENV_CONTROL_DB:-devenv_control}"
    _pe_sql="${PODENV_LIB:-/usr/local/lib/podenv}/bootstrap.sql"

    if [ -z "${DEVENV_PG_ADMIN_PASSWORD:-}" ]; then
        echo "[podenv-seed] DEVENV_PG_ADMIN_PASSWORD unset — skipping (podenv disabled)" >&2
        return 0
    fi
    # The control DATABASE is created by opc-devenv-seed.sh, which the
    # entrypoint sources before this one. Do not create it here: two creators
    # of one database is exactly the kind of second writer this repo's PRD
    # forbids, and the devenv seed already handles the concurrent-create race.
    if ! PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" psql -h "$_pe_host" -p "$_pe_port" \
            -U "$_pe_user" -d "$_pe_db" -tAc 'SELECT 1' >/dev/null 2>&1; then
        echo "[podenv-seed] $_pe_db on $_pe_host:$_pe_port unreachable — skipping" >&2
        return 0
    fi
    if PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" PGOPTIONS='-c client_min_messages=warning' \
        psql -h "$_pe_host" -p "$_pe_port" -U "$_pe_user" -d "$_pe_db" \
             -q -v ON_ERROR_STOP=1 -f "$_pe_sql" >/dev/null 2>&1; then
        echo "[podenv-seed] $_pe_db schema ready (podenv_lease + podenv_usage)"
    else
        echo "[podenv-seed] schema apply failed — podenv will not work" >&2
    fi
    return 0
}

# The pool bounds are stated twice — once here for the CLI to allocate from,
# once in compose's `ports:` to publish. compose cannot do arithmetic, so
# disagreement is possible and its symptom is invisible: podenv hands out a
# port docker never published, and the operator's client simply cannot connect
# with nothing anywhere saying why. Same hazard as DEVENV_HTTP_PORT_RANGE_END.
opc_podenv_check_port_pool() {
    _pe_base="${PODENV_PORT_BASE:-23000}"
    _pe_count="${PODENV_PORT_COUNT:-16}"
    _pe_end="${PODENV_PORT_RANGE_END:-}"
    _pe_last=$((_pe_base + _pe_count - 1))

    if [ -n "$_pe_end" ] && [ "$_pe_end" -ne "$_pe_last" ]; then
        echo "[podenv-seed] WARNING PODENV_PORT_RANGE_END=$_pe_end but BASE+COUNT-1=$_pe_last." >&2
        echo "[podenv-seed]   podenv will lease ports docker has not published; clients will not connect." >&2
        echo "[podenv-seed]   Fix .env so RANGE_END = BASE + COUNT - 1, then recreate the podenv container." >&2
    fi

    # Read from INSIDE this container: the collision is with bind(0) calls made
    # here, and a container has its own network namespace. NOT `read a b <
    # /proc/...` — procfs reports st_size 0 and dash's read mishandles that
    # (see the same comment in opc-devenv-seed.sh, where it killed the
    # entrypoint under set -e).
    if [ -r /proc/sys/net/ipv4/ip_local_port_range ]; then
        set -- $(cat /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
        _pe_lo="${1:-}"; _pe_hi="${2:-}"
    fi
    if [ -n "${_pe_lo:-}" ] && [ -n "${_pe_hi:-}" ]; then
        if [ "$_pe_base" -le "$_pe_hi" ] && [ "$_pe_last" -ge "$_pe_lo" ]; then
            echo "[podenv-seed] WARNING podenv port pool ${_pe_base}-${_pe_last} overlaps the ephemeral range ${_pe_lo}-${_pe_hi}." >&2
            echo "[podenv-seed]   Move PODENV_PORT_BASE below ${_pe_lo}." >&2
        fi
    fi
}
```

- [ ] **Step 8: 寫 CLI 骨架 (`list` 與錯誤處理)**

`patches/paperclip/podenv/podenv`:

```sh
#!/bin/sh
# podenv — nested container leases for Paperclip agents.
#
#   podenv provision <key> --image REF --port N [--as VAR] [--url TEMPLATE]
#                          [--env K=V] [--password-env NAME]
#                          [--netns pasta|host] [--dedicated "reason"]
#                          [--volume HOST:CONTAINER] [--env-file PATH]
#   podenv release   <key>
#   podenv list
#
# Design notes (including the seven Phase 0 measurements this depends on) live
# in docs/superpowers/specs/2026-08-22-podenv-nested-container-lease-design.md.
# Short version: devenv covers shared, multi-tenant, modern backends; podenv
# covers what devenv cannot — daemons that refuse to share, and very old
# versions that only exist as an image.
#
# USE DEVENV FIRST. If devenv already provides it, this CLI refuses the image
# and tells you the devenv command instead. That is a mechanism, not advice.
#
# Reclamation is manual (`podenv release`). Nothing reclaims automatically —
# invariant 6b.
#
# Exit codes: 0 ok / 2 bad usage / 3 resources exhausted / 4 backend unreachable
set -eu

PODENV_LIB="${PODENV_LIB:-/usr/local/lib/podenv}"
DEVENV_LIB="${DEVENV_LIB:-/usr/local/lib/devenv}"

# Shared with devenv: env merge, password derivation, owner, reserved .env
# names, provider image families. See shared.sh's header.
. "$DEVENV_LIB/shared.sh"

PODENV_SOCK="${PODENV_SOCK:-/run/podenv/podman.sock}"
PODENV_DIAG="${PODENV_DIAG:-/run/podenv/diagnosis}"
PODENV_HOST_NAME="${PODENV_HOST_NAME:-podenv}"
PODENV_PORT_BASE="${PODENV_PORT_BASE:-23000}"
PODENV_PORT_COUNT="${PODENV_PORT_COUNT:-16}"

DEVENV_PG_HOST="${DEVENV_PG_HOST:-devenv-pg}"
DEVENV_PG_PORT="${DEVENV_PG_PORT:-5432}"
DEVENV_PG_ADMIN_USER="${DEVENV_PG_ADMIN_USER:-postgres}"
DEVENV_PG_ADMIN_PASSWORD="${DEVENV_PG_ADMIN_PASSWORD:-}"
DEVENV_CONTROL_DB="${DEVENV_CONTROL_DB:-devenv_control}"

die()  { echo "podenv: $1" >&2; exit "${2:-1}"; }
note() { echo "$1" >&2; }

podenv_psql() {
    PGPASSWORD="$DEVENV_PG_ADMIN_PASSWORD" \
    PGOPTIONS='-c client_min_messages=warning' psql \
        -h "$DEVENV_PG_HOST" -p "$DEVENV_PG_PORT" -U "$DEVENV_PG_ADMIN_USER" \
        -w -q -d "$DEVENV_CONTROL_DB" "$@"
}

# Three distinct failures, three distinct messages. The raw errors here are
# actively misleading: podman-remote's "Cannot connect to Podman ... try
# `podman machine init`" sends the reader to a macOS workflow that does not
# exist in this stack, and a socket that exists but refuses the connection
# looks identical to one that is not listening yet.
podenv_require_runtime() {
    if [ ! -S "$PODENV_SOCK" ]; then
        die "no podman socket at $PODENV_SOCK. The podenv compose service is not running (or its volume is not mounted here). Start it: docker compose up -d podenv" 4
    fi
    if ! podman --remote --url "unix://$PODENV_SOCK" version --format '{{.Server.Version}}' >/dev/null 2>&1; then
        _pr_diag=""
        [ -s "$PODENV_DIAG" ] && _pr_diag=" Runtime host reported: $(cat "$PODENV_DIAG")"
        die "the podman socket at $PODENV_SOCK exists but will not accept a connection. The access gate is the socket's OWNER uid, which must equal this user's ($(id -u)).${_pr_diag}" 4
    fi
    if [ -s "$PODENV_DIAG" ]; then
        note "podenv: WARNING runtime host self-test: $(cat "$PODENV_DIAG")"
    fi
}

podenv_require_control_schema() {
    [ -n "$DEVENV_PG_ADMIN_PASSWORD" ] \
        || die "DEVENV_PG_ADMIN_PASSWORD is unset — podenv shares devenv's control database and cannot reach it" 4
    podenv_psql -tAc 'SELECT 1 FROM podenv_lease LIMIT 1' >/dev/null 2>&1 && return 0
    die "podenv control schema not ready — table podenv_lease is missing in '$DEVENV_CONTROL_DB' on $DEVENV_PG_HOST:$DEVENV_PG_PORT. It is created by opc-podenv-seed.sh (paperclip's entrypoint). This is NOT resource exhaustion; releasing leases will not help." 4
}

podman_remote() { podman --remote --url "unix://$PODENV_SOCK" "$@"; }

podenv_slug() { echo "podenv_$(echo "$1" | tr '-' '_')"; }

cmd_list() {
    podenv_require_control_schema
    podenv_psql -c \
        "SELECT key, image, netns, host_port, env_var,
                CASE WHEN dedicated_reason IS NULL THEN ''
                     ELSE dedicated_reason END AS dedicated,
                date_trunc('second', idle) AS idle
         FROM podenv_usage"
    # Disk lives in podman's store, which SQL cannot see. Printed here rather
    # than left out: there is no disk quota in this lane (a hard cap needs
    # CAP_SYS_ADMIN, i.e. privileged), so visibility is the only control there
    # is — the same stance devenv takes with devenv_usage.
    if [ -S "$PODENV_SOCK" ]; then
        echo
        echo "podman store:"
        podman_remote system df 2>/dev/null || note "podenv: (store usage unavailable)"
    fi
}

case "${1:-}" in
    provision) shift; cmd_provision "$@" ;;
    release)   shift; cmd_release   "$@" ;;
    list)      shift; cmd_list      "$@" ;;
    -h|--help|help|"")
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
    *) die "unknown command '$1' (provision|release|list)" 2 ;;
esac
```

`cmd_provision` 與 `cmd_release` 在 Task 3 加入。本 task 先放兩個佔位以外的**真實**實作: 讓它們以 exit 2 明說尚未實作是錯的 (那會是假成功)。改為在本 task 就定義最小的 usage 檢查, 由 Task 3 補完:

```sh
cmd_provision() {
    [ $# -gt 0 ] || die "usage: podenv provision <key> --image REF --port N [--as VAR] [...]" 2
    die "podenv provision is not implemented yet (Task 3)" 2
}
cmd_release() {
    [ $# -gt 0 ] || die "usage: podenv release <key>" 2
    die "podenv release is not implemented yet (Task 3)" 2
}
```

把這兩個函式定義放在 `cmd_list` 之前。

- [ ] **Step 9: 接進 paperclip image**

`patches/paperclip/Dockerfile` 三處修改。

(a) **不需要 stage alias。** 一開始的計畫是 `ARG PODENV_IMAGE` + `FROM ${PODENV_IMAGE} AS podenv`
(緊接在既有的 `FROM ${NIX_SEED_IMAGE} AS nix-seed` 之後), 用來 `COPY --from=podenv` 取 podman
binary。**這條路被量測推翻**: `quay.io/podman/stable` 是 Fedora, 那顆 binary 動態連結 Fedora 的
libc/libselinux/libsemanage/libpam/libgpgme 等 22+ 顆 library, 在這個 image 的 Debian trixie base
上直接死在 loader (`libsubid.so.5: cannot open shared object file`)。「複製 binary 讓 client/server
同一個 build, 版本不會 skew」是預防性理由, 不是量測— 量了之後發現版本 skew 本身不構成問題 (見 (b))。
所以整個 stage alias、`COPY --from=podenv` (binary 與整組 vendored library)、私有 lib 目錄、linker
wrapper script 一起拿掉, 這一步什麼都不用加。

(b) 在既有的 apt 工具層 (`openssh-client jq` 那條 `RUN`) 加 `podman-remote`, 在 OPC overlay 段
`COPY opc/devenv/ /usr/local/lib/devenv/` 之後只留 CLI + seed 兩個 COPY:

```dockerfile
RUN echo "cli-tools-epoch: ${CLI_TOOLS_CACHE_EPOCH}" \
  && npm install --global --omit=dev @anthropic-ai/claude-code@latest @openai/codex@latest opencode-ai @google/gemini-cli@latest \
  && apt-get update \
  && apt-get install -y --no-install-recommends openssh-client jq podman-remote \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /paperclip \
  && chown node:node /paperclip
```

```dockerfile
# podenv CLI + its control schema (the nested container lease lane).
COPY opc/podenv/ /usr/local/lib/podenv/
COPY opc/opc-podenv-seed.sh /usr/local/bin/opc-podenv-seed.sh
# The podman CLIENT: Debian's own `podman-remote` package (installed in the
# apt layer above), symlinked to the plain name an agent types (see the
# chmod/ln chain below).
#
# NOT `COPY --from=podenv /usr/bin/podman` (measured to fail, and previously
# the approach here) — see (a) for why the Fedora binary cannot load on this
# Debian base. Measured directly against the running podenv service instead:
# a 5.4.2 podman-remote client against the 5.8.4 runtime host succeeds at
# `version` (reports `server: 5.8.4`), `run`, `ps`, `build` (built and tagged
# an image), `image inspect`, and `system df`. So the version-skew precaution
# was buying nothing, and apt's ~33MB package replaces a ~44MB binary plus 23
# vendored libraries plus a private-linker wrapper script.
```

(c) 既有的 `RUN chmod +x ...` 鏈補上 podenv, 並加三個 symlink (devenv/podenv/prototype 沿用既有慣例,
`podman` 是新加的第四個):

```dockerfile
RUN chmod +x /usr/local/bin/opc-nix-seed.sh /usr/local/bin/opc-mise-seed.sh \
             /usr/local/bin/opc-gh-seed.sh /usr/local/bin/opc-claude-seed.sh \
             /usr/local/bin/opc-devenv-seed.sh /usr/local/bin/opc-podenv-seed.sh \
             /usr/local/bin/opc-prototype-restore.sh \
             /usr/local/bin/opc-paperclip-bootstrap.sh /usr/local/bin/nix-entrypoint.sh \
    && chmod +x /usr/local/lib/devenv/devenv /usr/local/lib/devenv/providers/*.sh \
    && chmod +x /usr/local/lib/podenv/podenv \
    && chmod +x /usr/local/lib/prototype/prototype \
    && ln -sf /usr/local/lib/devenv/devenv /usr/local/bin/devenv \
    && ln -sf /usr/local/lib/podenv/podenv /usr/local/bin/podenv \
    && ln -sf /usr/local/lib/prototype/prototype /usr/local/bin/prototype \
    && ln -sf /usr/bin/podman-remote /usr/local/bin/podman
```

(d) 在既有的 `ENV MISE_DATA_DIR=...` 區塊之後加:

```dockerfile
# Set in the image ENV, not only exported by the entrypoint: `docker exec`
# interactive sessions do not inherit entrypoint-time exports (AGENTS.md
# records this for GH_CONFIG_DIR / GIT_SSH_COMMAND / GIT_CONFIG_GLOBAL), and
# an agent debugging by hand needs the wide `podman` interface to just work.
#
# Measured (all three forms reach the runtime host's 5.8.4): `podman-remote
# --remote --url unix:///run/podenv/podman.sock version`; the `podman` symlink
# above with CONTAINER_HOST set and no flags at all; and `podman --remote
# --url ... version` through that same symlink. So the skill's examples can
# say plain `podman run`, not `podman-remote --remote --url ... run`.
ENV CONTAINER_HOST=unix:///run/podenv/podman.sock \
    PODENV_LIB=/usr/local/lib/podenv
```

- [ ] **Step 10: 接進 paperclip entrypoint 與 compose**

`patches/paperclip/nix-entrypoint.sh`, 在既有的 devenv seed 之後:

```sh
# devenv control DB + schema (optional lane; never fatal).
. /usr/local/bin/opc-devenv-seed.sh
opc_devenv_seed

# podenv's own table in that same database (optional lane; never fatal).
# Ordered AFTER the devenv seed because that one creates the database.
. /usr/local/bin/opc-podenv-seed.sh
opc_podenv_seed
```

`docker-compose.yml` 的 paperclip service:

在 `volumes:` 加 (`opc-prototypes:/prototypes` 之後):

```yaml
      # podenv's API socket. A unix socket on a shared volume is reachable
      # across containers — the same mechanism nix-daemon uses. Mounted rw
      # because connecting to a unix socket requires write permission on it.
      #
      # There is deliberately NO depends_on edge to the podenv service: a
      # broken nested runtime must degrade to "leases fail when used", not to
      # "paperclip does not start" (invariant 8).
      - opc-podenv-sock:/run/podenv
```

在 `environment:` 的 devenv 區塊之後加:

```yaml
      # podenv: the nested container lease lane. It shares devenv's control
      # database (its own table), so it needs no extra credentials — only the
      # pool bounds, which must match this service's published range.
      PODENV_PORT_BASE: ${PODENV_PORT_BASE:-23000}
      PODENV_PORT_COUNT: ${PODENV_PORT_COUNT:-16}
      PODENV_PORT_RANGE_END: ${PODENV_PORT_RANGE_END:-23015}
```

- [ ] **Step 11: 更新 spec 的「兩個地方」為三個**

`docs/superpowers/specs/2026-08-22-podenv-nested-container-lease-design.md`, 把

```
這是**對 `patches/paperclip/devenv/devenv`
的一處修改**, 與上面 (b) 的保留名函式一起, 是本設計唯一要碰 devenv 的兩個地方。
```

改成

```
這是**對 `patches/paperclip/devenv/devenv`
的一處修改**。連同 (b), 本設計碰 devenv 共三處: 新增 `devenv/shared.sh` (兩支 CLI 共用的
真相 —— env merge、密碼推導、owner、保留變數名、provider image 家族)、`devenv` 改成 source
它並刪掉自己那三份重複定義、以及這裡的 guarded 查詢。
```

- [ ] **Step 12: rebuild 並跑測試**

```bash
docker compose build podenv paperclip \
  && docker compose up -d podenv paperclip \
  && sleep 40 && tests/podenv.sh
```

Expected: 全部 PASS, exit 0。若 `paperclip's podman client can drive the podenv server` FAIL, 表示 socket 連不上或 nested run 失敗 —— 先看 `docker compose exec paperclip ls -ln /run/podenv/`, socket 的 owner 必須是 1000。

- [ ] **Step 13: commit**

```bash
git add patches/paperclip/ docker-compose.yml tests/podenv.sh docs/superpowers/specs/
git commit -m "feat: podenv 登記表與 CLI 骨架, 與 devenv 共用一份真相"
```

---

### Task 3: `podenv provision` 與 `podenv release`

**Files:**
- Modify: `patches/paperclip/podenv/podenv`
- Test: `tests/podenv.sh`

**Interfaces:**
- Consumes: Task 2 的 `podenv_require_runtime`、`podenv_require_control_schema`、`podman_remote`、`podenv_slug`、`devenv_env_merge`、`devenv_derive_password`、`devenv_owner`
- Produces:
  - `podenv provision <key> --image REF --port N [--as VAR] [--url TEMPLATE] [--env K=V] [--password-env NAME] [--netns pasta|host] [--volume H:C] [--env-file PATH]` → 冪等, 寫 `.env`, 印 `KEY=VALUE`
  - `podenv release <key>` → 冪等
  - 容器名 `<slug>`, label `opc.podenv.lease=<slug>` (Task 5 的 restore 用它)

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/podenv.sh` 尾端 (在 `printf 'passed ...'` 之前):

```bash
echo "── provision / release ──"

PROBE_ENV=/tmp/podenv-gate.env
docker compose exec -T -u node paperclip sh -c "rm -f $PROBE_ENV" >/dev/null 2>&1

expect "provision writes the requested variable" "WHOAMI_ADDR" \
    docker compose exec -T -u node paperclip sh -c \
    "podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1
     sed 's/=.*//' $PROBE_ENV | grep -x WHOAMI_ADDR"

expect "the lease is reachable from paperclip over docker DNS" "200" \
    docker compose exec -T -u node paperclip sh -c \
    "addr=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     curl -s -o /dev/null -w '%{http_code}' --max-time 5 \"http://\$addr/\""

expect "provision is idempotent (same port on re-run)" "same" \
    docker compose exec -T -u node paperclip sh -c \
    "a=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1
     b=\$(grep '^WHOAMI_ADDR=' $PROBE_ENV | cut -d= -f2-)
     [ \"\$a\" = \"\$b\" ] && echo same || echo \"\$a != \$b\""

# `{{.Labels.opc.podenv.key}}` cannot work — the label name contains dots, so
# Go's template parser reads them as field traversal. `index` is the only way.
expect "the lease carries the restore label" "gate-probe" \
    docker compose exec -T -u node paperclip sh -c \
    'podman ps --filter label=opc.podenv.lease --format "{{index .Labels \"opc.podenv.key\"}}" 2>/dev/null | head -1'

expect "provision does not clobber other keys in .env" "KEEP_ME" \
    docker compose exec -T -u node paperclip sh -c \
    "echo 'KEEP_ME=yes' >> $PROBE_ENV
     podenv provision gate-probe --image docker.io/traefik/whoami --port 80 \
        --as WHOAMI_ADDR --env-file $PROBE_ENV >/dev/null 2>&1
     sed 's/=.*//' $PROBE_ENV | grep -x KEEP_ME"

expect "release removes container and row" "gone" \
    docker compose exec -T -u node paperclip sh -c \
    "podenv release gate-probe >/dev/null 2>&1
     n=\$(podman ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null | grep -c podenv_gate_probe || true)
     r=\$(podenv list 2>/dev/null | grep -c gate-probe || true)
     [ \"\$n\" = 0 ] && [ \"\$r\" = 0 ] && echo gone || echo \"containers=\$n rows=\$r\""
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
tests/podenv.sh
```

Expected: `── provision / release ──` 六條 FAIL (`podenv provision is not implemented yet`)。

- [ ] **Step 3: 實作 port 配置與 provision**

把 Task 2 放的兩個 `die "... not implemented yet"` 佔位換成下列實作 (放在 `cmd_list` 之前):

```sh
# Smallest free port in the pool. UNIQUE(host_port) makes the DB the arbiter,
# so concurrent callers race harmlessly — the loser retries. No table lock is
# needed here (unlike devenv's http provider) because a lease holds one port,
# not a contiguous block.
podenv_port_alloc() {
    _pa_key="$1"
    _pa_have="$(podenv_psql -tAc \
        "SELECT COALESCE(host_port::text,'') FROM podenv_lease WHERE key = '$_pa_key'" \
        2>/dev/null | tr -d '[:space:]')"
    if [ -n "$_pa_have" ]; then echo "$_pa_have"; return 0; fi
    _pa_n="$(podenv_psql -tAc "
        SELECT n FROM generate_series($PODENV_PORT_BASE,
                                     $((PODENV_PORT_BASE + PODENV_PORT_COUNT - 1))) AS n
        WHERE NOT EXISTS (SELECT 1 FROM podenv_lease l WHERE l.host_port = n)
        ORDER BY n LIMIT 1" | tr -d '[:space:]')"
    [ -n "$_pa_n" ] || die "no free podenv port (pool $PODENV_PORT_BASE-$((PODENV_PORT_BASE + PODENV_PORT_COUNT - 1))) — run 'podenv list' and release one" 3
    echo "$_pa_n"
}

# Render {{host}} / {{port}} / {{password}} in a --url template. The double
# brace form matches the expose.urlTemplate syntax this stack already uses;
# ${port} is the wrong syntax here and AGENTS.md records it as an expired
# example from upstream docs.
podenv_render_url() {
    printf '%s' "$1" \
        | sed -e "s|{{host}}|$2|g" -e "s|{{port}}|$3|g" -e "s|{{password}}|$4|g"
}

cmd_provision() {
    key=""; image=""; cport=""; as_var=""; url_tpl=""; netns="pasta"
    dedicated=""; pw_env=""; env_file="$PWD/.env"; run_env=""; run_vol=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --image)        image="${2:?--image needs a value}"; shift 2 ;;
            --port)         cport="${2:?--port needs a value}"; shift 2 ;;
            --as)           as_var="${2:?--as needs a value}"; shift 2 ;;
            --url)          url_tpl="${2:?--url needs a value}"; shift 2 ;;
            # Accumulated in a string and later re-split by the shell, so a
            # VALUE CONTAINING SPACES is not supported. Stated as a limit
            # rather than half-handled: the alternative (an eval-based array
            # emulation in POSIX sh) is worse than the restriction.
            --env)          run_env="$run_env ${2:?--env needs K=V}"; shift 2 ;;
            --volume)       run_vol="$run_vol ${2:?--volume needs HOST:CONTAINER}"; shift 2 ;;
            --password-env) pw_env="${2:?--password-env needs a NAME}"; shift 2 ;;
            --netns)        netns="${2:?--netns needs pasta|host}"; shift 2 ;;
            --dedicated)    dedicated="${2:?--dedicated needs a reason}"; shift 2 ;;
            --env-file)     env_file="${2:?--env-file needs a value}"; shift 2 ;;
            --memory)
                # Never accept a flag that does nothing. Measured: podman's
                # --memory is silently ignored in this topology (memory.max
                # stays `max`, no warning), and delegation cannot be obtained
                # without mounting the host's /sys/fs/cgroup.
                die "--memory does not exist here: per-lease memory limits cannot be enforced in this topology (cgroup delegation needs a host /sys/fs/cgroup mount, which invariant 6 forbids). The whole lane is capped by PODENV_MEM_LIMIT in .env." 2 ;;
            -*)             die "unknown flag: $1" 2 ;;
            *)  [ -z "$key" ] || die "unexpected argument: $1" 2; key="$1"; shift ;;
        esac
    done

    [ -n "$key" ]   || die "usage: podenv provision <key> --image REF --port N [--as VAR]" 2
    [ -n "$image" ] || die "--image is required (e.g. --image mysql:5.7)" 2
    [ -n "$cport" ] || die "--port is required — the port the daemon listens on INSIDE the container (mysql: 3306)" 2
    echo "$key" | grep -Eq '^[a-z][a-z0-9-]{1,40}$' \
        || die "invalid key '$key' — must match ^[a-z][a-z0-9-]{1,40}\$" 2
    echo "$cport" | grep -Eq '^[1-9][0-9]*$' || die "--port must be a positive integer" 2
    case "$netns" in pasta|host) ;; *) die "--netns must be pasta or host" 2 ;; esac

    # Default variable name from the image's own name: mysql:5.7 -> MYSQL_ADDR.
    if [ -z "$as_var" ]; then
        as_var="$(printf '%s' "$image" | sed 's|.*/||; s|:.*||; s|[^A-Za-z0-9]|_|g' \
                  | tr '[:lower:]' '[:upper:]')_ADDR"
    fi
    echo "$as_var" | grep -Eq '^[A-Z][A-Z0-9_]*$' \
        || die "--as '$as_var' is not a shell variable name (A-Z, 0-9, _)" 2

    podenv_require_runtime
    podenv_require_control_schema

    slug="$(podenv_slug "$key")"
    pw="$(devenv_derive_password "$key" podenv)" \
        || die "cannot derive the lease password — DEVENV_SECRET_SALT is unset" 4
    hport="$(podenv_port_alloc "$key")"

    existing="$(podenv_psql -tAc "SELECT key FROM podenv_lease WHERE key = '$key'" \
                | tr -d '[:space:]')"

    # Register BEFORE creating: the row is what makes the port exclusive, so it
    # has to exist before anything is bound to it.
    if [ -z "$existing" ]; then
        podenv_psql -v ON_ERROR_STOP=1 -c "
            INSERT INTO podenv_lease
              (key, slug, image, netns, container_port, host_port, env_var,
               dedicated_reason, created_by)
            VALUES ('$key', '$slug', '$image', '$netns', $cport, $hport, '$as_var',
                    $( [ -n "$dedicated" ] && printf "'%s'" "$dedicated" || echo NULL ),
                    '$(devenv_owner)')" >/dev/null
    else
        podenv_psql -c "UPDATE podenv_lease SET last_seen_at = now() WHERE key = '$key'" >/dev/null
    fi

    # Idempotent container creation. `podman ps -a` is authoritative for its
    # own containers, unlike prototype-restore's problem where a DB row claimed
    # `running` after the process was long gone — the containers ARE this
    # service's child processes, so if it is up and they are listed, they exist.
    if podman_remote container exists "$slug" 2>/dev/null; then
        podman_remote start "$slug" >/dev/null 2>&1 || true
    else
        set -- run -d --name "$slug" \
            --label "opc.podenv.lease=$slug" \
            --label "opc.podenv.key=$key" \
            --restart no \
            --network="$netns"
        [ "$netns" = host ] || set -- "$@" -p "${hport}:${cport}"
        [ -z "$pw_env" ] || set -- "$@" -e "${pw_env}=${pw}"
        for _e in $run_env; do set -- "$@" -e "$_e"; done
        for _v in $run_vol; do set -- "$@" -v "$_v"; done
        set -- "$@" "$image"
        podman_remote "$@" >/dev/null \
            || die "podman could not start the lease. Run the same image by hand to see why: podman run --rm -it $image" 1
    fi

    # With --netns host there is no port remapping at all (measured: -p is
    # discarded without a warning), so the reachable port IS the container's.
    [ "$netns" = host ] && hport="$cport"

    out_file="$(mktemp)"
    if [ -n "$url_tpl" ]; then
        printf '%s=%s\n' "$as_var" \
            "$(podenv_render_url "$url_tpl" "$PODENV_HOST_NAME" "$hport" "$pw")" > "$out_file"
    else
        printf '%s=%s:%s\n' "$as_var" "$PODENV_HOST_NAME" "$hport" > "$out_file"
    fi
    devenv_env_merge "$env_file" "$out_file"
    if [ -n "$existing" ]; then
        note "podenv: '$key' (existing) → $env_file"
    else
        note "podenv: '$key' provisioned → $env_file"
    fi
    cat "$out_file"
    rm -f "$out_file"
}

cmd_release() {
    key="${1:?usage: podenv release <key>}"
    podenv_require_control_schema
    if [ -z "$(podenv_psql -tAc "SELECT key FROM podenv_lease WHERE key = '$key'" | tr -d '[:space:]')" ]; then
        note "podenv: '$key' (absent)"; return 0
    fi
    slug="$(podenv_slug "$key")"
    if [ -S "$PODENV_SOCK" ]; then
        podman_remote rm -f -v "$slug" >/dev/null 2>&1 || true
    else
        note "podenv: WARNING the runtime host is not reachable, so the container for"
        note "podenv:   '$key' was NOT removed. The registry row is going away, which"
        note "podenv:   frees port $(podenv_psql -tAc "SELECT host_port FROM podenv_lease WHERE key = '$key'" | tr -d '[:space:]') for the next lease — and a container still"
        note "podenv:   holding it would make that lease fail to start. Bring podenv up"
        note "podenv:   and run: podman rm -f -v $slug"
    fi
    podenv_psql -c "DELETE FROM podenv_lease WHERE key = '$key'" >/dev/null
    note "podenv: '$key' released"
}
```

- [ ] **Step 4: rebuild 並跑測試**

```bash
docker compose build paperclip && docker compose up -d paperclip \
  && sleep 40 && tests/podenv.sh
```

Expected: 全部 PASS (25 條), exit 0。

- [ ] **Step 5: commit**

```bash
git add patches/paperclip/podenv/podenv tests/podenv.sh
git commit -m "feat: podenv provision/release — 冪等的巢狀容器租約"
```

---

### Task 4: 與 devenv 的機制性分工 (保留名 + 路由 gate)

**Files:**
- Modify: `patches/paperclip/podenv/podenv`
- Test: `tests/podenv.sh`

**Interfaces:**
- Consumes: Task 2 的 `devenv_env_name_reserved`、`devenv_provider_image_families`
- Produces: `podenv provision` 在兩種情況以 exit 2 拒絕, 訊息含 devenv 的正確指令

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/podenv.sh` 尾端 (在 `printf 'passed ...'` 之前):

```bash
echo "── devenv coexistence ──"

# (b) variable-name partition. Refusing DATABASE_URL is what makes "postgres
# from devenv + Milvus from podenv" the only possible shape.
expect "refuses a variable name devenv owns" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision name-clash --image docker.io/traefik/whoami --port 80 \
             --as DATABASE_URL 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv" && echo refused || echo "rc=$rc out=$out"'
expect "refuses the DEV_PORT_<n> family too" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision name-clash --image docker.io/traefik/whoami --port 80 \
             --as DEV_PORT_2 2>&1); rc=$?
     [ "$rc" = 2 ] && echo refused || echo "rc=$rc out=$out"'

# (c) route gate. redis is a family devenv serves, so an unqualified request
# must be refused and must name the devenv command.
expect "route gate refuses an image devenv already serves" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision legacy-cache --image docker.io/library/redis:5 --port 6379 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "devenv provision" && echo refused || echo "rc=$rc out=$out"'
expect "--dedicated opens the gate and the reason is persisted" "pg9.6 client API" \
    docker compose exec -T -u node paperclip sh -c \
    'podenv provision legacy-pg --image docker.io/library/postgres:9.6 --port 5432 \
        --dedicated "pg9.6 client API" --password-env POSTGRES_PASSWORD \
        --env-file /tmp/podenv-dedicated.env >/dev/null 2>&1
     podenv list 2>/dev/null | grep -o "pg9.6 client API" | head -1'
expect "the dedicated reason shows up in devenv list too" "pg9.6 client API" \
    docker compose exec -T -u node paperclip sh -c \
    'devenv list 2>/dev/null | grep -o "pg9.6 client API" | head -1'
expect "--memory is refused rather than silently ignored" "refused" \
    docker compose exec -T -u node paperclip sh -c \
    'out=$(podenv provision mem-probe --image docker.io/traefik/whoami --port 80 --memory 128m 2>&1); rc=$?
     [ "$rc" = 2 ] && echo "$out" | grep -q "PODENV_MEM_LIMIT" && echo refused || echo "rc=$rc out=$out"'
# cleanup so re-runs start clean
docker compose exec -T -u node paperclip sh -c \
    'podenv release legacy-pg >/dev/null 2>&1; rm -f /tmp/podenv-dedicated.env' >/dev/null 2>&1
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
tests/podenv.sh
```

Expected: `── devenv coexistence ──` 中前四條 FAIL (名字與 image 都沒有被拒), 最後兩條可能已 PASS (`--memory` 在 Task 3 已擋)。

- [ ] **Step 3: 實作兩道 gate**

在 `patches/paperclip/podenv/podenv` 的 `cmd_provision` 裡, `--as` 的格式檢查之後、`podenv_require_runtime` 之前插入:

```sh
    # (b) Variable-name partition. devenv owns a fixed set of .env names; if
    # podenv could write them, one lease would silently overwrite the other's
    # connection string. The list comes from devenv/shared.sh — one home, so
    # there is no drift class here.
    if devenv_env_name_reserved "$as_var"; then
        die "'$as_var' is a variable name devenv owns (DATABASE_URL, VALKEY_URL, DEV_PORT, DEV_PORT_<n>, DEV_URL, DEV_HOST, HOST). Pick another with --as, e.g. --as ${as_var}_LEGACY. A devenv lease and a podenv lease share one .env, which only works while their variable names do not collide." 2
    fi

    # (c) Route gate. devenv already serves some image families, and it should
    # win by default: it is the shared, multi-tenant, modern lane. But an old
    # version of the SAME family is a legitimate podenv case (devenv-pg is
    # pg18; a project stuck on pg9.6 cannot use it), so this is not an absolute
    # ban — it is a detour that costs something. The reason is persisted and
    # listed, which is what keeps it from being a rubber stamp: the same
    # reasoning that keeps `prototype destroy` from having a --yes flag.
    _img_family="$(printf '%s' "$image" | sed 's|.*/||; s|:.*||')"
    _img_provider="$(devenv_provider_image_families \
        | sed -n "s|^${_img_family}=||p" | head -1)"
    if [ -n "$_img_provider" ] && [ -z "$dedicated" ]; then
        die "devenv already serves '$_img_family' — use it instead:
    devenv provision $key --with $_img_provider
devenv is the shared, multi-tenant lane and it should win whenever it can.
If you genuinely need a dedicated or older one (devenv-pg is pg18, devenv-valkey
is valkey 9.1), say why and it will be recorded on the lease:
    podenv provision $key --image $image --port $cport --dedicated \"<reason>\"" 2
    fi
```

- [ ] **Step 4: rebuild 並跑測試**

```bash
docker compose build paperclip && docker compose up -d paperclip \
  && sleep 40 && tests/podenv.sh
```

Expected: 全部 PASS (31 條), exit 0。

- [ ] **Step 5: commit**

```bash
git add patches/paperclip/podenv/podenv tests/podenv.sh
git commit -m "feat: podenv 與 devenv 的分工靠機制 — 保留變數名與路由 gate"
```

---

### Task 5: 開機把租約叫回來

**Files:**
- Create: `patches/podenv/opc-podenv-restore.sh`
- Modify: `patches/podenv/Dockerfile`
- Modify: `patches/podenv/opc-podenv-entrypoint.sh`
- Test: `tests/podenv.sh`

**Interfaces:**
- Consumes: Task 3 寫上的 label `opc.podenv.lease`
- Produces: podenv 容器重啟後, 帶該 label 的容器自己回到 running

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/podenv.sh` 尾端 (在 `printf 'passed ...'` 之前):

```bash
echo "── restore ──"

expect "a lease survives a podenv restart" "running" \
    sh -c 'docker compose exec -T -u node paperclip podenv provision restore-probe \
             --image docker.io/traefik/whoami --port 80 --as RESTORE_ADDR \
             --env-file /tmp/podenv-restore.env >/dev/null 2>&1
           docker compose restart podenv >/dev/null 2>&1
           for i in $(seq 1 30); do
             s=$(docker compose exec -T -u 1000 -e HOME=/home/podman \
                   -e XDG_RUNTIME_DIR=/run/user/1000 podenv \
                   podman ps --filter name=podenv_restore_probe --format "{{.State}}" 2>/dev/null | tr -d "\r")
             [ "$s" = "running" ] && { echo running; break; }
             sleep 2
           done'
docker compose exec -T -u node paperclip sh -c \
    'podenv release restore-probe >/dev/null 2>&1; rm -f /tmp/podenv-restore.env' >/dev/null 2>&1
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
tests/podenv.sh
```

Expected: `a lease survives a podenv restart` FAIL (got '')。

- [ ] **Step 3: 寫 restore script**

`patches/podenv/opc-podenv-restore.sh`:

```sh
#!/bin/sh
# opc-podenv-restore.sh — bring leased containers back after a restart.
#
# Backgrounded by the entrypoint. It has to be: the socket it waits for is
# created by the process the entrypoint is about to exec, so running this in
# the foreground would deadlock the boot. Same shape and same reason as
# opc-prototype-restore.sh in the paperclip image.
#
# Why an explicit start rather than --restart=always: podman's restart policy
# needs podman to be alive to act on it, and every boot is a NEW service
# process. The label plus this loop is the mechanism, not a safety net.
#
# Unlike prototype-restore, liveness needs no probing. Those preview servers
# were children of a server whose database still claimed `running` long after
# the process died. Here the containers ARE this service's descendants: if the
# service is up and podman lists them, they exist.
#
# Never fatal: this is recovery. Every lease is also restartable by hand with
# `podman start <slug>`.
set -u

PODENV_UID="${PODENV_UID:-1000}"
PODENV_GID="${PODENV_GID:-1000}"
PODENV_SOCK_DIR="${PODENV_SOCK_DIR:-/run/podenv}"
PODENV_SOCK="${PODENV_SOCK_DIR}/podman.sock"

_n=0
while [ ! -S "$PODENV_SOCK" ] && [ "$_n" -lt 60 ]; do
    _n=$((_n + 1)); sleep 2
done
if [ ! -S "$PODENV_SOCK" ]; then
    echo "[podenv-restore] socket never appeared — nothing restored" >&2
    exit 0
fi

_ids="$(setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups \
    env HOME=/home/podman XDG_RUNTIME_DIR="/run/user/${PODENV_UID}" \
    podman ps -a --filter label=opc.podenv.lease --format '{{.Names}}' 2>/dev/null)"
[ -n "$_ids" ] || { echo "[podenv-restore] no leases to restore"; exit 0; }

for _c in $_ids; do
    if setpriv --reuid "$PODENV_UID" --regid "$PODENV_GID" --clear-groups \
        env HOME=/home/podman XDG_RUNTIME_DIR="/run/user/${PODENV_UID}" \
        podman start "$_c" >/dev/null 2>&1; then
        echo "[podenv-restore] started $_c"
    else
        echo "[podenv-restore] WARNING could not start $_c — run 'podman start $_c' to see why" >&2
    fi
done
exit 0
```

- [ ] **Step 4: 從 Dockerfile 與 entrypoint 掛上去**

`patches/podenv/Dockerfile`, 把既有的 entrypoint COPY/chmod 換成:

```dockerfile
COPY opc-podenv-entrypoint.sh /usr/local/bin/opc-podenv-entrypoint.sh
COPY opc-podenv-restore.sh /usr/local/bin/opc-podenv-restore.sh
RUN chmod +x /usr/local/bin/opc-podenv-entrypoint.sh /usr/local/bin/opc-podenv-restore.sh
```

`patches/podenv/opc-podenv-entrypoint.sh`, 在最後那行 `exec setpriv ...` **之前**插入:

```sh
# Leased containers are this service's descendants, so they died with the
# previous instance of it. Backgrounded because it waits for the socket the
# exec below creates.
PODENV_UID="$PODENV_UID" PODENV_GID="$PODENV_GID" PODENV_SOCK_DIR="$PODENV_SOCK_DIR" \
    /usr/local/bin/opc-podenv-restore.sh &
```

- [ ] **Step 5: rebuild 並跑測試**

```bash
docker compose build podenv && docker compose up -d podenv \
  && sleep 15 && tests/podenv.sh
```

Expected: 全部 PASS (32 條), exit 0。

- [ ] **Step 6: commit**

```bash
git add patches/podenv/ tests/podenv.sh
git commit -m "feat: podenv 開機把帶 lease label 的容器叫回來"
```

---

### Task 6: skill (決策表正本) 與兩處指標

**Files:**
- Create: `patches/paperclip/skills/podenv/SKILL.md`
- Modify: `patches/paperclip/skills/devenv/SKILL.md`
- Modify: `patches/paperclip/skills/container-tools/SKILL.md`
- Modify: `patches/paperclip/opc-paperclip-bootstrap.sh`
- Test: `tests/podenv.sh`

**Interfaces:**
- Consumes: Task 3/4 的 CLI 介面與拒絕訊息
- Produces: company skill library 裡有 `podenv`; Prototyper 的 `desiredSkills` 含它

- [ ] **Step 1: 寫失敗的測試**

追加到 `tests/podenv.sh` 尾端 (在 `printf 'passed ...'` 之前):

```bash
echo "── skill ──"

check "podenv skill is on disk in the image" \
    docker compose exec -T paperclip test -s /opt/opc-skills/podenv/SKILL.md
expect "the decision table has exactly one home" "1" \
    sh -c 'grep -rl "devenv 已提供就優先" patches/paperclip/skills/ | wc -l | tr -d " "'
expect "devenv skill points forward without copying the table" "1" \
    sh -c 'grep -c "podenv" patches/paperclip/skills/devenv/SKILL.md | tr -d " "'
check "Prototyper lists podenv in desiredSkills" \
    sh -c 'grep -q "podenv" patches/paperclip/opc-paperclip-bootstrap.sh'
```

- [ ] **Step 2: 跑測試確認它失敗**

```bash
tests/podenv.sh
```

Expected: `── skill ──` 四條全 FAIL。

- [ ] **Step 3: 寫 skill 正本**

`patches/paperclip/skills/podenv/SKILL.md`:

```markdown
---
name: podenv
description: Lease a whole containerized daemon (any OCI image, including very old versions) when devenv cannot serve it — a daemon that refuses to be multi-tenant, or a version devenv does not run. Use only after checking devenv first.
---

# podenv — nested container leases

`devenv` is the shared, multi-tenant, modern lane: PostgreSQL 18 with
pgvector, Valkey 9.1, a preview port. `podenv` is the other half — **a whole
container, all yours**, from any image.

## Which one

**Check devenv first, every time.** If devenv can serve it, use devenv: it is
shared, it is already running, and it costs no disk.

| What you need | Use |
|---|---|
| PostgreSQL, any modern version | `devenv provision <key> --with postgres` |
| Redis / Valkey, any modern version | `devenv provision <key> --with valkey` |
| An HTTP port for a dev server | `devenv provision <key> --with http` |
| MySQL / MariaDB, any version | `podenv` |
| Milvus, Qdrant, Elasticsearch, Kafka, … | `podenv` |
| A daemon that cannot be multi-tenant | `podenv` |
| **An old version of something devenv serves** (pg 9.6, redis 5) | `podenv --dedicated "<why>"` |

**devenv 已提供就優先使用。** podenv enforces this: ask it for a `postgres`,
`pgvector`, `valkey` or `redis` image and it refuses, and tells you the devenv
command. The refusal is not absolute — an OLD version of those families is a
real podenv case — but you must say why with `--dedicated "<reason>"`, and the
reason is stored on the lease and shown in `podenv list` and `devenv list`.
Write a reason a person can act on ("pg9.6, devenv is pg18, client API is
incompatible"), not "needed for the task".

**The two leases coexist.** Use the SAME key for both and they land in the
same `.env`:

```sh
devenv provision myproj --with postgres          # -> DATABASE_URL
podenv provision myproj --image milvus/milvus:v2.5.0 --port 19530 \
       --as MILVUS_ADDR                          # -> MILVUS_ADDR
```

podenv refuses to write any variable name devenv owns (`DATABASE_URL`,
`VALKEY_URL`, `DEV_PORT`, `DEV_PORT_<n>`, `DEV_URL`, `DEV_HOST`, `HOST`), so
one lease can never overwrite the other's connection string.

## Leasing

```sh
podenv provision <key> --image REF --port <port-inside-the-container> [flags]
```

`--port` is where the daemon listens INSIDE its container (mysql: 3306). The
address you connect to is allocated for you — read it from `.env`, never
hardcode it.

| Flag | What it does |
|---|---|
| `--as VAR` | The `.env` variable to write. Defaults to `<IMAGE>_ADDR`. |
| `--url TPL` | Build a full URL. `{{host}}`, `{{port}}`, `{{password}}`. Double braces — `${port}` is wrong. |
| `--env K=V` | An environment variable for the container. Repeatable. |
| `--password-env NAME` | Put the lease's derived password in the container under `NAME`, and make it available to `{{password}}`. |
| `--volume H:C` | Bind-mount. `/prototypes` is visible to the runtime host, so `--volume /prototypes/myproj:/app` works. |
| `--netns host` | Only when pasta cannot run the image. **There is no port remapping in this mode**, so `--port` must already be free across every lease. |
| `--dedicated "reason"` | Required to override the route gate above. |

A worked example — MySQL 5.7, which is exactly what this lane exists for:

```sh
podenv provision legacy-erp --image mysql:5.7 --port 3306 \
  --password-env MYSQL_ROOT_PASSWORD \
  --env MYSQL_DATABASE=erp \
  --as MYSQL_URL --url 'mysql://root:{{password}}@{{host}}:{{port}}/erp'
```

Then read `MYSQL_URL` from `.env` like any application would. **Nothing in
your code should know podenv exists.**

## Rules

**`provision` is idempotent — run it freely.** Re-running returns the same
container, the same port and the same password, so it is safe at the start of
every session. It is how you pick a lease back up, not just how you create one.

**Never run `podenv release`.** It deletes the container AND its data volumes.
Releasing is the user's decision, not a tidy-up step.

**There is no memory limit per lease.** `podenv provision --memory` is refused
on purpose, and bare `podman run --memory` is **silently ignored** in this
topology — it does not error, the limit simply does not exist. Do not rely on
one. The whole lane shares one cap set by the operator.

**Prefer the lease over bare `podman run`.** You do have the full `podman`
command and you may use it for builds and throwaway checks. But only leases
are brought back after a restart and only leases appear in `podenv list` /
`devenv list` — anything you start by hand vanishes on the next
`docker compose up` with nothing recording that it existed.

**No `apt-get`, here or anywhere.** Same rule as everywhere else in this
stack: it writes to a container layer that a rebuild throws away.

## Inspecting

`podenv list` shows every lease (image, netns, port, variable, dedicated
reason, idle time) plus podman's disk usage. **There is no disk quota in this
lane** — a hard cap is not possible without privileges this stack does not
grant — so if the store is large, say so to the user rather than deleting
anything.

## Failure

| Exit | Meaning |
|---|---|
| 2 | Bad usage, a reserved variable name, or the route gate. Read the message — it names the devenv command to use instead. |
| 3 | Port pool exhausted. Report it to the user; they decide what to release. |
| 4 | The runtime host or the registry is unreachable. Report it — this is not something you can fix. |
```

- [ ] **Step 4: 加兩處指標 (不複製決策表)**

`patches/paperclip/skills/devenv/SKILL.md`, 在 `## Rules` 之前插入:

```markdown
## When devenv is the wrong tool

devenv serves shared, multi-tenant, modern backends. A daemon that refuses to
be multi-tenant, or a version devenv does not run (very old MySQL, pg 9.6),
belongs to the `podenv` lane — load the **podenv** skill; it holds the decision
table. Do not try to force such a daemon into devenv.
```

`patches/paperclip/skills/container-tools/SKILL.md`, 在檔尾加:

```markdown
## Need a service, not a tool?

A daemon (database, cache, queue, vector store) is not a tool install. Lease it:
`devenv` for shared modern backends, `podenv` for a whole container of your own
(any image, including very old versions). The **podenv** skill holds the
decision table for which one.
```

- [ ] **Step 5: 讓 bootstrap 裝這個 skill 並指派給 Prototyper**

`patches/paperclip/opc-paperclip-bootstrap.sh`: 找到既有的 vendored/first-party skill 安裝清單, 把 `podenv` 加進去 (與 `devenv`、`prototype-workspace` 並列); 找到 Prototyper 的 `paperclipSkillSync.desiredSkills`, 把 `podenv` 加進那個陣列。

**這一步必須是 reconcile 而非 create-only** —— AGENTS.md 已記: 安裝器若只在缺席時建立, 改過的 skill 內容永遠到不了跑著的 stack。SKILL.md 內容要走
`PATCH /companies/<c>/skills/<id>/files` 帶 `path:SKILL.md` (`updateSkill` 會收下 `markdown` 然後靜靜丟掉並回 200), 且要驗回應裡有 `.path` 才算成功。既有程式碼已經是這個形狀, 照同一條路徑加即可。

- [ ] **Step 6: rebuild 並跑測試**

```bash
docker compose build paperclip && docker compose up -d paperclip \
  && sleep 40 && docker compose up paperclip-bootstrap && tests/podenv.sh
```

Expected: 全部 PASS (36 條), exit 0。

- [ ] **Step 7: commit**

```bash
git add patches/paperclip/skills/ patches/paperclip/opc-paperclip-bootstrap.sh tests/podenv.sh
git commit -m "feat: podenv skill 是決策表正本, devenv 與 container-tools 只放指標"
```

---

### Task 7: 乾淨機器、文件、gate 收尾

**Files:**
- Modify: `scripts/setup.sh`
- Modify: `tests/fresh-install.sh`
- Modify: `SETUP.md`
- Modify: `AGENTS.md`

**Interfaces:**
- Consumes: 前六個 task 的全部產出
- Produces: 乾淨機器 `git clone` → `scripts/setup.sh` 之後 podenv 可用, 無手動步驟

- [ ] **Step 1: 先確認它現在是壞的 (乾淨安裝的 build 順序)**

```bash
grep -n "compose build nix-seed" scripts/setup.sh
```

Expected: 只有 nix-seed 被單獨 build — 這對 nix-seed 仍然是真的 hazard (paperclip 的
`FROM ${NIX_SEED_IMAGE}` 在乾淨機器上會解析不到就轉去 registry, 死在
`pull access denied for <prefix>/nix-seed`, 見 AGENTS.md)。**podenv 沒有這條 hazard**:
Task 2 改成 apt 裝 `podman-remote` 之後, `patches/paperclip/Dockerfile` 已經沒有任何
`FROM` 指向 podenv image (拿掉了量測後發現不需要的 stage alias), 所以 podenv 的 build
順序與 paperclip 的 build 完全無關 — 不必再單獨 build 它。

- [ ] **Step 2: 修 setup.sh**

`scripts/setup.sh` 單獨 build nix-seed 的那一行維持原樣 (`docker compose build nix-seed`),
**不需要**加 podenv: 沒有 `FROM` 引用它, 就沒有 build-ordering hazard, 沿用既有的
nix-seed 注解即可, 不必修改。

- [ ] **Step 3: 修 fresh-install.sh 的 port 位移**

`tests/fresh-install.sh` 對每個 port 做 +1000 的改寫。把 `PODENV_PORT_BASE`、`PODENV_PORT_RANGE_END` 加進去 (base 24000 / end 24015), 與既有的 `DEVENV_HTTP_PORT_*` 同一處。

- [ ] **Step 4: compose 的 paperclip build 區段不需要 podenv 條目**

`docker-compose.yml` 的 paperclip build 區段維持只有 nix-seed 這一個 additional context / arg:

```yaml
    build:
      context: ./upstream/paperclip
      dockerfile: opc/Dockerfile
      additional_contexts:
        nix-seed: "service:nix-seed"
      args:
        NIX_SEED_IMAGE: ${IMAGE_PREFIX:-opc}/nix-seed:local
```

**不要**加 `podenv: "service:podenv"` additional context 或 `PODENV_IMAGE` build arg —
Task 2 拿掉 stage alias之後, paperclip 的 build 再也不需要 podenv image 存在, 這一整類
「乾淨安裝 build 順序」失敗模式對 podenv 不成立。

- [ ] **Step 5: 寫 SETUP.md 段落**

在 devenv 的段落之後加一節 `## podenv — 巢狀容器租約`, 內容:

- 它解決什麼 (不能 multi-tenant 的 daemon、超舊版本), 以及**先試 devenv**
- 常用指令: `docker compose exec paperclip podenv list`、`podenv release <key>`
- 你要拿 client 連進去: port 發佈在 `127.0.0.1:23000-23015`, 具體哪個看 `podenv list`
- MySQL 5.7 的完整實例 (照 skill 那段)
- 改 `PODENV_MEM_LIMIT` 之後要 `docker compose up -d podenv`
- 改 port range 之後要 **recreate podenv 容器** (docker 的發佈 port 在建立容器時固定)
- 疑難: `docker compose exec podenv cat /run/podenv/diagnosis` 是第一個要看的地方

- [ ] **Step 6: 更新 AGENTS.md**

三處:

1. **架構**段, devenv 條目之後加 podenv 條目: 一句話定位 + 指向 spec + 「不變量 6 的兩條都完好, 但多一項 `seccomp=unconfined` 與一項 `/dev/net/tun` device 授予, 由 `tests/podenv.sh` 的結構檢查釘住」。
2. **常用指令**段加三行 (`podenv list` / `podenv release` / `tests/podenv.sh`)。
3. **已知坑**段加三條, 每一條都是量到的:
   - `podman` 的 socket 是 0600 且它在建好 listener **之後**才 chmod 回去, 所以跨容器存取靠 **uid 對齊** (podenv 的 runtime uid == paperclip 的 `node`), 不要試 setgid 目錄或共用 gid —— 帶驗證的重試迴圈會報告成功然後被改回去。
   - `podman run --memory` 在這個拓撲下**被靜靜忽略** (`memory.max` 是 `max`, 零警告), 兩個已量到的成因 (ro 的 `/sys/fs/cgroup`、image 的 `cgroups="disabled"`) 未隔離。唯一有效的旋鈕是 compose 的 `mem_limit`, 而驗證要讀 **podenv 自己**的 cgroup 檔, 讀 nested 那份會讓測試在錯的地方變綠。
   - nested 容器的網路只有兩種可用: pasta (要 `/dev/net/tun`, 有 `-p` 重映射) 與 host netns (**`-p` 被靜靜丟掉**)。bridge/netavark **不可能** —— 它要寫 `/proc/sys`, docker 掛 ro。而上游 image 的 containers.conf 預設是 host, 所以我們覆蓋成 pasta, 且**只改那一行** (`userns="host"` 拿掉會讓 `/prototypes` 的檔案歸屬壞掉)。
- [ ] **Step 7: 跑三條 gate**

```bash
tests/audit-bootstrap.sh; tests/connectivity.sh; tests/podenv.sh
```

Expected: 三條都綠。`tests/scientist.sh` 不受影響 (podenv 沒碰 hermes), 但也跑一次確認沒有回歸。

- [ ] **Step 8: commit**

```bash
git add scripts/setup.sh tests/fresh-install.sh docker-compose.yml SETUP.md AGENTS.md
git commit -m "docs: podenv 的乾淨安裝路徑、操作說明與三條踩過的坑"
```

- [ ] **Step 9: 開箱排練 (慢, 但這是唯一算數的驗證)**

```bash
tests/fresh-install.sh
```

Expected: clone 出去的那份走完 `setup.sh` 之後 `audit-bootstrap` + `connectivity` + `scientist` + `podenv` 四條都綠。**不要在這台上 `docker compose down -v`** —— AGENTS.md 明文, 那會毀掉 community/board/memory/prototype/租約。

---

## Notes for the implementer

- **不要跑 `scripts/prepare.sh` 來同步 `patches/podenv/`。** prepare.sh 處理的是 submodule 的 `patches/<proj>/` → `upstream/<proj>/opc/`; podenv 跟 nix-seed 一樣是直接的 build context。但**改了 `patches/paperclip/` 之後一定要跑 prepare.sh**, 否則 build 拿到的是舊的 `upstream/paperclip/opc/`。
- **每個 task 的最後一步是 rebuild 對應的 image。** `docker compose up -d` 不會因為 `patches/` 變了就重建。
- **每條測試都要看它先失敗。** 這個 repo 的紀錄裡有多個「檢查永遠成立」的 bug (`api_patch_raw` 結尾的 `|| true` 讓 `&&` 永遠成立)。一條沒看過它 FAIL 的檢查, 不算檢查。
