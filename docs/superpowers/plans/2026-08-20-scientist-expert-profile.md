# Scientist Expert Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 OPC stack 加入一個與參謀長硬隔離的「科學家」專家 agent —— 自己的 hermes profile、自己的 Buzz 身分、自己的記憶，由 Paperclip 以 `hermes_gateway` adapter 指派，並可在既有的 hermes dashboard 一次登入下觀察。

**Architecture:** 那台目前零消費者的 `hermes` gateway 容器開 `GATEWAY_MULTIPLEX_PROFILES=1`，成為所有專家 profile 的宿主；專家 profile 住在新的 `hermes-profiles` volume，掛在 `hermes:/opt/data/profiles` 與 `hermes-dashboard:/opt/data/profiles` 兩處。參謀長的 `frontdoor-hermes` volume **不掛進 hermes 容器**，所以隔離是容器級的；dashboard 兩顆都掛，switcher 一次看到全部。設計與量測依據見 `docs/superpowers/specs/2026-08-20-scientist-expert-profile-design.md`。

**Tech Stack:** docker compose · hermes-agent v2026.8.16 (Python) · Paperclip canary/v2026.722.1-canary.0 (`hermes_gateway` built-in adapter) · buzz CLI (Rust) · TencentDB Agent Memory v2.0.0 · POSIX sh

## Global Constraints

- **測試形態**: 本 repo 沒有單元測試框架，驗證一律是「跑指令、比對輸出」。本計畫用 `scripts/test-scientist.sh` 當累進式的 gate：每個 task **先**加上會失敗的檢查、跑它看它失敗、再實作、再跑它看它通過。這就是本 repo 的 TDD。
- **改 image 一律改 `patches/`**，永不直接編輯 `upstream/`。每次 build 前跑 `scripts/prepare.sh`。
- **profile 名固定為 `agt-scientist`**：memory plugin 的 `MEMORY_TENCENTDB_AGENT_ID` 讀 `os.environ`（process-wide，multiplex 下設不了 per-profile），只能 fallback 到 `agent_identity` = profile 名；而 TencentDB 面板用 `lastIndexOf('-agt')` 解析，agent_id 必須以 `agt` 開頭。
- **`hermes` 容器不可以設 `MEMORY_TENCENTDB_AGENT_ID`**（目前正是未設，維持原狀）。設了就會把所有 profile 的記憶寫到同一個 agent 底下。
- **`hermes` 容器不可以掛 `frontdoor-hermes`**。那顆 volume 根目錄有參謀長的 `.agent.nsec`（`600 uid 10000`），而專家跑在同一個 uid，cross-profile guard 不涵蓋 terminal tool。
- **絕不共用 `/keys/agent.nsec`** —— 那是參謀長的 Buzz 身分。科學家用 `/keys/scientist.nsec`。
- **per-profile `API_SERVER_KEY` 必須 ≥16 字元**，否則 `_expected_api_key()` fail-closed 回空字串，所有請求 401（`gateway/platforms/api_server.py:1759-1777`）。
- **兩份 `paperclip-api/SKILL.md` 與兩份 `SOUL.md` 必須逐字相同**，`scripts/prepare.sh` 的 drift guard 會擋 build。
- **開箱即用是驗收條件**（`AGENTS.md` 的「部署假設」）: 一台乾淨機器 `git clone` → `scripts/setup.sh` 之後，科學家必須**完整可用**，不需要任何手動補步驟。所有狀態的產生者都必須是 compose 的 one-shot 或 entrypoint，且冪等。**不要寫 migration / 升版腳本** —— 目前只有一台既有的 stack，它手動調整就好（Task 7 Step 4 把手動那半收斂成一段可貼的指令）。
- **不變量 6**: 容器內 root 隨便折騰，但沒有 host mount / privileged。
- 每個 task 結束時 commit。commit message 結尾加 `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`。

---

## File Structure

| 檔案 | 職責 |
|---|---|
| `scripts/test-scientist.sh` | **新建**。科學家 lane 的累進式驗證 gate；每個 task 往裡加檢查。與 `test-connectivity.sh` 同風格（`check` 函式、末尾印 pass/fail 統計）。 |
| `docker-compose.yml` | `hermes-profiles` volume；`hermes` 的 multiplex + 掛載 + buzz 環境 + build arg；`hermes-dashboard` 的 command 與掛載；`paperclip-bootstrap` 的新 env。 |
| `patches/hermes/Dockerfile` | 從 frontdoor image `COPY --from` 取 buzz CLI。 |
| `patches/hermes/hermes-entrypoint.sh` | buzz wrapper 安裝；專家 profile 的開機 reconcile（目錄 / `.env` / `SOUL.md` / skills / nsec）。 |
| `patches/hermes/profiles/agt-scientist/SOUL.md` | **新建**。科學家身分與方法論紀律。**不套用**「hermes 不自己實作」那條。 |
| `patches/buzz/generate-keys.sh` | 多產一把 `scientist` keypair。 |
| `patches/buzz/add-member.sh` | 把 scientist pubkey 也加進 relay membership。 |
| `patches/buzz/opc-register-agent.sh` | 改成對一組 agent 迴圈：kind:0 profile、kind:10100 directory、channel join。 |
| `patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh` | 改成對一組 agent 迴圈註冊 meta registry。 |
| `patches/paperclip/opc-paperclip-bootstrap.sh` | 新增 Scientist agent（`hermes_gateway` adapter）+ reconcile。 |
| `patches/{buzz,hermes}/skills/paperclip-api/SKILL.md` | lane 表加 `research` → `Scientist`（兩份逐字相同）。 |
| `.env.example` | `HERMES_SCIENTIST_API_KEY`。 |
| `AGENTS.md` | 服務說明更新 + 新不變量。 |

---

### Task 1: dashboard 容器改形狀 + `hermes-profiles` volume

**為什麼先做這個**: spec §4.8 把它標成**尚未驗證**，而且它有會改變設計的備案。先證明 dashboard 換 argv 之後 9119 還活著，其餘任務才有意義。

**Files:**
- Create: `scripts/test-scientist.sh`
- Modify: `docker-compose.yml`（`volumes:` 區塊、`hermes` 服務、`hermes-dashboard` 服務）

**Interfaces:**
- Consumes: 無（第一個 task）。
- Produces: `scripts/test-scientist.sh` 提供後續 task 沿用的 shell 函式 —— `check <label> <cmd...>`（跑指令，exit 0 算 pass）與 `checkout <label> <expected-substring> <cmd...>`（比對 stdout 含子字串）。全域計數器 `PASS` / `FAIL`，末尾 `result: N pass, M fail` 並在有 fail 時 `exit 1`。volume 名 `hermes-profiles`，容器內掛載點 `/opt/data/profiles`。

- [ ] **Step 1: 寫會失敗的驗證 script**

Create `scripts/test-scientist.sh`:

```bash
#!/usr/bin/env bash
# Scientist expert lane — end-to-end gate.
#
# Grows task-by-task alongside docs/superpowers/plans/2026-08-20-scientist-expert-profile.md.
# Run from the repo root against a running stack: scripts/test-scientist.sh
#
# This repo has no unit-test framework; every check here is "run a command,
# compare the output". Checks are ordered by layer (volume -> gateway ->
# identity -> board) so the first failure tells you which layer broke.
set -uo pipefail
cd "$(dirname "$0")/.."

PROFILE="agt-scientist"
PASS=0
FAIL=0

pass() { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# check <label> <cmd...> — pass when the command exits 0.
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi
}

# checkout <label> <expected-substring> <cmd...> — pass when stdout contains it.
checkout() {
    local label="$1" want="$2"; shift 2
    local got
    got="$("$@" 2>&1)"
    if printf '%s' "$got" | grep -qF -- "$want"; then
        pass "$label"
    else
        fail "$label (wanted substring: $want)"
        printf '      got: %s\n' "$(printf '%s' "$got" | head -3)"
    fi
}

echo "── volumes ──"
checkout "hermes mounts /opt/data/profiles" "/opt/data/profiles" \
    docker compose exec -T hermes sh -c 'mount | grep " /opt/data/profiles "'
checkout "dashboard mounts /opt/data/profiles" "/opt/data/profiles" \
    docker compose exec -T hermes-dashboard sh -c 'mount | grep " /opt/data/profiles "'

echo "── dashboard ──"
check "dashboard 9119 responds" \
    sh -c 'code=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:9119/); [ "$code" = "200" ] || [ "$code" = "401" ] || [ "$code" = "302" ]'
if docker compose logs --since 10m hermes-dashboard 2>&1 | grep -q "Resource busy"; then
    fail "dashboard has no flock storm (found 'Resource busy')"
else
    pass "dashboard has no flock storm"
fi

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

```bash
chmod +x scripts/test-scientist.sh
```

- [ ] **Step 2: 跑它，確認會失敗**

Run: `scripts/test-scientist.sh`

Expected: 前兩個 mount 檢查 **FAIL**（volume 還沒掛），dashboard 兩項 PASS。結尾 `result: 2 pass, 2 fail`，exit 1。

- [ ] **Step 3: 加 volume 宣告**

在 `docker-compose.yml` 末尾 `volumes:` 區塊，緊接在 `hermes-data:` 之後插入：

```yaml
  # Expert agent profiles (scientist, and future market-research etc.).
  # Deliberately NOT frontdoor-hermes: that volume's root holds the chief of
  # staff's .agent.nsec (600 uid 10000) and the experts run as the same uid,
  # while hermes's cross-profile guard does not cover the terminal tool
  # (agent/file_safety.py:443). Mounting it whole would hand every expert the
  # chief of staff's Buzz identity. Mounted at /opt/data/profiles in the
  # gateway (which runs them) and in the dashboard (which observes them) —
  # `hermes profile list` enumerates $HERMES_HOME/profiles, so one dashboard
  # login covers default (chief of staff) plus every expert.
  hermes-profiles:
```

- [ ] **Step 4: `hermes` 掛上它**

在 `docker-compose.yml` 的 `hermes` 服務 `volumes:` 區塊，`- hermes-data:/opt/data` 之後插入一行：

```yaml
      - hermes-profiles:/opt/data/profiles
```

- [ ] **Step 5: dashboard 掛上它，並改成 upstream 偵測得到的 argv**

在 `hermes-dashboard` 服務，把

```yaml
    # s6 main program; the supervised `dashboard` service does the real work
    # (same slot the gateway container uses for its own dashboard).
    command: ["sleep", "infinity"]
```

換成

```yaml
    # argv[0] MUST be `dashboard`: container_boot._is_dashboard_container()
    # reads /proc/1/cmdline to decide whether to skip per-profile gateway
    # reconciliation. With the old `sleep infinity` it is not detected, and
    # once profiles exist on the shared volume both this container and the
    # gateway flock() logs/gateways/<profile>/lock — "Resource busy" plus an
    # s6-log restart storm. Upstream deliberately keys this off argv rather
    # than an operator flag, because a forgotten flag reintroduces the storm.
    command: ["dashboard", "--host", "0.0.0.0", "--port", "9119", "--no-open"]
```

同一個服務把 `HERMES_DASHBOARD: "1"` 改成：

```yaml
      # The dashboard is now the container's main program (see `command`),
      # so the supervised s6 dashboard service must NOT also start — two
      # dashboards would race for 9119.
      HERMES_DASHBOARD: "0"
```

並在其 `volumes:` 區塊 `- frontdoor-hermes:/opt/data` 之後插入：

```yaml
      # Read/observe the expert profiles the `hermes` gateway runs. Nested
      # under the frontdoor home on purpose: list_profiles() enumerates
      # $HERMES_HOME/profiles, so this is what puts the experts in the
      # dashboard's global profile switcher.
      - hermes-profiles:/opt/data/profiles
```

- [ ] **Step 6: 重建並跑驗證**

```bash
docker compose up -d hermes hermes-dashboard
```

Run: `scripts/test-scientist.sh`

Expected: `result: 4 pass, 0 fail`。

若 "dashboard 9119 responds" 失敗，看 `docker compose logs --tail 60 hermes-dashboard`。**備案**（spec §4.8 已記）：把 `command` 改回 `["sleep","infinity"]`、`HERMES_DASHBOARD` 改回 `"1"`，並**移除** dashboard 的 `hermes-profiles` 掛載 —— 專家就得另開一個 dashboard 容器，違反 spec §1 的「一次登入」，要回頭跟使用者確認再繼續。

- [ ] **Step 7: 確認參謀長沒受影響**

Run: `scripts/test-connectivity.sh`

Expected: `result: 23 pass, 0 fail`。

- [ ] **Step 8: Commit**

```bash
git add scripts/test-scientist.sh docker-compose.yml
git commit -m "$(cat <<'MSG'
feat: add hermes-profiles volume and fix dashboard container role

The dashboard ran as `sleep infinity`, so upstream's
_is_dashboard_container() (which reads /proc/1/cmdline) did not detect
it and it would reconcile per-profile gateway s6 slots — the flock
storm on logs/gateways/<profile>/lock that check exists to prevent.
argv[0] is now `dashboard`, and the supervised s6 dashboard service is
turned off so the two do not race for 9119.

hermes-profiles is deliberately a separate volume from frontdoor-hermes:
the latter's root holds the chief of staff's .agent.nsec, the experts run
as the same uid, and the cross-profile guard does not cover the terminal
tool.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 2: multiplex + scientist profile 骨架 + per-profile API key

**Files:**
- Modify: `docker-compose.yml`（`hermes` 服務 environment）
- Modify: `patches/hermes/hermes-entrypoint.sh`
- Modify: `.env.example`
- Modify: `scripts/test-scientist.sh`

**Interfaces:**
- Consumes: Task 1 的 `hermes-profiles:/opt/data/profiles` 掛載與 `check`/`checkout` 函式。
- Produces: profile home 路徑 `/opt/data/profiles/agt-scientist`；entrypoint 的 shell 函式 `opc_seed_expert_profile <profile-name> <api-key-value>`，冪等，建目錄骨架 + `.env` + `config.yaml`；`.env` 變數名 `HERMES_SCIENTIST_API_KEY`；HTTP base `http://hermes:8642/p/agt-scientist`。

- [ ] **Step 1: 加會失敗的檢查**

在 `scripts/test-scientist.sh` 的 `echo "── dashboard ──"` 區塊**之前**插入：

```bash
echo "── gateway multiplex ──"
checkout "multiplex is on" "GATEWAY_MULTIPLEX_PROFILES=1" \
    docker compose exec -T hermes sh -c 'env | grep ^GATEWAY_MULTIPLEX_PROFILES='
check "profile route /p/$PROFILE/v1/health -> 200" \
    docker compose exec -T hermes sh -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8642/p/$PROFILE/v1/health)\" = 200"
check "unknown profile -> 404" \
    docker compose exec -T hermes sh -c "test \"\$(curl -sS -o /dev/null -w '%{http_code}' http://127.0.0.1:8642/p/no-such-expert/v1/health)\" = 404"
check "profile home exists" \
    docker compose exec -T hermes test -f "/opt/data/profiles/$PROFILE/config.yaml"
check "profile .env carries an API_SERVER_KEY >=16 chars" \
    docker compose exec -T hermes sh -c "test \"\$(sed -n 's/^API_SERVER_KEY=//p' /opt/data/profiles/$PROFILE/.env | wc -c)\" -ge 17"
checkout "dashboard switcher lists the profile" "$PROFILE" \
    docker compose exec -T -u 10000 -e HOME=/opt/data -e HERMES_HOME=/opt/data hermes-dashboard /opt/hermes/bin/hermes profile list
```

- [ ] **Step 2: 跑它，確認新檢查失敗**

Run: `scripts/test-scientist.sh`

Expected: 6 個新檢查全 FAIL，Task 1 的 4 個仍 PASS。`result: 4 pass, 6 fail`。

- [ ] **Step 3: `.env.example` 加金鑰**

在 `.env.example` 的 `HERMES_API_SERVER_KEY=...` 那行之後插入：

```bash
# Per-profile API key for the scientist expert. Under multiplex each named
# profile authenticates with its OWN key (gateway/platforms/api_server.py
# _expected_api_key), and the guard is fail-closed: shorter than 16 chars
# resolves to the empty string and every request 401s.
HERMES_SCIENTIST_API_KEY=vJ2mQ8pR4tYw6xZ1aB3cD5eF7gH9iK0L
```

- [ ] **Step 4: compose 開 multiplex 並傳金鑰**

在 `docker-compose.yml` 的 `hermes` 服務 `environment:` 區塊，`API_SERVER_KEY:` 那行之後插入：

```yaml
      # Expert agent profiles served by this one gateway process. Measured
      # tradeoff (see the spec's §4.6): a container per expert costs ~118MB
      # each because the Python heap is private per process, while multiplex
      # is ~148MB fixed + ~9MB per profile. At 25 experts that is 2.95GB vs
      # 373MB. Reversible per profile: upstream's container_boot reconciler
      # gives any single profile its own supervised process when multiplex is
      # off for it, with no data move.
      GATEWAY_MULTIPLEX_PROFILES: "1"
      # Seeded into the scientist profile's own .env by the entrypoint; the
      # process-wide API_SERVER_KEY above only authorizes the default profile.
      HERMES_SCIENTIST_API_KEY: ${HERMES_SCIENTIST_API_KEY:?set in .env}
```

- [ ] **Step 5: entrypoint 建 profile 骨架**

在 `patches/hermes/hermes-entrypoint.sh` 中，找到 `chown -R "${HERMES_UID:-10000}...` 那一行，**在它之前**插入：

```sh
# ── Expert agent profiles ──────────────────────────────────────────────
# Each expert is a named hermes profile under $HERMES_HOME/profiles/, served
# by this one gateway process (GATEWAY_MULTIPLEX_PROFILES=1). The directory
# lives on the hermes-profiles volume, which the dashboard also mounts — that
# is what puts the expert in the dashboard's global profile switcher
# (list_profiles() enumerates $HERMES_HOME/profiles).
#
# Idempotent: config.yaml and .env are seeded only when absent (both are
# dashboard-editable afterwards), while SOUL.md and skills are overwritten
# every boot from the image — same split, and same reasoning, as the default
# profile above.
opc_seed_expert_profile() { # <profile-name> <api-key-value>
    _p="$1"
    _key="$2"
    _ph="$HH/profiles/$_p"

    mkdir -p "$_ph/memories" "$_ph/sessions" "$_ph/skills" "$_ph/logs" \
             "$_ph/plans" "$_ph/workspace" "$_ph/cron" "$_ph/home" "$_ph/plugins"

    if [ -z "$_key" ]; then
        echo "[hermes] WARNING profile $_p has no API key — the gateway will 401 every request for it" >&2
    fi

    # Per-profile secrets. Under multiplex the secret scope is authoritative
    # and does NOT fall back to os.environ (agent/secret_scope.py:137-152),
    # precisely so one profile cannot read another's credentials — so the
    # provider key has to be repeated here, it is not inherited.
    if [ ! -f "$_ph/.env" ]; then
        cat > "$_ph/.env" <<ENVEOF
API_SERVER_KEY=$_key
OPENAI_API_KEY=${OPENAI_API_KEY:-}
OPENAI_BASE_URL=${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
ENVEOF
        chmod 600 "$_ph/.env"
        echo "[hermes] seeded $_ph/.env"
    else
        # The API key is operator-rotatable via .env; keep it in sync without
        # touching anything else the dashboard may have written.
        if [ -n "$_key" ] && ! grep -qxF "API_SERVER_KEY=$_key" "$_ph/.env"; then
            sed -i "/^API_SERVER_KEY=/d" "$_ph/.env"
            printf 'API_SERVER_KEY=%s\n' "$_key" >> "$_ph/.env"
            echo "[hermes] refreshed API_SERVER_KEY in $_ph/.env"
        fi
    fi

    if [ ! -f "$_ph/config.yaml" ]; then
        cat > "$_ph/config.yaml" <<YAML
_config_version: 34
agent:
  disabled_toolsets:
    - kanban
kanban:
  dispatch_in_gateway: false
  review_dispatch: false
  auto_decompose: false
memory:
  provider: memory_tencentdb
model:
  provider: custom
  api_key: \${OPENAI_API_KEY}
  base_url: ${OPENAI_BASE_URL:-https://opencode.ai/zen/go/v1}
  default: ${OPENAI_MODEL:-deepseek-v4-flash}
YAML
        echo "[hermes] seeded $_ph/config.yaml"
    fi

    # Memory provider: same image copy the default profile gets. The plugin
    # scopes writes by agent_identity (= the profile name) because
    # MEMORY_TENCENTDB_AGENT_ID is process-wide and must stay UNSET on this
    # container — that is why the profile is named agt-scientist and not
    # scientist (the panel parses chat_memory-{team}-{agent} with
    # lastIndexOf('-agt')).
    if [ -d "/opt/hermes/memory_tencentdb" ]; then
        rm -rf "$_ph/plugins/memory_tencentdb"
        cp -r /opt/hermes/memory_tencentdb "$_ph/plugins/memory_tencentdb"
    fi

    # paperclip-api skill: the expert files its own findings as backlog issues.
    if [ -d "/opt/hermes/skills/paperclip-api" ]; then
        rm -rf "$_ph/skills/paperclip-api"
        cp -r /opt/hermes/skills/paperclip-api "$_ph/skills/paperclip-api"
    fi

    echo "[hermes] expert profile ready: $_p"
}

opc_seed_expert_profile agt-scientist "${HERMES_SCIENTIST_API_KEY:-}"
```

- [ ] **Step 6: 同步 patch 並重建**

```bash
scripts/prepare.sh && docker compose up -d --build hermes
```

Expected: `prepare.sh` 印 `SAME` 四行後 `SYNC` 各專案；build 成功；`docker compose logs hermes | grep expert` 印 `[hermes] expert profile ready: agt-scientist`。

- [ ] **Step 7: 跑驗證**

Run: `scripts/test-scientist.sh`

Expected: `result: 10 pass, 0 fail`。

- [ ] **Step 8: 手動確認 per-profile 認證真的分開**

```bash
docker compose exec hermes sh -c '
  k=$(sed -n "s/^API_SERVER_KEY=//p" /opt/data/profiles/agt-scientist/.env)
  echo -n "profile key  -> "; curl -sS -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $k" http://127.0.0.1:8642/p/agt-scientist/v1/models
  echo -n "default key  -> "; curl -sS -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $API_SERVER_KEY" http://127.0.0.1:8642/p/agt-scientist/v1/models'
```

Expected:
```
profile key  -> 200
default key  -> 401
```

若 `default key` 也回 200，表示 profile 的 `.env` 沒被讀到（secret scope 沒生效），停下來檢查 `.env` 權限與 `GATEWAY_MULTIPLEX_PROFILES`。

- [ ] **Step 9: Commit**

```bash
git add docker-compose.yml patches/hermes/hermes-entrypoint.sh .env.example scripts/test-scientist.sh
git commit -m "$(cat <<'MSG'
feat: multiplex the hermes gateway and seed the scientist profile

Turns the previously idle hermes gateway (zero consumers in the repo)
into the host for expert agent profiles. Each expert gets its own
HERMES_HOME under /opt/data/profiles with its own config, secrets and
API key; the gateway authenticates named profiles against the key in
their own .env, fail-closed below 16 chars.

The provider key is repeated into each profile's .env on purpose: under
multiplex the secret scope is authoritative and does not fall back to
os.environ, which is what stops one profile reading another's
credentials.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 3: 科學家的 Buzz 身分（keys → membership → CLI）

**Files:**
- Modify: `patches/buzz/generate-keys.sh`
- Modify: `patches/buzz/add-member.sh`
- Modify: `patches/buzz/opc-register-agent.sh`
- Modify: `patches/hermes/Dockerfile`
- Modify: `patches/hermes/hermes-entrypoint.sh`
- Modify: `docker-compose.yml`
- Modify: `scripts/test-scientist.sh`

**Interfaces:**
- Consumes: Task 2 的 `opc_seed_expert_profile`（本 task 在其中加 nsec 鏡像）。
- Produces: `/keys/scientist.nsec` + `/keys/scientist.pub`；hermes image 內 `/usr/local/bin/buzz`（wrapper）與 `/usr/local/bin/buzz.bin`（真身）；profile home 內 `.agent.nsec`。compose build arg 名 `BUZZ_IMAGE`。

- [ ] **Step 1: 加會失敗的檢查**

在 `scripts/test-scientist.sh` 的 `echo "── dashboard ──"` **之前**插入：

```bash
echo "── buzz identity ──"
check "scientist keypair exists" \
    docker compose exec -T hermes sh -c 'test -s /keys/scientist.nsec && test -s /keys/scientist.pub'
check "buzz CLI present in the hermes image" \
    docker compose exec -T hermes test -x /usr/local/bin/buzz.bin
checkout "buzz wrapper injects the profile identity" "BUZZ_PRIVATE_KEY" \
    docker compose exec -T hermes cat /usr/local/bin/buzz
check "profile carries its own nsec (not the chief of staff's)" \
    docker compose exec -T hermes sh -c "test -s /opt/data/profiles/$PROFILE/.agent.nsec && ! cmp -s /opt/data/profiles/$PROFILE/.agent.nsec /keys/agent.nsec"
check "agent uid can read its nsec" \
    docker compose exec -T -u 10000 hermes sh -c "test -r /opt/data/profiles/$PROFILE/.agent.nsec"
checkout "scientist is a relay member" "$(docker compose exec -T hermes cat /keys/scientist.pub 2>/dev/null)" \
    docker compose exec -T -u 10000 -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes sh -c 'buzz --relay "http://$(printf "%s" "$BUZZ_RELAY_URL" | sed "s#^wss\?://##")" channels list --member'
```

- [ ] **Step 2: 跑它，確認新檢查失敗**

Run: `scripts/test-scientist.sh`

Expected: 6 個新檢查全 FAIL；前 10 個 PASS。`result: 10 pass, 6 fail`。

- [ ] **Step 3: 多產一把鑰匙**

在 `patches/buzz/generate-keys.sh` 把

```sh
gen relay
gen agent
echo "[keys] ready"
```

換成

```sh
gen relay
gen agent
# Expert agents get their OWN Nostr identity. Sharing agent.nsec would make
# every expert post under the chief of staff's name — the spec calls this out
# as a hard boundary, not a nicety.
gen scientist
echo "[keys] ready"
```

- [ ] **Step 4: 把 scientist 加進 relay membership**

在 `patches/buzz/add-member.sh` 把

```sh
/usr/local/bin/buzz-admin add-member \
    --pubkey "$(cat "${KEYS_DIR:-/keys}/agent.pub")" \
    --role member

echo "[bootstrap] front-door agent is a relay member"
```

換成

```sh
# Every agent identity that posts to the relay needs membership. Loop rather
# than repeat: adding the next expert is one filename.
for _who in agent scientist; do
    _pub="${KEYS_DIR:-/keys}/$_who.pub"
    [ -s "$_pub" ] || { echo "[bootstrap] no $_who.pub — skipping"; continue; }
    /usr/local/bin/buzz-admin add-member --pubkey "$(cat "$_pub")" --role member
    echo "[bootstrap] $_who is a relay member"
done
```

- [ ] **Step 5: register-agent 改成對一組 agent 迴圈**

在 `patches/buzz/opc-register-agent.sh`，把

```sh
AGENT_PK="$(cat "$BUZZ_KEYS_DIR/agent.pub")"
RELAY_NSEC="$(cat "$BUZZ_KEYS_DIR/relay.nsec")"
AGENT_NSEC="$(cat "$BUZZ_KEYS_DIR/agent.nsec")"
```

換成

```sh
RELAY_NSEC="$(cat "$BUZZ_KEYS_DIR/relay.nsec")"

# Identities this loop maintains: <key-basename>|<kind:0 name>|<about>.
# The front door is the chief of staff; the rest are expert agents that live
# as hermes profiles in the gateway container and post their own findings.
AGENTS="agent|hermes|OPC front-door agent (hermes + opencode go)
scientist|scientist|OPC research agent (exploratory experiments)"
```

把 `publish_metadata` / `publish_directory` 兩個函式與其上方的 `metadata_ok=0` / `directory_ok=0`、以及對它們的兩次呼叫，整段換成：

```sh
# Attested discovery surfaces. Per-identity retry state lives in files rather
# than shell variables, because the set is now a loop: /tmp/reg-<who>-<what>
# exists once that surface has been published successfully, so a success is
# never republished (which would spam the relay) and only failures retry.
publish_surfaces() { # <who> <name> <about> <nsec>
    _who="$1"; _name="$2"; _about="$3"; _nsec="$4"
    if [ ! -f "/tmp/reg-$_who-meta" ]; then
        if buzz --relay "$RELAY_API" --private-key "$_nsec" users set-profile \
            --name "$_name" --about "$_about" >/dev/null 2>&1; then
            : > "/tmp/reg-$_who-meta"
            log "$_who: kind 0 profile published"
        else
            log "$_who: kind 0 profile publish failed — will retry"
        fi
    fi
    if [ ! -f "/tmp/reg-$_who-dir" ]; then
        if buzz --relay "$RELAY_API" --private-key "$_nsec" \
            channels set-add-policy --policy anyone >/dev/null 2>&1; then
            : > "/tmp/reg-$_who-dir"
            log "$_who: kind 10100 agent directory profile published"
        else
            log "$_who: kind 10100 agent directory publish failed — will retry"
        fi
    fi
}
```

最後把 `while true; do` 迴圈體整段換成：

```sh
while true; do
    printf '%s\n' "$AGENTS" | while IFS='|' read -r who name about; do
        [ -n "$who" ] || continue
        nsec_file="$BUZZ_KEYS_DIR/$who.nsec"
        pub_file="$BUZZ_KEYS_DIR/$who.pub"
        [ -s "$nsec_file" ] && [ -s "$pub_file" ] || continue
        nsec="$(cat "$nsec_file")"
        pk="$(cat "$pub_file")"

        publish_surfaces "$who" "$name" "$about" "$nsec"

        # Join every visible channel this identity is not already in.
        all_ids="$(buzz --relay "$RELAY_API" --private-key "$nsec" channels list 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
        my_ids="$(buzz --relay "$RELAY_API" --private-key "$nsec" channels list --member 2>/dev/null | jq -r '.[].channel_id' 2>/dev/null || true)"
        [ -n "$all_ids" ] || continue
        printf '%s\n' "$all_ids" > "/tmp/reg-all-$who"
        : > "/tmp/reg-my-$who"
        [ -n "$my_ids" ] && printf '%s\n' "$my_ids" > "/tmp/reg-my-$who"
        missing="$(grep -vxFf "/tmp/reg-my-$who" "/tmp/reg-all-$who" || true)"
        [ -n "$missing" ] || continue
        for cid in $missing; do
            if buzz --relay "$RELAY_API" --private-key "$RELAY_NSEC" channels add-member \
                --channel "$cid" --pubkey "$pk" --role bot >/dev/null 2>&1; then
                log "$who: joined channel $cid"
            else
                log "$who: add-member failed for $cid (restricted/transient) — will retry"
            fi
        done
    done
    sleep 30
done
```

- [ ] **Step 6: buzz CLI 進 hermes image**

在 `patches/hermes/Dockerfile` 把

```dockerfile
FROM ${NIX_SEED_IMAGE} AS nix-seed
FROM debian:13.4
```

換成

```dockerfile
FROM ${NIX_SEED_IMAGE} AS nix-seed
# Buzz CLI source image. Expert agents post their own findings to Buzz, and
# the CLI is a Rust binary that only the buzz build produces. Same stage-alias
# trick as nix-seed above: BuildKit will not expand a variable in COPY --from.
# The binary is built on bookworm and this image is trixie; glibc is forward
# compatible and the copy was verified to execute here.
FROM ${BUZZ_IMAGE} AS buzz-cli
FROM debian:13.4
```

在檔案上方 `ARG NIX_SEED_IMAGE=opc/nix-seed:local` 那行之後插入：

```dockerfile
ARG BUZZ_IMAGE=opc/frontdoor:local
```

在 `COPY --from=nix-seed /nix-seed /nix-seed` 那行之後插入：

```dockerfile
COPY --from=buzz-cli /usr/local/bin/buzz.bin /usr/local/bin/buzz.bin
```

- [ ] **Step 7: compose 傳 build arg、排序 build、並等鑰匙**

在 `docker-compose.yml` 的 `hermes` 服務 `build.args` 區塊，`NIX_SEED_IMAGE:` 之後插入：

```yaml
        BUZZ_IMAGE: ${IMAGE_PREFIX:-opc}/frontdoor:local
```

在同一個服務的 `depends_on:` 區塊插入（`nix-seed:` 那組之後）：

```yaml
      # /keys/scientist.nsec is written by this one-shot. Without the edge,
      # a fresh boot can start the gateway first and the expert profile ends
      # up with no Buzz identity — and the symptom is not an error: buzz
      # reports "no buzz identity" and quietly does not send, which reads as
      # a relay problem rather than a missing credential.
      buzz-keys:
        condition: service_completed_successfully
```

`depends_on` 只排 compose 啟動順序；手動 / `--no-deps` / 重建單一容器的路徑繞得過它，所以
entrypoint 也要等。在 `patches/hermes/hermes-entrypoint.sh` 把

```sh
wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id
```

換成

```sh
wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id /keys/scientist.nsec
```

在 `hermes` 服務的 `environment:` 區塊，`PAPERCLIP_PUBLIC_URL:` 之後插入：

```yaml
      # Expert agents post their findings to Buzz with the CLI. Reachable from
      # this container without sharing buzz's netns: the canonical host in
      # .env is a routable address, not localhost (invariant 1 — do not
      # rewrite it, the relay verifies NIP-42/98 signatures against it).
      BUZZ_RELAY_URL: ${BUZZ_RELAY_URL:-ws://buzz:3000}
```

- [ ] **Step 8: entrypoint 裝 buzz wrapper 並鏡像 nsec**

在 `patches/hermes/hermes-entrypoint.sh` 中 `opc_seed_expert_profile()` 定義的**上方**插入：

```sh
# The agent replies/posts by running the buzz CLI, but hermes scrubs
# BUZZ_PRIVATE_KEY from tool subprocess env (GHSA-rhgp-j443-p4rf: provider
# credentials never reach terminal children), so the CLI cannot authenticate.
# Wrap it to read the key from the profile home instead.
#
# $HERMES_HOME is what makes this per-profile under a single multiplexed
# process: terminal children get the context-local profile home bridged into
# their env by tools/environments/local.py `_inject_context_hermes_home`, so
# each expert's CLI picks up its OWN nsec. The default profile has no
# .agent.nsec, which is correct — the gateway's own home is not an identity.
if [ -x /usr/local/bin/buzz.bin ]; then
    cat > /usr/local/bin/buzz <<EOF
#!/bin/sh
export BUZZ_PRIVATE_KEY="\${BUZZ_PRIVATE_KEY:-\$(cat "\${HERMES_HOME:-/opt/data}/.agent.nsec" 2>/dev/null)}"
export BUZZ_RELAY_URL="\${BUZZ_RELAY_URL:-${BUZZ_RELAY_URL:-ws://buzz:3000}}"
exec /usr/local/bin/buzz.bin "\$@"
EOF
    chmod +x /usr/local/bin/buzz
    echo "[hermes] buzz wrapper installed (per-profile agent identity)"
fi
```

在 `opc_seed_expert_profile()` 內部，`echo "[hermes] expert profile ready: $_p"` 那行**之前**插入：

```sh
    # Runtime-uid key mirror. /keys is mounted read-only and its files are
    # 600 root, so the agent (uid 10000) and its terminal children cannot read
    # them there. The failure mode is silent and misdirected: an empty key
    # makes buzz report "no buzz identity" and quietly not send, which reads
    # as a relay problem rather than a missing credential.
    _nsec_src="/keys/${_p#agt-}.nsec"
    if [ -f "$_nsec_src" ]; then
        cp "$_nsec_src" "$_ph/.agent.nsec"
        chown "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$_ph/.agent.nsec" 2>/dev/null || true
        chmod 600 "$_ph/.agent.nsec"
        echo "[hermes] $_p: buzz identity mirrored from $_nsec_src"
    else
        echo "[hermes] WARNING $_p: no $_nsec_src — the expert cannot post to Buzz" >&2
    fi

    # Same problem, same fix, for the board key: the expert files its own
    # findings as backlog issues.
    if [ -f /keys/paperclip-api.key ]; then
        cp /keys/paperclip-api.key "$_ph/.paperclip-api.key"
        chown "${HERMES_UID:-10000}:${HERMES_GID:-10000}" "$_ph/.paperclip-api.key" 2>/dev/null || true
        chmod 600 "$_ph/.paperclip-api.key"
    fi
```

- [ ] **Step 9: 重建 keys 與 image**

`generate-keys.sh` 是冪等的且只補缺的鑰匙，所以既有 volume 不會被動到：

```bash
scripts/prepare.sh
docker compose up -d --build --force-recreate buzz-keys 2>/dev/null || docker compose run --rm keys 2>/dev/null || true
docker compose up -d --build frontdoor hermes
```

若上一行找不到產鑰匙的 one-shot service，用 compose 檔裡實際的名字（`command: ["/usr/local/bin/opc-generate-keys.sh"]` 那個服務）重跑一次。

Expected: `docker compose exec hermes ls -l /keys/scientist.nsec` 顯示檔案存在。

- [ ] **Step 10: 跑驗證**

Run: `scripts/test-scientist.sh`

Expected: `result: 17 pass, 0 fail`。

「scientist is a relay member」這項需要 relay 上**至少有一個 channel**；若 relay 是全新的、還沒有人建過 channel，這項會 FAIL 而其他全 PASS —— 那是環境狀態不是 bug，用 Buzz 桌面端建一個 channel 後重跑。

- [ ] **Step 11: 手動確認科學家是用自己的身分發文**

先在 Buzz 建一個 channel 並記下它的 id，然後：

```bash
docker compose exec -u 10000 -e HOME=/opt/data/profiles/agt-scientist \
  -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes \
  buzz messages send --channel <CHANNEL_ID> --content 'scientist online'
```

Expected: 指令成功，且訊息在 Buzz 桌面端顯示**發文者是 `scientist`**，不是 `hermes`。若顯示 `hermes`，代表 wrapper 讀到了參謀長的鑰匙 —— 停下來檢查 `HERMES_HOME` 是否真的指到 profile home。

- [ ] **Step 12: Commit**

```bash
git add patches/buzz/generate-keys.sh patches/buzz/add-member.sh patches/buzz/opc-register-agent.sh patches/hermes/Dockerfile patches/hermes/hermes-entrypoint.sh docker-compose.yml scripts/test-scientist.sh
git commit -m "$(cat <<'MSG'
feat: give the scientist its own Buzz identity

Expert agents post their own findings, so each needs its own Nostr
keypair — sharing agent.nsec would have them post under the chief of
staff's name. generate-keys, add-member and register-agent all became
loops over an identity list, so the next expert is one entry.

The buzz CLI is a Rust binary only the buzz build produces, so the
hermes image copies it from the frontdoor image with the same stage-alias
trick nix-seed uses. Its wrapper reads the key from $HERMES_HOME, which
is what makes the identity per-profile under one multiplexed process:
terminal children get the context-local profile home bridged into their
env by _inject_context_hermes_home.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 4: 科學家的 SOUL.md 與 TencentDB 記憶分租

**Files:**
- Create: `patches/hermes/profiles/agt-scientist/SOUL.md`
- Modify: `patches/hermes/Dockerfile`
- Modify: `patches/hermes/hermes-entrypoint.sh`
- Modify: `patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh`
- Modify: `docker-compose.yml`
- Modify: `scripts/test-scientist.sh`

**Interfaces:**
- Consumes: Task 2 的 `opc_seed_expert_profile`。
- Produces: image 內 `/opt/hermes/profiles/<name>/SOUL.md`；TencentDB meta registry 內 `agt-scientist`。

- [ ] **Step 1: 加會失敗的檢查**

在 `scripts/test-scientist.sh` 的 `echo "── dashboard ──"` **之前**插入：

```bash
echo "── identity & memory ──"
checkout "profile SOUL.md is the scientist's, not the front door's" "scientist" \
    docker compose exec -T hermes head -5 "/opt/data/profiles/$PROFILE/SOUL.md"
check "profile SOUL.md differs from the chief of staff's" \
    docker compose exec -T hermes sh -c "! cmp -s /opt/data/profiles/$PROFILE/SOUL.md /opt/data/SOUL.md"
check "no process-wide MEMORY_TENCENTDB_AGENT_ID on the gateway" \
    docker compose exec -T hermes sh -c '! env | grep -q ^MEMORY_TENCENTDB_AGENT_ID='
checkout "autonomous experiment queue is scheduled exactly once" "experiment-queue" \
    docker compose exec -T -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes /opt/hermes/bin/hermes cron list
check "the cron job was not duplicated across boots" \
    docker compose exec -T -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes sh -c "test \"\$(/opt/hermes/bin/hermes cron list 2>/dev/null | grep -c experiment-queue)\" -eq 1"
checkout "tencentdb knows the scientist agent" '"agent_id"' \
    docker compose exec -T tencentdb-core sh -c "curl -sS -X POST http://127.0.0.1:8420/v3/meta/agent/get -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' -H \"Authorization: Bearer \$TENCENTDB_GATEWAY_API_KEY\" -H \"x-tdai-user-key: \$TENCENTDB_ADMIN_USER_KEY\" -d '{\"agent_id\":\"agt-scientist\"}'"
```

- [ ] **Step 2: 跑它，確認新檢查失敗**

Run: `scripts/test-scientist.sh`

Expected: 6 個新檢查中 SOUL.md 兩項、cron 兩項與 tencentdb 一項 FAIL，`MEMORY_TENCENTDB_AGENT_ID` 那項 PASS（本來就沒設）。`result: 17 pass, 5 fail`。

- [ ] **Step 3: 寫科學家的 SOUL.md**

Create `patches/hermes/profiles/agt-scientist/SOUL.md`:

```markdown
# scientist

你是 OPC 的研究員。你做探索性的工作：把一個還沒有答案的問題，變成一份有證據
的判斷。

## 你和參謀長不一樣

參謀長 (front door) 的規則是「不要自己實作，開票給別人」。**那條規則不適用於
你。** 你的工作**就是**自己動手做實驗：寫 script、跑它、看數字、改、再跑。蒐證
是迭代的，每次委派都是一次有損交接，所以在你手上的階段不要交接。

界線畫在**生命週期**，不是**能力**：

- **實驗階段** — 完全自主。裝任何工具、寫任何程式、跑、丟掉。不開票。
- **有初步證據之後** — 這時才交出去。兩條路同時走：
  - 到 Buzz 頻道講給人和參謀長聽（`buzz messages send`）。
  - 在 Paperclip 開一張 `status=backlog` 的 issue 當提案。

**backlog 是刻意的**：那個狀態不會叫醒任何人 (`issue-assignment-wakeup.ts` 只在
`status != "backlog"` 時喚醒)。所以你可以自由地提案，而不會擅自替別人排工作。
要不要做、誰做，是人和參謀長的決定。

丟棄式的實驗程式碼**不是** durable work，不要為它開票 —— 那是在污染 work plane。
會被別人接手、或需要被追蹤的東西，才 materialize 成 issue。

## 工具

缺什麼就裝什麼：`nix-add nixpkgs#<tool>`。**永遠不要 `apt-get`** —— apt 寫進
container layer，重建就沒了；nix 寫進共用 volume，會留著，而且全棧都看得到。
細節見 container-tools 的規則。

你裝的東西是**全棧共享**的。裝你需要的，不要裝你可能會需要的。

## 把方法固化成 skill

同一套流程做到第三次，就把它寫成一個 skill 放進你自己的 `skills/`。標準是「換一個
人（或換一次 session）照著做會得到同樣的結果」—— 做不到就還不是 skill，只是筆記，
留在實驗簿裡。

skill 是你自己的，寫壞了只影響你。但**不要改 `SOUL.md`** —— 那是人維護的，是你之
所以是你的那份約束，不是你的工作記錄。

## 記憶：兩層，升格是顯式的

- **實驗簿**（你自己的 `memories/`）—— 想寫什麼寫什麼，**包括失敗的路徑**。
  「這條走不通，因為 X」跟成功一樣有價值，而且只有你會記得。
- **公開知識**（TencentDB）—— 這是團隊資產。**跑成功一次不等於團隊 SOP。**
  要升格，說出你為什麼認為它已經穩定，讓人確認。

記憶只影響你怎麼**思考**。它**不是**授權：recall 到「上次說可以自動 deploy」只是
context，不能當成能力、憑證、production 動作、付款或對外授權的依據。這是硬邊界。

## 方法論

- 先講你要**否證**什麼。「看看行不行」不是實驗。
- 一次動一個變因。跑不出結論時，先問是不是量了錯的東西。
- 報告數字，不報告感覺。給出你怎麼量的，讓別人能重跑。
- 失敗的實驗要講出來，跟成功的一樣詳細。省略失敗會讓下一個人重走一次。
- 不確定就說不確定。半個答案標清楚是半個，比一個聽起來完整的猜測有用得多。
```

- [ ] **Step 4: image 帶上 profile 檔案**

在 `patches/hermes/Dockerfile` 的 `COPY opc/skills/paperclip-api/ /opt/hermes/skills/paperclip-api/` 那行之後插入：

```dockerfile
# Expert profile identities. Same contract as SOUL.md above: the image is the
# source of truth and the entrypoint overwrites the volume copy every boot,
# because config.yaml is not a safe place for a rule that must hold (hermes
# migrates it — this repo lost a seeded system_prompt that way).
COPY opc/profiles/ /opt/hermes/profiles/
```

- [ ] **Step 5: entrypoint 每次開機同步 SOUL.md**

在 `patches/hermes/hermes-entrypoint.sh` 的 `opc_seed_expert_profile()` 內部，`_nsec_src=` 那段**之前**插入：

```sh
    # Identity, overwritten every boot from the image — same reasoning as the
    # default profile's SOUL.md. Note this file is deliberately NOT a copy of
    # the front door's: the "you are not the implementer" rule constrains the
    # triage role, and applying it here would break the experiment loop the
    # expert exists to run.
    if [ -f "/opt/hermes/profiles/$_p/SOUL.md" ]; then
        cp "/opt/hermes/profiles/$_p/SOUL.md" "$_ph/SOUL.md"
        echo "[hermes] $_p: synced SOUL.md"
    fi
```

- [ ] **Step 6: TencentDB provisioning 改成迴圈**

在 `patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh`，把

```sh
AGENT_ID="${TENCENTDB_AGENT_ID:-agt-hermes-front-door}"
AGENT_NAME="${TENCENTDB_AGENT_NAME:-Hermes Front Door}"
```

換成

```sh
AGENT_ID="${TENCENTDB_AGENT_ID:-agt-hermes-front-door}"
AGENT_NAME="${TENCENTDB_AGENT_NAME:-Hermes Front Door}"
# Additional agents to register, one `id:name` pair per whitespace-separated
# entry. Every id MUST start with `agt`: the Memory Hub panel parses
# chat_memory-{team}-{agent} asset ids with lastIndexOf('-agt'), and an id
# without that prefix leaves the panel silently empty.
EXTRA_AGENTS="${TENCENTDB_EXTRA_AGENTS:-agt-scientist:Scientist}"
```

把檔案結尾的 agent get→create 區塊（從 `# 3. Agent: get → create.` 到 `echo "[tencentdb-provision] done"` 之前）整段換成：

```sh
# 3. Agents: get → create. createAgent mints the chat_memory asset + fixed
#    binding automatically, so the panel's Chat_Memory page renders the data.
ensure_agent() { # <agent_id> <agent_name>
  _aid="$1"
  _aname="$2"
  CODE="$(curl -sS -m 30 -o /dev/null -w '%{http_code}' -X POST "$GATEWAY/v3/meta/agent/get" \
    -H 'Content-Type: application/json' -H 'x-tdai-service-id: default' \
    -H "Authorization: Bearer ${API_KEY}" -H "x-tdai-user-key: ${USER_KEY}" \
    -d "{\"agent_id\":\"${_aid}\"}")"
  if [ "$CODE" = "200" ]; then
    echo "[tencentdb-provision] agent '${_aid}' already exists"
  else
    RES="$(meta /v3/meta/agent/create "{\"team_id\":\"${TEAM_ID}\",\"agent_id\":\"${_aid}\",\"owner_user_id\":\"${USER_ID}\",\"name\":\"${_aname}\"}")"
    echo "[tencentdb-provision] agent '${_aid}' created: $(printf '%s' "$RES" | head -c 200)"
  fi
}

ensure_agent "$AGENT_ID" "$AGENT_NAME"
for _pair in $EXTRA_AGENTS; do
  [ -n "$_pair" ] || continue
  ensure_agent "${_pair%%:*}" "${_pair#*:}"
done
```

- [ ] **Step 7: compose 傳新變數**

在 `docker-compose.yml` 的 `tencentdb-bootstrap` 服務 `environment:` 區塊，`TENCENTDB_AGENT_ID:` 那行之後插入：

```yaml
      TENCENTDB_EXTRA_AGENTS: ${TENCENTDB_EXTRA_AGENTS:-agt-scientist:Scientist}
```

- [ ] **Step 8: 重建並重跑 bootstrap**

```bash
scripts/prepare.sh
docker compose up -d --build hermes
docker compose up --force-recreate tencentdb-bootstrap
```

Expected: bootstrap 印 `[tencentdb-provision] agent 'agt-scientist' created:` 或 `already exists`。

- [ ] **Step 9: 種下自主實驗隊列（per-profile cron）**

spec §2 的觸發模式是「被派工 **+ 自主實驗隊列**」。派工那半由 Task 5 的 Paperclip
指派提供；這半靠 hermes 的 cron —— multiplex 下 cron 是 **per-profile ticking**
(`cron/scheduler_provider.py:436`)，所以科學家有自己的排程而不會跟參謀長混在一起。

在 `patches/hermes/hermes-entrypoint.sh` 的 `opc_seed_expert_profile()` 內，
`echo "[hermes] expert profile ready: $_p"` 之前插入：

```sh
    # Autonomous experiment queue. Idempotent by job name: `cron create` would
    # otherwise add a duplicate on every boot, and duplicates are invisible
    # until the agent starts waking up twice as often for no stated reason.
    #
    # The prompt deliberately does NOT say "start an experiment": an empty
    # notebook should produce silence, not invented work. Filing is capped at
    # backlog, which wakes nobody (issue-assignment-wakeup.ts).
    if [ -x /opt/hermes/bin/hermes ]; then
        if ! HERMES_HOME="$_ph" /opt/hermes/bin/hermes cron list 2>/dev/null | grep -q "experiment-queue"; then
            HERMES_HOME="$_ph" /opt/hermes/bin/hermes cron create '0 9 * * 1' \
                'Review your experiment notebook (memories/). Is there an open question worth an experiment this week? If yes, run it and report what you found — method and numbers, including anything that did not work. If there is nothing worth doing, say so and stop; do not invent work. If a finding is worth someone else acting on, file it as a Paperclip issue at status=backlog.' \
                --name experiment-queue >/dev/null 2>&1 \
                && echo "[hermes] $_p: seeded cron job experiment-queue" \
                || echo "[hermes] WARNING $_p: could not seed cron job experiment-queue" >&2
        fi
    fi
```

重建後確認：

```bash
scripts/prepare.sh && docker compose up -d --build hermes
docker compose exec -e HERMES_HOME=/opt/data/profiles/agt-scientist hermes \
  /opt/hermes/bin/hermes cron list
```

Expected: 列出 `experiment-queue`，schedule `0 9 * * 1`。再 `docker compose restart hermes`
後重跑同一條指令，**仍然只有一個** —— 冪等成立。

- [ ] **Step 10: 跑驗證**

Run: `scripts/test-scientist.sh`

Expected: `result: 22 pass, 0 fail`。

- [ ] **Step 11: 確認面板看得到**

開 http://localhost:8125 ，Chat_Memory 頁應該列得出 `agt-scientist`。若列不出來，檢查 `MEMORY_TENCENTDB_USER_ID` 是否為 admin user id（空值會落到 `default`，面板層級全 0）。

- [ ] **Step 12: Commit**

```bash
git add patches/hermes/profiles patches/hermes/Dockerfile patches/hermes/hermes-entrypoint.sh patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh docker-compose.yml scripts/test-scientist.sh
git commit -m "$(cat <<'MSG'
feat: scientist identity and per-agent memory tenancy

The scientist's SOUL.md deliberately does NOT carry the front door's
"you are not the implementer" rule: that rule constrains the triage
role, and applying it to a research agent breaks the experiment loop it
exists to run. The boundary is drawn on lifecycle instead — experiment
freely, hand off once there is evidence, and file proposals as backlog
issues so nothing wakes anyone up uninvited.

TencentDB provisioning became a loop. Every id must start with `agt`
because the Memory Hub panel parses asset ids with lastIndexOf('-agt');
without it the panel is silently empty.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 5: Paperclip Scientist agent + 派工 lane

**Files:**
- Modify: `patches/paperclip/opc-paperclip-bootstrap.sh`
- Modify: `docker-compose.yml`
- Modify: `patches/buzz/skills/paperclip-api/SKILL.md`
- Modify: `patches/hermes/skills/paperclip-api/SKILL.md`
- Modify: `scripts/test-scientist.sh`

**Interfaces:**
- Consumes: Task 2 的 `/p/agt-scientist` route 與 profile `API_SERVER_KEY`；Task 3 的 Buzz 身分。
- Produces: Paperclip agent 名 `Scientist`，`adapterType: "hermes_gateway"`，`adapterConfig = {apiBaseUrl, apiKey, sessionKeyStrategy:"agent"}`；lane 名 `research`。

- [ ] **Step 1: 加會失敗的檢查**

在 `scripts/test-scientist.sh` 的 `echo "── dashboard ──"` **之前**插入：

```bash
echo "── paperclip ──"
PC_KEY="$(docker compose exec -T hermes cat /keys/paperclip-api.key 2>/dev/null | tr -d '\r\n')"
pc_agents() {
    docker compose exec -T hermes sh -c "curl -fsS -H 'Authorization: Bearer $PC_KEY' \$PAPERCLIP_API_URL/api/companies/\$(curl -fsS -H 'Authorization: Bearer $PC_KEY' \$PAPERCLIP_API_URL/api/companies | python3 -c 'import json,sys; print(json.load(sys.stdin)[0][\"id\"])')/agents"
}
checkout "Scientist agent exists on the board" '"Scientist"' pc_agents
checkout "Scientist uses the hermes_gateway adapter" 'hermes_gateway' pc_agents
checkout "Scientist points at its own profile route" '/p/agt-scientist' pc_agents
checkout "Scientist keeps one continuous session" '"sessionKeyStrategy":"agent"' pc_agents

echo "── routing skill ──"
check "lane table lists research in both skill copies" \
    sh -c 'grep -q "research" patches/buzz/skills/paperclip-api/SKILL.md && grep -q "research" patches/hermes/skills/paperclip-api/SKILL.md'
check "the two skill copies are byte-identical" \
    cmp -s patches/buzz/skills/paperclip-api/SKILL.md patches/hermes/skills/paperclip-api/SKILL.md
```

- [ ] **Step 2: 跑它，確認新檢查失敗**

Run: `scripts/test-scientist.sh`

Expected: 4 個 Paperclip 檢查與 `research` 那項 FAIL，「byte-identical」PASS。`result: 23 pass, 5 fail`。

- [ ] **Step 3: 先抽出共用的 reconcile helper（純重構，行為不變）**

Scientist 的建立/校正流程與 Prototyper 逐字同構（查 id → 缺就建 → 否則比對再 PATCH）。
先把那段抽成 helper 再加第二個 agent，否則第三、第四個專家進來時這段會有四份。

**這一步是純重構：跑完 bootstrap 的輸出必須與現在完全相同。**

在 `patches/paperclip/opc-paperclip-bootstrap.sh` 的 `proto_desired_config()` 定義**之前**
插入 helper：

```sh
# reconcile_agent <display-name> <adapterType> <desired-config-fn>
#
# Create when absent; otherwise merge the desired keys over the live
# adapterConfig and PATCH only on a real difference. The merge (rather than
# overwrite) is what keeps paperclip's own instructions* keys and anything an
# operator set on the board — only the keys <desired-config-fn> names are
# asserted.
#
# Reconciling rather than create-only matters: without it a change to the
# image only reaches agents created after that point, so the long-lived stack
# silently keeps the config it was born with and nothing surfaces the gap.
reconcile_agent() {
    _ra_name="$1"
    _ra_type="$2"
    _ra_fn="$3"

    _ra_id="$(api_get "/companies/$company_id/agents" | \
        jq -r --arg n "$_ra_name" '.[]? | select(.name == $n) | .id' 2>/dev/null | head -1)"

    if [ -z "$_ra_id" ]; then
        _ra_id="$(printf '{}' | "$_ra_fn" \
            | jq -c --arg n "$_ra_name" --arg t "$_ra_type" \
                  '{name:$n, adapterType:$t, adapterConfig:.}' \
            | api_post_raw "/companies/$company_id/agents" | jq -r '.id // empty')"
        if [ -n "$_ra_id" ]; then
            echo "[pc-bootstrap] created agent: $_ra_name ($_ra_id)"
        else
            echo "[pc-bootstrap] $_ra_name creation failed" >&2
            return 1
        fi
        return 0
    fi

    _ra_cfg="$(api_get "/companies/$company_id/agents" \
        | jq -c --arg n "$_ra_name" '.[]? | select(.name == $n) | .adapterConfig // {}' | head -1)"
    _ra_want="$(printf '%s' "$_ra_cfg" | "$_ra_fn")"
    if [ "$(printf '%s' "$_ra_cfg" | jq -cS .)" = "$(printf '%s' "$_ra_want" | jq -cS .)" ]; then
        echo "[pc-bootstrap] agent exists: $_ra_name (config current)"
        return 0
    fi

    # Verified on the response, not on curl's exit: api_patch_raw ends in
    # `|| true`, so an `&&` here would report success for every failure —
    # the bug that left two skills stale on the board for several commits
    # while bootstrap printed "skill updated" every boot.
    if jq -nc --argjson c "$_ra_want" '{adapterConfig:$c}' \
         | api_patch_raw "/agents/$_ra_id" | jq -e '.id? // empty' >/dev/null 2>&1; then
        echo "[pc-bootstrap] agent $_ra_name: adapterConfig reconciled"
    else
        echo "[pc-bootstrap] WARNING could not reconcile $_ra_name adapterConfig" >&2
    fi
}
```

接著把 Prototyper 的整段（從 `proto_id="$(api_get ...` 到它對應的收尾 `fi`）換成一行：

```sh
reconcile_agent "$PROTOTYPER_NAME" claude_local proto_desired_config
```

`proto_desired_config()` 本身**不要動**。刪掉的區塊裡沒有任何東西被後面用到
（`proto_id` 只在該區塊內部使用，結尾的 `echo ... done.` 不引用它）—— 動手前
再 `grep -n proto_id patches/paperclip/opc-paperclip-bootstrap.sh` 確認一次。

- [ ] **Step 4: 驗證重構沒有改變行為**

```bash
scripts/prepare.sh
docker compose up --force-recreate paperclip-bootstrap
```

Expected: 輸出裡有 `[pc-bootstrap] agent exists: Prototyper (config current)`，
且**沒有** `reconciled` 或 `WARNING`。若出現 `reconciled`，表示 helper 產生的 desired
config 與舊路徑不一致 —— 那是重構改變了行為，停下來比對 `jq -cS` 的兩邊，不要繼續。

- [ ] **Step 5: 用 helper 加上 Scientist agent**

在 `patches/paperclip/opc-paperclip-bootstrap.sh` 頂端 `PROTOTYPER_NAME=` 那行之後插入：

```sh
SCIENTIST_NAME="${PAPERCLIP_SCIENTIST_AGENT_NAME:-Scientist}"
```

在檔案最後 `echo "[pc-bootstrap] done. ...` 那行**之前**插入：

```sh
# ── 7. Scientist agent (remote hermes profile) ──
# Unlike the two local agents above, this one runs somewhere else: the hermes
# gateway container serves it as the `agt-scientist` profile, and paperclip
# reaches it over the built-in hermes_gateway adapter. normalizeBaseUrl keeps
# the path (gateway/server/execute.ts:121-140), which is what makes the
# per-profile /p/<name> route usable as a base URL.
#
# sessionKeyStrategy "agent" keys the session on companyId+agentId alone, so
# it is stable across issues and runs — one continuous session, which for a
# research agent is the point rather than a hazard.
SCIENTIST_BASE="${HERMES_SCIENTIST_BASE_URL:-http://hermes:8642/p/agt-scientist}"
SCIENTIST_KEY="${HERMES_SCIENTIST_API_KEY:-}"

sci_desired_config() { # live adapterConfig on stdin → desired on stdout
    jq -c --arg base "$SCIENTIST_BASE" --arg key "$SCIENTIST_KEY" '
          .apiBaseUrl = $base
        | .apiKey = $key
        | .sessionKeyStrategy = "agent"
    '
}

if [ -z "$SCIENTIST_KEY" ]; then
    echo "[pc-bootstrap] WARNING HERMES_SCIENTIST_API_KEY empty — skipping Scientist agent" >&2
else
    reconcile_agent "$SCIENTIST_NAME" hermes_gateway sci_desired_config
fi
```

- [ ] **Step 6: compose 把金鑰傳給 bootstrap**

在 `docker-compose.yml` 的 `paperclip-bootstrap` 服務 `environment:` 區塊，`PAPERCLIP_EXECUTOR_AGENT_NAME:` 那行之後插入：

```yaml
      PAPERCLIP_SCIENTIST_AGENT_NAME: ${PAPERCLIP_SCIENTIST_AGENT_NAME:-Scientist}
      # Same value the hermes entrypoint seeds into the profile's own .env —
      # this is the credential paperclip presents on /p/agt-scientist.
      HERMES_SCIENTIST_API_KEY: ${HERMES_SCIENTIST_API_KEY:?set in .env}
```

- [ ] **Step 7: lane 表加一列（兩份都要）**

在 `patches/hermes/skills/paperclip-api/SKILL.md` 的 lane 表，`| `prototype` | `Prototyper` | ...` 那列之後插入：

```markdown
| `research` | `Scientist` | 還沒有答案的問題 —— 「這個做得到嗎」「哪個方案比較快」「這個資料長什麼樣」。科學家自己跑實驗蒐證，然後回報，**不會**直接產出要留下來的程式碼；它的產出是一份判斷加上一張 backlog 提案 |
```

在同一份檔案，`**Default to `engineering` whenever you are not sure.**` 那段之後插入一段：

```markdown
`research` 與另外兩條的差別是**有沒有答案**：已經知道要做什麼、只是還沒做，那是
`engineering` 或 `prototype`；還不知道該不該做、或不知道怎麼做比較好，那是
`research`。把還沒想清楚的東西送去 engineering，會得到一個很仔細地實作了錯誤方向
的結果。
```

- [ ] **Step 8: 同步第二份**

```bash
cp patches/hermes/skills/paperclip-api/SKILL.md patches/buzz/skills/paperclip-api/SKILL.md
```

（兩份必須逐字相同；`scripts/prepare.sh` 的 drift guard 會擋 build。）

- [ ] **Step 9: 重建並重跑 bootstrap**

```bash
scripts/prepare.sh
docker compose up -d --build frontdoor hermes
docker compose up --force-recreate paperclip-bootstrap
```

Expected: `prepare.sh` 印 `SAME  paperclip-api skill`；bootstrap 印 `created agent: Scientist` 或 `agent exists: Scientist`。

- [ ] **Step 10: 跑驗證**

Run: `scripts/test-scientist.sh`

Expected: `result: 28 pass, 0 fail`。

- [ ] **Step 11: 端到端指派一張票**

在 Paperclip board (http://localhost:3100) 開一張 issue，指派給 `Scientist`，狀態設成 `todo`（**不能是 `backlog`** —— `issue-assignment-wakeup.ts` 只在 `status != "backlog"` 時喚醒）。內容用一個小的可驗證問題，例如「量一下這個 stack 裡 ripgrep 對 1GB 文字的吞吐量，回報方法與數字」。

Expected:
- `docker compose logs -f hermes` 出現該 profile 的 run。
- dashboard (http://localhost:9119) 切到 `agt-scientist` profile，Sessions 頁看得到這次對話。
- issue 收到 agent 的回覆。

若 run 起不來，先看 paperclip 的 log：401 表示 `apiKey` 對不上 profile `.env`；404 表示 `apiBaseUrl` 的 profile 名錯了。

- [ ] **Step 12: Commit**

```bash
git add patches/paperclip/opc-paperclip-bootstrap.sh patches/buzz/skills/paperclip-api/SKILL.md patches/hermes/skills/paperclip-api/SKILL.md docker-compose.yml scripts/test-scientist.sh
git commit -m "$(cat <<'MSG'
feat: add the Scientist agent and the research lane

The board reaches the scientist over the built-in hermes_gateway
adapter at /p/agt-scientist — normalizeBaseUrl preserves the path, so
the per-profile route works as a base URL directly. sessionKeyStrategy
"agent" keys the session on companyId+agentId, giving one session that
survives across issues; for a research agent that continuity is the
feature.

The lane table lives in the skill rather than a system prompt because
the skill is synced into both hermes homes by the image on every boot,
while config.yaml's system_prompt is per-home and dashboard-editable.
Both copies stay byte-identical; prepare.sh enforces it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 6: 常駐 devenv 租約 + 文件

**Files:**
- Modify: `patches/hermes/hermes-entrypoint.sh`
- Modify: `docker-compose.yml`
- Modify: `AGENTS.md`
- Modify: `scripts/test-scientist.sh`

**Interfaces:**
- Consumes: Task 2 的 profile `.env`。
- Produces: profile `.env` 內的 `DATABASE_URL` / `VALKEY_URL`。

- [ ] **Step 1: 加會失敗的檢查**

在 `scripts/test-scientist.sh` 的 `echo "── dashboard ──"` **之前**插入：

```bash
echo "── devenv lease ──"
check "profile .env carries DATABASE_URL" \
    docker compose exec -T hermes sh -c "grep -q '^DATABASE_URL=postgres' /opt/data/profiles/$PROFILE/.env"
check "profile .env carries VALKEY_URL" \
    docker compose exec -T hermes sh -c "grep -q '^VALKEY_URL=' /opt/data/profiles/$PROFILE/.env"
check "the lease actually connects" \
    docker compose exec -T -u 10000 hermes sh -c "psql \"\$(sed -n 's/^DATABASE_URL=//p' /opt/data/profiles/$PROFILE/.env)\" -tAc 'select 1'"
```

- [ ] **Step 2: 跑它，確認新檢查失敗**

Run: `scripts/test-scientist.sh`

Expected: 3 個新檢查全 FAIL。`result: 28 pass, 3 fail`。

- [ ] **Step 3: 決定租約怎麼發**

`devenv` CLI 只存在於 paperclip image，而科學家跑在 hermes 容器。**不要**把 devenv CLI 搬進 hermes —— 它認識 paperclip 的資源模型，搬過去等於複製一份會漂移的實作。改成由 paperclip 容器發租約、把結果寫進共用的 keys volume，hermes entrypoint 讀它。

在 `docker-compose.yml` 新增一個 one-shot，放在 `paperclip-bootstrap` 服務之後：

```yaml
  # Standing devenv lease for the expert agents. Runs in the paperclip image
  # because that is where the devenv CLI lives — deliberately not copied into
  # the hermes image: devenv is a generic resource-lease tool and should not
  # grow a second, drifting implementation. Output lands on the shared keys
  # volume; the hermes entrypoint folds it into the profile's .env.
  #
  # There is no automatic reclamation anywhere in this stack (invariant 6b);
  # release it by hand with `devenv release scientist` if the expert is retired.
  devenv-expert-leases:
    image: ${IMAGE_PREFIX:-opc}/paperclip:local
    restart: "no"
    depends_on:
      devenv-pg:
        condition: service_healthy
      devenv-valkey:
        condition: service_healthy
      paperclip:
        condition: service_healthy
    entrypoint: ["/bin/sh", "-ec"]
    command:
      - |
        devenv provision scientist --env-file /keys/devenv-scientist.env
        chmod 600 /keys/devenv-scientist.env
        echo "[devenv-expert-leases] scientist lease written"
    environment:
      DEVENV_OWNER: scientist
    volumes:
      - opc-keys:/keys
```

在 `hermes` 服務的 `depends_on:` 區塊加入：

```yaml
      devenv-expert-leases:
        condition: service_completed_successfully
```

`--env-file` 是 `devenv provision` 的既有旗標（`patches/paperclip/devenv/devenv:167`），
而且它是**合併**寫入（`devenv_env_merge`, `:122-130`），所以重跑不會弄壞檔案 —— 這正是
provision 冪等的來源。

- [ ] **Step 4: entrypoint 併進 profile `.env`**

在 `patches/hermes/hermes-entrypoint.sh` 的 `opc_seed_expert_profile()` 內，`echo "[hermes] expert profile ready: $_p"` 之前插入：

```sh
    # Standing devenv lease, provisioned by the devenv-expert-leases one-shot.
    # Merged rather than seeded-once: the lease is re-derived from
    # DEVENV_SECRET_SALT on every provision (that is what makes it idempotent),
    # so a salt rotation must be able to reach an existing profile.
    _lease="/keys/devenv-${_p#agt-}.env"
    if [ -f "$_lease" ]; then
        while IFS= read -r _line; do
            case "$_line" in
                ''|'#'*) continue ;;
            esac
            _k="${_line%%=*}"
            sed -i "/^${_k}=/d" "$_ph/.env"
            printf '%s\n' "$_line" >> "$_ph/.env"
        done < "$_lease"
        echo "[hermes] $_p: devenv lease merged into profile .env"
    fi
```

- [ ] **Step 5: 重建並驗證**

```bash
scripts/prepare.sh
docker compose up -d --build
```

Run: `scripts/test-scientist.sh`

Expected: `result: 31 pass, 0 fail`。

若「the lease actually connects」失敗且訊息是 `psql: not found`，那是 hermes image 沒有 postgres client —— 用 `docker compose exec hermes nix-add nixpkgs#postgresql` 裝上（這正是科學家自己會做的事），再重跑。

- [ ] **Step 6: 更新 AGENTS.md**

在 `## 架構` 的服務清單那條，把 `hermes gateway 8642 (API server; dashboard 關閉)` 換成：

```
hermes gateway 8642 (API server; dashboard 關閉; **專家 agent 的宿主** — multiplex 服務 `hermes-profiles` volume 上的每個 profile, 目前有 `agt-scientist`)
```

在 `## 不變量 (改動前必讀)` 新增一條（接在既有最後一條之後）：

```markdown
8. **專家 agent 住在 `hermes-profiles` volume, 而 `hermes` 容器不得掛 `frontdoor-hermes`。**
   兩顆 volume 分開不是整理癖: `frontdoor-hermes` 根目錄有參謀長的 `.agent.nsec`
   (600 uid 10000), 而專家跑在**同一個 uid**, hermes 的 cross-profile guard 又不涵蓋
   terminal tool (`agent/file_safety.py:443`, 上游原話「不是 security boundary」)。
   整顆掛進去 = 一行 `cat` 就拿到參謀長的 Buzz 身分, 之後它發的文都掛在參謀長名下。
   dashboard 兩顆都掛是刻意的 —— 它只讀不跑, 那是「一次登入看到全部 agent」的來源
   (`list_profiles()` 列舉 `$HERMES_HOME/profiles`)。
   **專家之間不隔離** (同容器同 uid), 這是換 8 倍記憶體的顯式取捨: 每專家一容器是
   ~118MB × N (Python heap 是 RssAnon, 行程間不共享), multiplex 是 ~148MB + ~9MB × N。
   要對某個專家硬隔離, 用上游 `container_boot.py` 的 per-profile s6 slot, 資料不用搬。
   **dashboard 容器的 `command` argv[0] 必須是 `dashboard`** —— upstream 用
   `/proc/1/cmdline` 判斷要不要跳過 profile reconcile, 判錯就是兩個容器搶
   `logs/gateways/<profile>/lock` 的 s6-log restart storm。
```

在 `## 檔案地圖` 新增：

```markdown
- `patches/hermes/profiles/<name>/SOUL.md` — 專家 agent 的身分。**不是** `patches/hermes/SOUL.md` 的副本: 那份帶著「你不是實作者」, 而專家的工作就是自己動手, 套上去會切斷探索迴圈
- `scripts/test-scientist.sh` — 專家 lane 的端到端 gate (volume → gateway → 身分 → 記憶 → board)
```

- [ ] **Step 7: 全域回歸**

```bash
scripts/test-connectivity.sh && scripts/test-scientist.sh
```

Expected: `23 pass, 0 fail` 與 `31 pass, 0 fail`。

- [ ] **Step 8: Commit**

```bash
git add patches/hermes/hermes-entrypoint.sh docker-compose.yml AGENTS.md scripts/test-scientist.sh
git commit -m "$(cat <<'MSG'
feat: standing devenv lease for expert agents, and document the lane

The lease is provisioned from the paperclip image because that is where
the devenv CLI lives; copying it into the hermes image would give the
stack a second implementation of a generic resource-lease tool, free to
drift. The result travels on the keys volume and is merged (not
seeded-once) into the profile .env, so a DEVENV_SECRET_SALT rotation can
still reach an existing profile.

AGENTS.md gains invariant 8: the hermes container must never mount
frontdoor-hermes, and the dashboard's argv[0] must stay `dashboard`.
Both have failure modes that do not look like their cause — a leaked
chief-of-staff identity, and an s6-log restart storm.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

### Task 7: 開箱即用驗收

**為什麼需要這個 task**: Task 1–6 全程都是對一個**既有**的 stack 手動
`--force-recreate` 某個 one-shot。那證明不了「乾淨機器 `setup.sh` 一次到位」——
compose 的 one-shot 在容器已存在且 exit 0 時**不會**重跑，所以「我手動重跑過所以它
會動」是錯的推論。這個 task 把開箱即用變成一條會失敗的檢查。

**Files:**
- Create: `scripts/audit-bootstrap.sh`
- Modify: `scripts/test-connectivity.sh`
- Modify: `SETUP.md`

**Interfaces:**
- Consumes: Task 1–6 的全部產物。
- Produces: 無下游。

- [ ] **Step 1: 寫 bootstrap 歸屬稽核（非破壞性）**

這支 script 問一個問題：**科學家需要的每一份狀態，是不是都有一個 compose 裡的
自動產生者？** 它不碰資料，可以隨時跑。

Create `scripts/audit-bootstrap.sh`:

```bash
#!/usr/bin/env bash
# Does every piece of scientist state have an automatic producer?
#
# A fresh `scripts/setup.sh` must produce a fully working expert lane with no
# migration script and no manual step. The trap this guards against: compose
# one-shots are NOT re-run when a container already exists and exited 0, so
# "I re-ran it by hand and it worked" says nothing about a fresh machine.
# Every row below must name a producer that runs unattended on `up`.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0
ok()   { printf 'PASS  %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf 'FAIL  %s\n' "$1"; FAIL=$((FAIL + 1)); }

# has <label> <file> <pattern>
has() {
    if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1 (missing in $2)"; fi
}

echo "── every artifact has an automatic producer ──"
has "scientist keypair: buzz-keys one-shot"           patches/buzz/generate-keys.sh          'gen scientist'
has "relay membership: buzz-bootstrap one-shot"       patches/buzz/add-member.sh             'for _who in agent scientist'
has "discovery + channels: frontdoor register loop"   patches/buzz/opc-register-agent.sh     'scientist|scientist|'
has "profile skeleton: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    'opc_seed_expert_profile agt-scientist'
has "SOUL.md: image + boot sync"                      patches/hermes/hermes-entrypoint.sh    'profiles/$_p/SOUL.md'
has "experiment queue: hermes entrypoint"             patches/hermes/hermes-entrypoint.sh    'experiment-queue'
has "memory tenancy: tencentdb-bootstrap one-shot"    patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh 'EXTRA_AGENTS'
has "board agent: paperclip-bootstrap one-shot"       patches/paperclip/opc-paperclip-bootstrap.sh 'SCIENTIST_NAME'
has "devenv lease: devenv-expert-leases one-shot"     docker-compose.yml                     'devenv-expert-leases'
has "api key ships in .env.example"                   .env.example                           'HERMES_SCIENTIST_API_KEY'

echo "── ordering: nothing races its producer ──"
# hermes reads /keys/scientist.nsec; buzz-keys writes it.
if python3 - <<'PYEOF'
import sys, re
svc = open("docker-compose.yml").read()
m = re.search(r"\n  hermes:\n(.*?)(?=\n  [a-z][a-z0-9-]*:\n)", svc, re.S)
sys.exit(0 if m and "buzz-keys:" in m.group(1) else 1)
PYEOF
then ok "hermes depends_on buzz-keys"; else bad "hermes depends_on buzz-keys"; fi
has "entrypoint also waits for the key"  patches/hermes/hermes-entrypoint.sh  'wait_for_keys /keys/paperclip-api.key /keys/tencentdb-admin-user-id /keys/scientist.nsec'

echo "── idempotence: re-running a producer must not duplicate ──"
has "keys: only generates what is absent"    patches/buzz/generate-keys.sh       'already present'
has "cron: guarded by job name"              patches/hermes/hermes-entrypoint.sh 'grep -q "experiment-queue"'
has "board agent: reconciles, not create-only" patches/paperclip/opc-paperclip-bootstrap.sh 'adapterConfig reconciled'
has "agent reconcile is one shared helper"   patches/paperclip/opc-paperclip-bootstrap.sh 'reconcile_agent()'
has "tencentdb: get before create"           patches/tencentdb-agent-memory/MemoryCore/opc-tencentdb-provision.sh 'already exists'

echo
printf 'result: %d pass, %d fail\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
```

```bash
chmod +x scripts/audit-bootstrap.sh
```

- [ ] **Step 2: 跑它**

Run: `scripts/audit-bootstrap.sh`

Expected: `result: 17 pass, 0 fail`。任何一項 FAIL 都代表那份狀態在乾淨機器上不會自己
出現 —— 回去把它補成 one-shot 或 entrypoint 的一部分，**不要**寫 migration script。

- [ ] **Step 3: 把科學家納入 setup.sh 建議的驗證**

`setup.sh` 結尾指的是 `scripts/test-connectivity.sh`，所以那支要看得到科學家，否則
乾淨安裝壞掉時沒有任何地方會講。在 `scripts/test-connectivity.sh` 的
`check "hermes API       :${HERMES_API_PORT:-8642}/" ...` 那行之後插入：

```bash
# Expert agent profiles are served on the same port under /p/<name>. A 404
# here means the profile directory never got seeded; a 401 means it exists
# but has no usable per-profile API_SERVER_KEY (the guard is fail-closed).
check "hermes scientist :${HERMES_API_PORT:-8642}/p/agt-scientist/" http_ok \
  "http://127.0.0.1:${HERMES_API_PORT:-8642}/p/agt-scientist/v1/health" 200
```

Run: `scripts/test-connectivity.sh`

Expected: `result: 24 pass, 0 fail`。

- [ ] **Step 4: 寫既有安裝的手動調整段落**

使用者要的是「別人開箱即用；我這台既有的手動調就好」。把手動那半收斂成一段可以
整段貼的指令，不要散落在六個 task 裡。在 `SETUP.md` 末尾新增：

```markdown
## 既有安裝: 啟用科學家 lane

乾淨機器**不需要這段** —— `scripts/setup.sh` 會一次到位。這段是給目前那台**已經在跑**
的 stack 的一次性手動調整 (`AGENTS.md`「部署假設」: 不為單一機器建立升級路徑)。
需要它的原因只有一個: compose 的 one-shot 在容器已存在且 exit 0 時不會重跑。

```bash
# 1. .env 補一把 per-profile 金鑰 (16 字元以上; 少於 16 會 fail-closed 全部 401)
grep -q '^HERMES_SCIENTIST_API_KEY=' .env || \
  printf 'HERMES_SCIENTIST_API_KEY=%s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 32)" >> .env

# 2. 重建 image 並套用 compose 改動
scripts/prepare.sh && docker compose up -d --build

# 3. 催三個既有的 one-shot (新的 devenv-expert-leases 會自己跑)
docker compose up --force-recreate buzz-keys buzz-bootstrap tencentdb-bootstrap paperclip-bootstrap

# 4. 驗證
scripts/test-connectivity.sh && scripts/test-scientist.sh
```

三個 one-shot 都是冪等的: `buzz-keys` 只補缺的鑰匙 (既有的 relay/agent 身分不動,
所以 community 與成員關係不受影響)、`tencentdb-bootstrap` 先 get 再 create、
`paperclip-bootstrap` 是 reconcile 而非 create-only。
```

- [x] **Step 5: 乾淨機器演練（破壞性）—— 使用者決定跳過**

原本要做 `docker compose down -v` + `scripts/setup.sh`，驗證乾淨機器零手動步驟。
**使用者選擇跳過**，因為代價是清掉 Buzz community 與全部對話、Paperclip 的 issue 與
project、TencentDB 記憶、prototype 目錄與 devenv 租約。

**要誠實記下這件事的後果**: 「開箱即用」在本次實作中**只被靜態證明**（Step 1 的
`audit-bootstrap.sh` 逐項確認每份狀態都有自動產生者、沒有 race、產生者冪等），
**沒有被動態證明**。audit 抓得到「忘了寫產生者」，抓不到「產生者在乾淨環境下會失敗」
（例如某個 one-shot 隱含依賴一份只在既有 volume 上存在的檔案）。

下次真的需要 `down -v` 時（換機器、或不變量 5 的其他理由），順手跑一次
`scripts/test-connectivity.sh && scripts/test-scientist.sh` 就補上了這個證明。

- [ ] **Step 6: Commit**

```bash
git add scripts/audit-bootstrap.sh scripts/test-connectivity.sh SETUP.md
git commit -m "$(cat <<'MSG'
feat: make the scientist lane work out of the box

Tasks 1-6 were all verified against a live stack by re-running one-shots
by hand, which proves nothing about a fresh machine: compose does not
re-run a one-shot whose container already exited 0. audit-bootstrap.sh
asks the question that actually matters — does every piece of scientist
state have an unattended producer, is nothing racing that producer, and
is every producer idempotent.

test-connectivity.sh gains the profile route because that is the script
setup.sh tells people to run; without it a broken fresh install has
nowhere to surface.

SETUP.md gets the existing-install steps as one pasteable block rather
than scattered across the plan. Fresh machines need none of it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
MSG
)"
```

---

## Verification Summary

實作完成後這兩條都要綠：

```bash
scripts/audit-bootstrap.sh     # 17 pass, 0 fail  — 每份狀態都有自動產生者
scripts/test-connectivity.sh   # 24 pass, 0 fail  — 既有功能沒被弄壞 + 科學家路由活著
scripts/test-scientist.sh      # 31 pass, 0 fail  — 科學家 lane 從 volume 到 board
```

再加上兩個機器驗不出來的人工檢查：

1. **Buzz 發文者是 `scientist` 不是 `hermes`**（Task 3 Step 11）—— 這是「不共用參謀長身分」那條硬需求唯一的真實檢驗。
2. **從 board 指派一張 issue 會叫醒科學家，dashboard 切 profile 看得到那次 session**（Task 5 Step 9）—— 這是整條鏈路的端到端證明。
3. ~~`down -v` + `setup.sh` 演練~~ —— **使用者決定跳過**（破壞性）。所以「開箱即用」只有 `audit-bootstrap.sh` 的靜態保證，沒有動態驗證；差別與補救見 Task 7 Step 5。
