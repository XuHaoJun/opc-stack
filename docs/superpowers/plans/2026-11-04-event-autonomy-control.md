# OPC Event & Autonomy Control Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the one-way watcher into a closed loop: Paperclip work events reach Buzz through an OPC-owned deterministic service, Hermes verifies and decides, and persisted mandates/policy control what may run, pause, stop and alert.

**Architecture:** A standalone `event-bridge` compose service (Python 3 stdlib, sqlite state, `buzz` CLI for transport) polls Paperclip for issue/run transitions, emits a versioned event contract with a signed `opc-event` tag, and delivers at-least-once through an outbox. The same service owns policy (mandates/overrides), track-aware admission (pause via Paperclip's native agent status), owner-authorized force stop, and health classification. Hermes wakes on Buzz, re-reads Paperclip, and obeys policy; it never becomes the authorization source.

**Tech Stack:** Python 3.14 stdlib (sqlite3, http.server, urllib, subprocess, unittest), `buzz` CLI, Paperclip REST, Docker Compose, POSIX shell gates, Rust patches for `buzz-acp`.

**Spec:** `docs/superpowers/specs/2026-11-04-event-autonomy-control-design.md`

## Global Constraints

- Never edit `upstream/` directly; all local change goes through `patches/` + `scripts/prepare.sh`.
- `upstream/paperclip` / `buzz` / `hermes` / `tencentdb-agent-memory` stay byte-identical to their pinned tags.
- No new Python dependencies: stdlib only (the image has no package manager budget and must build offline).
- No host mounts and no `privileged` in compose; the new service adds only `opc-keys` (ro) and `opc-event-state`.
- Every new persisted state has an idempotent producer (entrypoint/one-shot), never a manual step.
- `BUZZ_CLI` calls must never log `--private-key`, tokens or key contents.
- `patches/buzz/SOUL.md` and `patches/hermes/SOUL.md` stay byte-identical; likewise the two `paperclip-api` skills and the two `opc-paperclip` copies (enforced by `scripts/prepare.sh`).
- Health monitoring never calls the cancel API; force stop only after an owner-signed command.
- Unlock is always manual; no scheduled reclamation.
- Patches apply with `patch -p1 --fuzz=0` so upstream drift fails the build.
- Event ids are deterministic; delivery is at-least-once; consumption is idempotent.
- All new env vars are documented in `SETUP.md` and defaulted in compose.

## Review Focus

These are the failure modes the spec implies but no single task's happy-path test covers. Each is pinned by a named test in the task that owns the code.

1. A crash between Buzz send and the local ack must not produce a second Hermes turn or a second follow-up ticket.
2. A Lab lock must never touch Core agents, and unlocking must never clear a manually paused agent it did not pause.
3. A forged `opc-event` (wrong author) or a replayed owner command must be refused and audited.
4. A ticket with no origin markers, or a private channel the notifier cannot post to, must still reach a visible destination — never silently dropped.
5. A run whose liveness cannot be determined must be reported as `unknown`, never as stalled, and must never be cancelled.

---

## File Structure

Created:

```
patches/event-bridge/
  Dockerfile                       # FROM frontdoor (python3, buzz, jq, curl)
  opc-control                      # operator/agent CLI (thin HTTP client)
  opc_bridge/__init__.py
  opc_bridge/config.py             # env → Config, clock
  opc_bridge/events.py             # contract, ids, mapping, message rendering
  opc_bridge/store.py              # sqlite schema, outbox, cursor, policy, audit
  opc_bridge/paperclip.py          # REST client (injectable opener)
  opc_bridge/buzz.py               # CLI wrapper (injectable runner)
  opc_bridge/poller.py             # issue transitions, reconcile, baseline, backfill
  opc_bridge/deliver.py            # outbox worker, destination ladder
  opc_bridge/policy.py             # precedence resolver, hard rules
  opc_bridge/control.py            # track lock/resume, allocation, force stop, operator auth
  opc_bridge/health.py             # classification, reminders
  opc_bridge/api.py                # stdlib HTTP API
  opc_bridge/cli.py                # opc-control implementation
  opc_bridge/main.py               # wiring, threads, signals
  tests/fakes.py                   # fake Paperclip server + fake buzz runner
  tests/test_events.py
  tests/test_store.py
  tests/test_paperclip.py
  tests/test_poller.py
  tests/test_buzz.py
  tests/test_deliver.py
  tests/test_policy.py
  tests/test_control.py
  tests/test_health.py
  tests/test_api.py
patches/buzz/patches/opc-event-tag-cli.patch        # buz messages send --tag
patches/buzz/patches/opc-event-gate.patch           # buzz-acp dedupe + author gate
tests/event-bridge.sh                               # offline gate (unit suite in image)
tests/event-identity.sh                             # live: identity + registration
tests/event-loop.sh                                 # live: end-to-end + crash recovery
tests/autonomy.sh                                   # live: mandates/policy
tests/admission.sh                                  # live: lock/pause/restart
tests/force-stop.sh                                 # live: owner-authorized cancel
tests/buzz-event-gate.sh                            # offline: Rust gate unit test
```

Modified:

```
docker-compose.yml                    # event-bridge service + volume
patches/buzz/generate-keys.sh         # paperclip keypair + opc-control token
patches/buzz/Dockerfile               # COPY/patch: two new patches, drop watcher
patches/buzz/frontdoor-entrypoint.sh  # drop watcher sweep, mirror opc-control key
patches/buzz/opc-register-agent.sh    # publish paperclip kind:0 only; no 10100
patches/buzz/opc-paperclip           # labels, admission check, bridge_adaptive source
patches/hermes/opc-paperclip          # byte-identical copy
patches/buzz/skills/paperclip-api/SKILL.md   # event handling + policy workflow
patches/hermes/skills/paperclip-api/SKILL.md # byte-identical copy
patches/buzz/SOUL.md / patches/hermes/SOUL.md # durable authorization rules
tests/audit-bootstrap.sh              # producers for every new state
tests/connectivity.sh                 # bridge health + auth
tests/fresh-install.sh                # new gates
AGENTS.md, SETUP.md                   # architecture rules + operations
```

Deleted:

```
patches/buzz/opc-issue-watcher.sh
```

---

## Phase 1 — Event loop

### Task 1: Service skeleton, config and sqlite schema

**Files:**
- Create: `patches/event-bridge/Dockerfile`, `patches/event-bridge/opc_bridge/{__init__,config,store,main}.py`, `patches/event-bridge/tests/fakes.py`, `patches/event-bridge/tests/test_store.py`
- Modify: `docker-compose.yml` (new service + `opc-event-state` volume), `tests/event-bridge.sh` (new)

**Interfaces:**
- Produces: `config.load(env) -> Config` (frozen dataclass; fields exactly as spec §16, plus `db_path`, `api_key_path`, `notifier_key_path`, `test_now`); `config.now(cfg) -> float` honouring `OPC_TEST_NOW`; `store.Store(db_path)` with `Store.close()`, `Store.schema_version() -> int`, `Store.set_meta(key, value)`, `Store.get_meta(key) -> str|None`.
- Produces: `store.SCHEMA_VERSION = 1` and tables `meta, cursor, issue_state, origin, events, deliveries, run_health, policies, mandates, track_state, agent_pause_ledger, control_actions, auth_uses, audit` (columns fixed by spec §15).
- Produces: compose service `event-bridge` (image `${IMAGE_PREFIX:-opc}/event-bridge:local`, volume `opc-event-state:/var/lib/opc-bridge`, `opc-keys:/keys:ro`, no published port).

- [ ] **Step 1: Write the failing schema test**

```python
# patches/event-bridge/tests/test_store.py
def test_creating_schema_twice_is_idempotent(tmp_path):
    first = store.Store(tmp_path / "a.db"); first.close()
    second = store.Store(tmp_path / "a.db")   # must not raise
    assert second.schema_version() == store.SCHEMA_VERSION
    tables = set(second.table_names())
    assert {"events", "deliveries", "policies", "mandates", "auth_uses"} <= tables
```

- [ ] **Step 2: Run it and confirm failure**

Run: `docker compose build event-bridge && tests/event-bridge.sh`
Expected: FAIL — `ModuleNotFoundError: opc_bridge`, then `no such table: meta` after the first fix.

- [ ] **Step 3: Implement `config.py`, `store.py`, minimal `main.py`**

`Store.__init__` opens sqlite (`PRAGMA journal_mode=WAL`, `foreign_keys=ON`) and applies `SCHEMA_SQL` guarded by `PRAGMA user_version`. `main.py` at this task only builds `Config` + `Store`, logs, and exits 0. Dockerfile copies `opc_bridge/` and `tests/` into `/opt/opc-bridge`, entrypoint `python3 -m opc_bridge.main`, base `FROM ${FRONTDOOR_IMAGE} AS frontdoor`.

- [ ] **Step 4: Add the compose service and the gate script**

`tests/event-bridge.sh` runs:
`docker compose run --rm --no-deps -T --entrypoint python3 event-bridge -m unittest discover -s /opt/opc-bridge/tests -t /opt/opc-bridge -v`
and exits non-zero on any failure. Compose service gets `depends_on: paperclip(service_healthy), buzz(service_healthy), buzz-keys(service_completed_successfully)`, `additional_contexts: {frontdoor: "service:frontdoor"}`, `build.args.FRONTDOOR_IMAGE`.

- [ ] **Step 5: Verify**

Run: `scripts/prepare.sh && docker compose build event-bridge && tests/event-bridge.sh`
Expected: 1 test OK; `docker compose config` resolves the service with no published ports.

- [ ] **Step 6: Commit**

```bash
git add patches/event-bridge docker-compose.yml tests/event-bridge.sh
git commit -m "feat(event-bridge): service skeleton, config and sqlite schema"
```

---

### Task 2: Event contract, deterministic ids and message rendering

**Files:**
- Create: `patches/event-bridge/opc_bridge/events.py`, `patches/event-bridge/tests/test_events.py`

**Interfaces:**
- Produces: `events.Event` dataclass with the exact fields in spec §6 (all strings except `schema_version: int`).
- Produces: `events.issue_event_id(issue_id: str, status: str, terminal_ts: str) -> str`, `events.run_event_id(run_id: str, status: str) -> str`, `events.health_event_id(run_id: str, kind: str, bucket: int) -> str` — all `"evt_" + sha256(payload).hexdigest()[:12]`.
- Produces: `events.classify_issue(previous: dict|None, issue: dict) -> str|None` returning one of `paperclip.issue.completed|blocked|cancelled` or `None`.
- Produces: `events.render_message(event: Event, issue: dict, public_url: str) -> str`; `events.event_tags(event: Event) -> dict[str, str]` (keys `opc-event`, `opc-event-type`, `opc-issue`, `opc-track`).

- [ ] **Step 1: Write the failing tests**

```python
def test_reopened_and_recompleted_issue_gets_a_new_event_id():
    a = events.issue_event_id("i1", "done", "2026-11-04T02:00:00Z")
    b = events.issue_event_id("i1", "done", "2026-11-04T03:00:00Z")
    assert a != b and a.startswith("evt_") and len(a) == 16

def test_same_transition_is_stable_across_restarts():
    assert events.issue_event_id("i1", "done", "T") == events.issue_event_id("i1", "done", "T")

def test_classify_only_emits_on_change():
    assert events.classify_issue({"status": "in_progress"}, {"status": "done", "completedAt": "T"}) == "paperclip.issue.completed"
    assert events.classify_issue({"status": "done"}, {"status": "done", "completedAt": "T"}) is None
    assert events.classify_issue(None, {"status": "done", "completedAt": "T"}) is None   # baseline, not a transition

def test_blocked_reassert_is_a_new_event_when_transition_ts_changes():
    prev = {"status": "blocked", "blockedTransitionAt": "T1"}
    assert events.classify_issue(prev, {"status": "blocked", "blockedTransitionAt": "T2"}) == "paperclip.issue.blocked"

def test_message_carries_machine_line_and_destination_fields():
    msg = events.render_message(evt, {"title": "t", "identifier": "OPC-7"}, "https://board.example")
    assert msg.rstrip().endswith(f"OPC_EVENT: {evt.event_id}")
    assert "https://board.example/issues/OPC-7" in msg
```

- [ ] **Step 2: Run and confirm failure** — `tests/event-bridge.sh` → FAIL (module missing).

- [ ] **Step 3: Implement** the three id functions, `classify_issue` (terminal-ts per status: `completedAt`/`cancelledAt`/`blockedTransitionAt` falling back to `updatedAt`), `render_message` (Chinese header + title + ticket link + blank line + machine line) and `event_tags`.

- [ ] **Step 4: Run and confirm pass** — `tests/event-bridge.sh` → all tests OK.

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): versioned event contract and deterministic ids"`

---

### Task 3: Paperclip REST client

**Files:**
- Create: `patches/event-bridge/opc_bridge/paperclip.py`, `patches/event-bridge/tests/test_paperclip.py`
- Extend: `patches/event-bridge/tests/fakes.py` (fake Paperclip HTTP server on `127.0.0.1:0`)

**Interfaces:**
- Produces: `paperclip.Paperclip(base_url: str, api_key: str, opener=urllib.request.urlopen)` with
  `issues_updated_since(iso: str, limit=100, offset=0) -> list[dict]`,
  `issue(issue_id) -> dict`, `comments(issue_id, limit=500) -> list[dict]`,
  `agents() -> list[dict]`, `patch_agent(agent_id, body: dict) -> dict`,
  `patch_issue(issue_id, body: dict) -> dict`, `cancel_run(run_id) -> dict`,
  `run(run_id) -> dict`, `live_runs() -> list[dict]`, `runs_for_issue(issue_id) -> list[dict]`,
  `labels() -> list[dict]`, `create_label(name, color) -> dict`.
- Produces: `paperclip.PaperclipError(status: int, body: str)`; messages never include the auth header.
- Produces: `paperclip.company_id(cfg) -> str` — resolves via `/api/companies` once and caches.

- [ ] **Step 1: Write the failing tests**

```python
def test_list_issues_parses_arrays_and_object_envelopes(fake_pc):
    assert fake_pc.client.issues_updated_since("2026-01-01T00:00:00Z")[0]["identifier"] == "OPC-1"
    fake_pc.respond_with({"issues": [{"id": "i2"}]})
    assert fake_pc.client.issues_updated_since("2026-01-01T00:00:00Z") == [{"id": "i2"}]

def test_401_is_an_error_not_an_empty_list(fake_pc):
    fake_pc.respond_status(401, "unauthorized")
    with self.assertRaises(paperclip.PaperclipError) as e:
        fake_pc.client.issues_updated_since("2026-01-01T00:00:00Z")
    assert e.exception.status == 401 and "Bearer" not in str(e.exception)

def test_every_request_carries_the_bearer_token(fake_pc):
    fake_pc.client.agents()
    assert fake_pc.last_headers["Authorization"] == "Bearer test-key"
```

- [ ] **Step 2: Run and confirm failure** — `tests/event-bridge.sh`.

- [ ] **Step 3: Implement** thin method wrappers over one `_request(method, path, body=None)`; JSON decode; empty body → `{}`; non-2xx → `PaperclipError`.

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): Paperclip REST client"`

---

### Task 4: Poller — transitions, baseline, backfill, reconcile

**Files:**
- Create: `patches/event-bridge/opc_bridge/poller.py`, `patches/event-bridge/tests/test_poller.py`
- Extend: `opc_bridge/store.py` (`cursor`, `issue_state`, `origin`, `events` inserts), `tests/fakes.py`

**Interfaces:**
- Consumes: `events.classify_issue`, `events.issue_event_id`, `Paperclip`, `Store`.
- Produces: `poller.Poller(cfg, store, pc, log=print)` with `bootstrap() -> None`,
  `tick(now: float) -> int` (returns events enqueued), `reconcile(now: float) -> int`,
  `backfill(since_iso: str) -> int`, `resolve_origin(issue_id) -> tuple[str|None,str|None]`.
- Produces: `store.enqueue_event(event: events.Event) -> bool` (False when `event_id` already exists — the dedupe point).

- [ ] **Step 1: Write the failing tests**

```python
def test_bootstrap_records_terminal_issues_without_emitting(poller_fixture):
    poller_fixture.pc.set_issues([{"id": "i1", "identifier": "OPC-1", "status": "done", "completedAt": "T1", "labelIds": []}])
    poller_fixture.poller.bootstrap()
    assert poller_fixture.store.pending_deliveries() == []

def test_terminal_transition_enqueues_exactly_one_event(poller_fixture):
    poller_fixture.seed_issue_state("i1", "in_progress")
    poller_fixture.pc.set_issues([{"id": "i1", "identifier": "OPC-1", "status": "done", "completedAt": "T2", "labelIds": []}])
    assert poller_fixture.poller.tick(now=100.0) == 1
    assert poller_fixture.poller.tick(now=101.0) == 0          # same transition, deduped

def test_origin_markers_only_from_allowed_authors(poller_fixture):
    poller_fixture.pc.set_comments("i1", [
        {"body": "BUZZ_CHANNEL: abc", "authorAgentId": "intruder"},
        {"body": "BUZZ_CHANNEL: 11111111-1111-1111-1111-111111111111", "authorAgentId": poller_fixture.frontdoor_agent_id},
        {"body": "BUZZ_EVENT: " + "a"*64, "authorAgentId": poller_fixture.frontdoor_agent_id},
    ])
    assert poller_fixture.poller.resolve_origin("i1")[0] == "11111111-1111-1111-1111-111111111111"

def test_reconcile_recovers_an_event_missed_while_stopped(poller_fixture):
    poller_fixture.pc.set_issues([{... "status": "done", "updatedAt": "T9", "completedAt": "T8"}])
    assert poller_fixture.poller.reconcile(now=200.0) == 1
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** `tick` (fetch page(s) with the 10 s overlap, classify, enqueue, upsert `issue_state`, advance cursor only after each page commits), `bootstrap` (seed open issues, mark terminal observed, cursor `now - OPC_EVENT_CUTOVER_LOOKBACK_HOURS`, and backfill track labels — Task 13 fills the label part), `reconcile`, `backfill`, `resolve_origin` (author allowlist: `frontdoor_agent_id` and `paperclip_agent_id` resolved once from `/api/agents`; strict regex for UUID and 64-hex).

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): issue transition poller with baseline and reconcile"`

---

### Task 5: Buzz client — tagged send, channels, control-channel resolution

**Files:**
- Create: `patches/event-bridge/opc_bridge/buzz.py`, `patches/event-bridge/tests/test_buzz.py`

**Interfaces:**
- Produces: `buzz.Buzz(relay_url: str, nsec_path: Path, runner=subprocess.run)` with
  `send(channel: str, content: str, reply_to: str|None, tags: dict[str,str]) -> buzz.SendResult(event_id: str, accepted: bool)`,
  `channels() -> list[dict]`, `messages(channel: str, since: int|None=None, limit: int=200) -> list[dict]`,
  `create_channel(name: str, visibility="open") -> dict`, `set_profile(name: str, about: str) -> None`.
- Produces: `buzz.SendResult` (dataclass) and `buzz.BuzzError(kind: str, message: str)` where `kind ∈ {"not_member","auth","relay","cli"}`; `not_member` is detected by the substring `restricted: not a channel member`.
- Produces: `buzz.resolve_control_channel(cfg, client, store) -> str` — env value, else channel named `opc-control`, else create it, persist in `meta`.

- [ ] **Step 1: Write the failing tests**

```python
def test_send_passes_repeatable_tags_and_reads_stdin(fake_buzz):
    fake_buzz.client.send("c1", "hello", reply_to="a"*64, tags={"opc-event": "evt_1", "opc-track": "lab"})
    argv = fake_buzz.last_argv
    assert argv.count("--tag") == 2 and "--content" in argv and argv[argv.index("--content")+1] == "-"
    assert fake_buzz.last_stdin == "hello"

def test_send_success_requires_event_id_and_accepted(fake_buzz):
    fake_buzz.respond({"event_id": "", "accepted": True})
    with self.assertRaises(buzz.BuzzError): fake_buzz.client.send("c1", "x", None, {})

def test_not_member_is_classified(fake_buzz):
    fake_buzz.fail(exit_code=2, stderr='{"error":"relay_error","message":"relay error 400: restricted: not a channel member"}')
    with self.assertRaises(buzz.BuzzError) as e: fake_buzz.client.send("c1", "x", None, {})
    assert e.exception.kind == "not_member"

def test_private_key_never_appears_in_errors(fake_buzz):
    fake_buzz.fail(exit_code=2, stderr="boom")
    with self.assertRaises(buzz.BuzzError) as e: fake_buzz.client.send("c1", "x", None, {})
    assert "nsec" not in str(e.exception)
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** the wrapper: argv `[buzz, --relay <url>, --private-key <nsec>, messages, send, --channel, <c>, --content, -, --reply-to?, --tag K=V...]`, content via stdin, `BUZZ_AUTH_TAG` explicitly removed from the child env, 30 s timeout, stdout JSON parse, stderr sanitisation.

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): buzz CLI client with signed tags"`

---

### Task 6: Outbox delivery with backoff, fallback ladder and crash recovery

**Files:**
- Create: `patches/event-bridge/opc_bridge/deliver.py`, `patches/event-bridge/tests/test_deliver.py`
- Extend: `opc_bridge/store.py` (`deliveries` claim/mark/reschedule, `pending_deliveries()`, `recover_inflight()`)

**Interfaces:**
- Consumes: `Store`, `Buzz`, `Config`.
- Produces: `deliver.Deliverer(cfg, store, buzz_client, clock=config.now)` with
  `run_once() -> int` (delivered count), `destination(event) -> str|None`, `next_backoff(attempts) -> float`.
- Produces: `store.claim_due(now) -> list[dict]`, `store.mark_sent(event_id, buzz_event_id)`, `store.mark_fallback(event_id, buzz_event_id)`, `store.reschedule(event_id, next_at, error)`, `store.mark_failed(event_id, reason)`, `store.recover_inflight()`.

- [ ] **Step 1: Write the failing tests**

```python
def test_failed_send_is_retried_not_marked_delivered(delivery_fixture):
    delivery_fixture.buzz.fail_once()
    assert delivery_fixture.deliverer.run_once() == 0
    row = delivery_fixture.store.delivery("evt_1")
    assert row["state"] == "pending" and row["attempts"] == 1 and row["next_attempt_at"] > row["created_at"]

def test_crash_between_send_and_ack_redelivers_the_same_event_id(delivery_fixture):
    delivery_fixture.store.claim_due(now=0)            # state=sending
    delivery_fixture.store.recover_inflight()          # simulates restart
    delivery_fixture.deliverer.run_once()
    assert delivery_fixture.buzz.sent_tags[0]["opc-event"] == "evt_1"   # same id, consumer dedupes

def test_not_member_goes_to_the_fallback_channel(delivery_fixture):
    delivery_fixture.buzz.fail_not_member()
    delivery_fixture.deliverer.run_once()
    assert delivery_fixture.store.delivery("evt_1")["state"] == "fallback_sent"
    assert delivery_fixture.buzz.sent_channels == ["fallback-uuid"]

def test_no_destination_marks_failed_and_audits(delivery_fixture):
    delivery_fixture.event.origin_channel_id = None
    delivery_fixture.store.mark_failed("evt_1", "no_destination")
    assert delivery_fixture.store.audit_rows()[-1]["action"] == "delivery_failed"

def test_expired_event_is_not_delivered(delivery_fixture):
    delivery_fixture.event.occurred_at = "2000-01-01T00:00:00Z"
    delivery_fixture.deliverer.run_once()
    assert delivery_fixture.store.delivery("evt_1")["state"] == "expired"

def test_backoff_is_capped(delivery_fixture):
    assert delivery_fixture.deliverer.next_backoff(20) == 300
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** the state machine (`pending → sending → sent|fallback_sent|failed|expired`), the destination ladder (`origin` → `OPC_EVENT_FALLBACK_CHANNEL` → control channel → `failed/no_destination`), max-age expiry, jittered exponential backoff, and `recover_inflight()` at boot.

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): at-least-once outbox with fallback ladder"`

---

### Task 7: Service wiring — threads, health endpoint, graceful shutdown

**Files:**
- Modify: `patches/event-bridge/opc_bridge/main.py`, `patches/event-bridge/opc_bridge/api.py`
- Create: `patches/event-bridge/tests/test_api.py`

**Interfaces:**
- Produces: `api.serve_forever(cfg, handler_context) -> http.server.ThreadingHTTPServer` bound to `OPC_API_LISTEN`; `GET /v1/health` returns `{"status":"ok","schema_version":1,"version":"<git describe or 'dev'>"}` with **no** auth, every other route requires `Authorization: Bearer <opc-control.key>`.
- Produces: `main.main() -> int` starting `Poller`, `Deliverer`, `HealthMonitor` (Task 22 fills it) and the API thread; SIGTERM sets a stop event and joins with a 10 s deadline.

- [ ] **Step 1: Write the failing test**

```python
def test_health_is_open_but_policy_requires_the_key(api_client):
    assert api_client.get("/v1/health").status == 200
    assert api_client.get("/v1/policy/effective").status == 401
    assert api_client.get("/v1/policy/effective", key="right").status in (200, 400)
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** the HTTP server and the thread wiring; `poller` sleeps `OPC_EVENT_POLL_INTERVAL`, reconcile every `OPC_EVENT_RECONCILE_SECONDS`, deliverer every 1 s.

- [ ] **Step 4: Verify live**

Run: `docker compose up -d --build event-bridge && docker compose exec -T event-bridge python3 -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8645/v1/health').read().decode())"`
Expected: `{"status": "ok", ...}`; `docker compose ps event-bridge` healthy.

- [ ] **Step 5: Commit** — `git commit -m "feat(event-bridge): service wiring and health endpoint"`

---

### Task 8: Buzz patches — `--tag` CLI flag and the buzz-acp event gate

**Files:**
- Create: `patches/buzz/patches/opc-event-tag-cli.patch`, `patches/buzz/patches/opc-event-gate.patch`, `tests/buzz-event-gate.sh`
- Modify: `patches/buzz/Dockerfile` (COPY + `patch -p1 --fuzz=0` lines next to the existing memory-ingress patch)

**Interfaces:**
- Produces: CLI `messages send --tag KEY=VALUE` (repeatable) that appends `["KEY","VALUE"]` to the built event tags for kind 9 and rejects `KEY` not matching `^[a-z0-9-]{1,32}$` with exit 1.
- Produces: buzz-acp config `opc_event_tag` (`BUZZ_ACP_OPC_EVENT_TAG`, default `opc-event`), `opc_event_authors` (`BUZZ_ACP_OPC_EVENT_AUTHORS`, CSV hex), `ignore_agent_authors` (`BUZZ_ACP_IGNORE_AGENT_AUTHORS`, default true), `agent_authors` (`BUZZ_ACP_AGENT_AUTHORS`, CSV hex).
- Produces (behaviour): tagged event from a non-listed author ⇒ dropped + INFO log; tagged event id already in `$HERMES_HOME/.buzz-acp/opc-events.seen` ⇒ dropped; untagged kind:9 from a listed agent author ⇒ dropped when `ignore_agent_authors`.

- [ ] **Step 1: Write the failing Rust unit test inside the patch**

A new `#[cfg(test)] mod opc_event_gate_tests` in `crates/buzz-acp/src/lib.rs` covering `admit_opc_event(tag_present, author_listed, seen)` and `should_ignore_agent_author(ignore, authors, author)` truth tables.

- [ ] **Step 2: Run it on a scratch clone and confirm failure**

`tests/buzz-event-gate.sh` clones `upstream/buzz` into `mktemp -d`, copies `opc/patches/*.patch`, applies with `--fuzz=0`, runs `cargo test -p buzz-acp opc_event_gate -- --nocapture`.
Expected: FAIL (patch does not exist yet).

- [ ] **Step 3: Write both patches**

Small, surgical hunks: CLI arg struct + builder call site; buzz-acp config fields + the two predicates called at the top of the event dispatch loop (before the author gate), plus a `SeenSet` helper (append + truncate to 5000, atomic rename) in a new module.

- [ ] **Step 4: Run and confirm pass** — `tests/buzz-event-gate.sh` → `test result: ok`.

- [ ] **Step 5: Verify the real build applies the patches**

Run: `scripts/prepare.sh && docker compose build buzz frontdoor`
Expected: build succeeds; `docker compose exec -T frontdoor buzz messages send --help | grep -- --tag` shows the flag.

- [ ] **Step 6: Commit** — `git commit -m "feat(buzz): opc-event tag flag and deterministic wake gate"`

---

### Task 9: Paperclip notifier identity and registration

**Files:**
- Modify: `patches/buzz/generate-keys.sh` (add `gen paperclip`, add `gen_token opc-control` writing `/keys/opc-control.key`)
- Modify: `patches/buzz/opc-register-agent.sh` (AGENTS list gains `paperclip|paperclip|Paperclip work events and notifications`; **skip** the kind:10100 publication for it; never pass `BUZZ_AUTH_TAG`)
- Modify: `patches/buzz/frontdoor-entrypoint.sh` (mirror `/keys/opc-control.key` into `$HERMES_HOME/.opc-control.key`; export `OPC_API_KEY`)
- Modify: `docker-compose.yml` (event-bridge env: `OPC_API_KEY` path, `BUZZ_ACP_OPC_EVENT_AUTHORS`/`BUZZ_ACP_AGENT_AUTHORS` computed by the frontdoor entrypoint from the keys volume, not hardcoded)
- Create: `tests/event-identity.sh`

**Interfaces:**
- Produces: `/keys/paperclip.nsec|.pub` (600, idempotent), `/keys/opc-control.key` (600, 64 hex).
- Produces: bridge `publisher.publish_profile(...)` called on boot and on a 30 s retry loop until the relay acknowledges; verified by reading back kind:0 through `buzz users`/relay query.
- Produces: frontdoor entrypoint exports `BUZZ_ACP_AGENT_AUTHORS` = every `/keys/*.pub` except `relay.pub`, `agent.pub`, `paperclip.pub`.

- [ ] **Step 1: Write the failing live test**

`tests/event-identity.sh` asserts:
1. `docker compose exec -T buzz test -s /keys/paperclip.nsec` and `opc-control.key` exist, mode 600.
2. `buzz --private-key "$(cat /keys/paperclip.nsec)" --relay ... users profile` (or `messages get` author check) shows display name `paperclip`.
3. `buzz --private-key "$(cat /keys/paperclip.nsec)" --relay ... channels set-add-policy` is **not** required to succeed; instead assert the desktop-visible agent directory does **not** list the paperclip key: `channels list` + relay query for kind:10100 with `#p=<paperclip.pub>` returns zero events.
4. `docker compose exec -T frontdoor printenv BUZZ_ACP_AGENT_AUTHORS` contains `scientist.pub`'s hex and not `agent.pub`/`paperclip.pub`.

- [ ] **Step 2: Run and confirm failure** — `tests/event-identity.sh` → missing keys.

- [ ] **Step 3: Implement the producers and the bridge profile publisher.**

- [ ] **Step 4: Verify on the live stack**

```bash
docker compose up -d --force-recreate buzz-keys
docker compose up -d --build buzz frontdoor event-bridge
tests/event-identity.sh
```
Expected: all four assertions pass; `docker compose logs event-bridge | grep "profile published"`.

- [ ] **Step 5: Commit** — `git commit -m "feat: paperclip notifier identity and deterministic key producers"`

---

### Task 10: Retire the watcher (clean cutover)

**Files:**
- Delete: `patches/buzz/opc-issue-watcher.sh`
- Modify: `patches/buzz/Dockerfile` (drop COPY + chmod entry), `patches/buzz/frontdoor-entrypoint.sh` (drop sweep block, keep relay-url file write for compatibility), `patches/buzz/skills/paperclip-api/SKILL.md` + `patches/hermes/skills/paperclip-api/SKILL.md` (drop watcher step 5, keep marker comments), `tests/audit-bootstrap.sh` (assert no watcher references)

**Interfaces:**
- Produces: `grep -rn opc-issue-watcher patches docker-compose.yml tests` returns only the audit assertion (a negative check).

- [ ] **Step 1: Write the failing negative test** in `tests/audit-bootstrap.sh`:

```bash
if grep -rqs "opc-issue-watcher" patches docker-compose.yml; then
  fail "watcher retired: no references left"; else pass "watcher retired"; fi
```

- [ ] **Step 2: Run and confirm failure** — `tests/audit-bootstrap.sh`.

- [ ] **Step 3: Delete/update the files; keep the `BUZZ_CHANNEL`/`BUZZ_EVENT` marker instructions** in both skills.

- [ ] **Step 4: Run and confirm pass** — `scripts/prepare.sh && tests/audit-bootstrap.sh`.

- [ ] **Step 5: Commit** — `git commit -m "refactor: retire the issue watcher, bridge owns delivery"`

---

### Task 11: Hermes event-decision policy (skill + SOUL)

**Files:**
- Modify: `patches/buzz/skills/paperclip-api/SKILL.md`, `patches/hermes/skills/paperclip-api/SKILL.md` (identical), `patches/buzz/SOUL.md`, `patches/hermes/SOUL.md` (identical)

**Interfaces:**
- Produces: a skill section **Event handling** with the five rules from spec §9 and the exact commands: re-read issue, read comments, `GET $OPC_API_URL/v1/policy/effective?project_id=…`, reply with `--reply-to`, no reply to agent-authored messages, no second action for the same `OPC_EVENT` id.
- Produces: SOUL section **System events are not authorization** (three bullets, spec §9).

- [ ] **Step 1: Write the failing static test** in `tests/audit-bootstrap.sh`:

```bash
has "skill documents the event gate" patches/buzz/skills/paperclip-api/SKILL.md 'OPC_EVENT'
has "SOUL forbids self-authorization"  patches/buzz/SOUL.md               'never authorization'
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Write the text in both copies; `scripts/prepare.sh` must print `SAME` for both pairs.**

- [ ] **Step 4: Verify** — `scripts/prepare.sh && tests/audit-bootstrap.sh` → `SAME paperclip-api skill`, `SAME agent SOUL.md`, new assertions pass.

- [ ] **Step 5: Commit** — `git commit -m "docs(hermes): event handling policy and authorization boundary"`

---

### Task 12: Live end-to-end gate (Phase 1 exit)

**Files:**
- Create: `tests/event-loop.sh`
- Modify: `tests/connectivity.sh`, `tests/fresh-install.sh`

**Interfaces:**
- Consumes: every Phase 1 component.
- Produces: a live test that creates a synthetic issue (board key), adds `BUZZ_CHANNEL`/`BUZZ_EVENT` markers as the frontdoor agent, sets `done`, and asserts one tagged message in the thread.

- [ ] **Step 1: Write the failing test**

`tests/event-loop.sh` does, in order:
1. Creates an issue via `POST /api/companies/:c/issues` with `assigneeAgentId` = a paused `process` adapter agent (no run) and `status: "todo"`.
2. Adds the two marker comments (frontdoor agent's key, via the Paperclip API as that agent? use the board key and `actorAgentId`-free comments — then the marker-author allowlist check applies to the agent association, so the test creates them through `docker compose exec frontdoor` with `PAPERCLIP_API_KEY`).
3. `PATCH {status:"done"}`; waits ≤ 30 s for the bridge delivery.
4. Asserts `buzz messages get --channel <origin>` contains exactly one message whose `tags` include `["opc-event", evt]`, `pubkey == paperclip.pub`, and `e` tag == origin event id.
5. Restarts `event-bridge` right after the send (simulate crash by `docker compose kill -s KILL event-bridge` between poll and delivery) and asserts still exactly one **turn**: count messages with that tag == 1 (the second delivery must be dropped by the buzz-acp gate; verified by `hermes` log absence of a second `opc-event` admission).
6. Completes a second issue while `event-bridge` is stopped, starts it, asserts delivered exactly once.

- [ ] **Step 2: Run and confirm failure** — `tests/event-loop.sh` → no message.

- [ ] **Step 3: Fix** whatever the test exposes (this task is mostly integration: cursor/interval tuning, default channel resolution, tag plumbing).

- [ ] **Step 4: Run and confirm pass** — `tests/event-loop.sh`; then `tests/connectivity.sh` (bridge health + identity live) and `tests/audit-bootstrap.sh`.

- [ ] **Step 5: Commit** — `git commit -m "test: phase 1 end-to-end event loop gate"`

---

## Phase 2 — Autonomy policy

### Task 13: Track/style labels and helper admission check

**Files:**
- Modify: `patches/buzz/opc-paperclip` (+ identical `patches/hermes/opc-paperclip`)
- Modify: `patches/event-bridge/opc_bridge/poller.py` (bootstrap backfill)
- Create: `patches/event-bridge/tests/test_labels.py`

**Interfaces:**
- Produces: `opc-paperclip labels ensure` creating `track:core|track:lab|style:blueprint|style:exploration` (colors `#2563eb|#7c3aed|#0f766e|#b45309`) via `POST /api/companies/:c/labels` when absent.
- Produces: issue creation sends `labelIds` derived from `Track:`/`Style:` markers with the spec defaults (engineering→core/blueprint, prototype|research→lab/exploration).
- Produces: before creating, the helper calls `GET $OPC_API_URL/v1/policy/effective?track=<track>` and refuses with exit 3 and the resolver's reason when `track_locked` or the mandate forbids follow-ups.
- Produces: `poller.backfill_labels() -> int` — idempotent; labels open issues without `track:*` by lane; unresolved ⇒ no label + `opc.policy.violation` event (deduped per issue+reason).

- [ ] **Step 1: Write the failing tests**

```python
def test_track_label_defaults_follow_lane():
    assert opc_labels_for({"Lane": "engineering"}) == {"track:core", "style:blueprint"}
    assert opc_labels_for({"Lane": "research"}) == {"track:lab", "style:exploration"}
    assert opc_labels_for({"Lane": "engineering", "Track": "lab", "Style": "exploration"}) == {"track:lab", "style:exploration"}

def test_conflicting_labels_resolve_to_unknown(policy_store):
    assert track_of({"track:core", "track:lab"}) == "unknown"
```

- [ ] **Step 2: Run and confirm failure** — `tests/event-bridge.sh` (python) and a small shell assertion in `tests/autonomy.sh` for the helper.

- [ ] **Step 3: Implement** the marker parsing/validation (`^core|^lab`, `^blueprint|^exploration`), label ensure/attach, the admission refusal, and the backfill.

- [ ] **Step 4: Verify live**

Run: `docker compose exec -T event-bridge python3 -m opc_bridge.cli backfill-labels` then `curl` an open issue's `labelIds` — non-empty and matching its lane; run twice, same result (idempotent).

- [ ] **Step 5: Commit** — `git commit -m "feat: track/style labels, label backfill and helper admission check"`

---

### Task 14: Policy store and precedence resolver

**Files:**
- Create: `patches/event-bridge/opc_bridge/policy.py`, `patches/event-bridge/tests/test_policy.py`
- Extend: `opc_bridge/store.py` (`policies`, `mandates` CRUD: `active_overrides`, `active_mandates`, `insert_policy`, `revoke_policy`, `insert_mandate`, `revoke_mandate`)

**Interfaces:**
- Produces: `policy.PRIORITY = {"hard":10,"operator":20,"mandate":30,"adaptive":40,"default":50}`; `policy.HARD_RULES: dict[str, dict]` containing `production_deploy`, `merge_main`, `publish_public`, `spend_money`, `destructive_delete`, `grant_access` all `allowed: False`.
- Produces: `policy.effective(store, company_id, project_id, track, now) -> dict` = `{"values": {key: value}, "provenance": {key: {"priority":int,"source":str,"scope":str,"row_id":str|None}}}`.
- Produces: `policy.check(store, ..., action: str) -> tuple[bool, str]` — `(allowed, reason)`; hard rules win over everything.
- Produces: `policy.tie_break(candidates) -> dict` implementing project>track>company, newest, then most restrictive.

- [ ] **Step 1: Write the failing tests**

```python
def test_operator_override_beats_mandate_and_default(policy_store):
    policy_store.add_override("track", "lab", "followups.allowed", False, actor="operator:x")
    policy_store.add_mandate(track="lab", followups_allowed=True, expires_at=None)
    eff = policy.effective(policy_store, "c", None, "lab", now=0)
    assert eff["values"]["followups.allowed"] is False
    assert eff["provenance"]["followups.allowed"]["priority"] == 20

def test_expired_mandate_resolves_to_nothing(policy_store):
    policy_store.add_mandate(track="lab", followups_allowed=True, expires_at="2000-01-01T00:00:00Z")
    assert policy.effective(policy_store, "c", None, "lab", now=0)["values"]["followups.allowed"] is False   # default

def test_project_beats_track_then_most_restrictive(policy_store):
    policy_store.add_mandate(scope="track", scope_id="lab", followups_allowed=True)
    policy_store.add_mandate(scope="project", scope_id="p1", followups_allowed=False)
    assert policy.effective(policy_store, "c", "p1", "lab", 0)["values"]["followups.allowed"] is False

def test_hard_rule_cannot_be_enabled_by_a_mandate(policy_store):
    policy_store.add_mandate(track="core", allowed=["production_deploy"])
    assert policy.check(policy_store, "c", None, "core", "production_deploy", 0) == (False, "hard rule")

def test_effective_reports_provenance_for_every_key(policy_store):
    eff = policy.effective(policy_store, "c", None, "lab", 0)
    assert set(eff["values"]) == set(eff["provenance"])
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** — resolution over active rows, the tie-break, the default map (`allocation.core=70`, `allocation.lab=30`, `followups.allowed=False`, `style=blueprint`, `track_locked=False`), and `check`.

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat: policy store with precedence and hard safety rules"`

---

### Task 15: Mandates, operator command verification and the control API

**Files:**
- Create: `patches/event-bridge/opc_bridge/control.py`, `patches/event-bridge/tests/test_control.py`
- Modify: `opc_bridge/api.py` (routes), `opc_bridge/cli.py` (subcommands)

**Interfaces:**
- Produces: `control.OperatorAuth(cfg, buzz_client, store)` with `verify(command: str, event_id: str, now: float) -> None` raising `control.AuthError(reason)`; `AuthError.reason ∈ {"missing","not_found","wrong_author","stale","command_mismatch","replayed"}`.
- Produces: `control.grant_mandate(...)`, `control.revoke_mandate(...)`, `control.set_policy(...)` — each writes one row + one `control_actions` row + one `audit` row with `source_event_id`.
- Produces: HTTP routes `GET/POST /v1/mandates`, `POST /v1/mandates/{id}/revoke`, `POST /v1/control/override`, `DELETE /v1/control/override`, `GET /v1/control/state`, `GET /v1/events`, `GET /v1/policy/effective`, and `acl`: reads use `OPC_API_KEY`; every POST/DELETE additionally needs `authorization_event_id` + `command`.

- [ ] **Step 1: Write the failing tests**

```python
def test_replayed_command_is_rejected(auth_fixture):
    auth_fixture.sign("!opc mandate grant project=p1 track=lab style=exploration", "e"*64)
    auth_fixture.auth.verify("!opc mandate grant project=p1 track=lab style=exploration", "e"*64, now=10)
    with self.assertRaises(control.AuthError) as e:
        auth_fixture.auth.verify("!opc mandate grant project=p1 track=lab style=exploration", "e"*64, now=11)
    assert e.exception.reason == "replayed"

def test_wrong_author_is_rejected(auth_fixture):
    auth_fixture.sign("!opc pause lab", "e"*64, author="f"*64)
    with self.assertRaises(control.AuthError) as e: auth_fixture.auth.verify("!opc pause lab", "e"*64, 10)
    assert e.exception.reason == "wrong_author"

def test_command_text_must_match_the_signed_message(auth_fixture):
    auth_fixture.sign("!opc pause lab", "e"*64)
    with self.assertRaises(control.AuthError) as e: auth_fixture.auth.verify("!opc resume lab", "e"*64, 10)
    assert e.exception.reason == "command_mismatch"

def test_stale_command_is_rejected(auth_fixture):
    auth_fixture.sign("!opc pause lab", "e"*64, created_at=0)
    with self.assertRaises(control.AuthError) as e: auth_fixture.auth.verify("!opc pause lab", "e"*64, 1000)
    assert e.exception.reason == "stale"
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** the verifier (scan the control channel with `buzz messages get --since now-900 --limit 200`, match `id`, `pubkey`, `created_at`, normalised content), the one-time-use table, the mandate/policy writers, and the API/CLI surface. `opc-control` CLI maps 1:1 to the HTTP routes and also supports `backfill`, `backfill-labels`, `state`, `events`.

- [ ] **Step 4: Run and confirm pass** — `tests/event-bridge.sh`.

- [ ] **Step 5: Commit** — `git commit -m "feat: owner-signed control API, mandates and audit"`

---

### Task 16: Hermes consumes effective policy (live)

**Files:**
- Modify: both `paperclip-api` skills (identical), `tests/autonomy.sh` (new)

**Interfaces:**
- Produces: skill workflow step: fetch effective policy before any follow-up, quote `provenance` when refusing, never grant a mandate.
- Consumes: Task 15 routes.

- [ ] **Step 1: Write the failing live test** `tests/autonomy.sh`:

1. Owner-signed `!opc mandate grant project=<p> track=lab style=exploration followups=on expires=+1d` in the control channel (test signs with the owner's `agent.nsec`? no — the owner is the human key from `.env`; the test uses `BUZZ_ACP_AGENT_OWNER`'s nsec **only if** the test harness holds it; otherwise it asserts the **negative** path and the positive path via the ops CLI with `--as-ops`). Decide in-task: positive path uses `docker compose exec event-bridge opc-control mandate grant ... --reason test` (documented ops path) and the **owner path** is asserted with a wrong-author rejection plus a manually seeded valid command fixture (offline test already covers validation).
2. Asserts `GET /v1/policy/effective` flips `followups.allowed` and the provenance names the mandate.
3. Revokes it; asserts it flips back and a follow-up attempt is refused by `opc-paperclip` with exit 3.

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement the skill text + any endpoint fixes the test exposes.**

- [ ] **Step 4: Run and confirm pass** — `tests/autonomy.sh && tests/event-bridge.sh && scripts/prepare.sh`.

- [ ] **Step 5: Commit** — `git commit -m "feat(hermes): consume effective policy before follow-ups"`

---

## Phase 3 — Resource control

### Task 17: Track→agent resolution and slot allocation

**Files:**
- Modify: `opc_bridge/control.py`, `opc_bridge/store.py` (`track_state`), `patches/buzz/opc-paperclip` (+copy)
- Create: `patches/event-bridge/tests/test_allocation.py`

**Interfaces:**
- Produces: `control.resolve_track_agents(pc, track, selectors: list[str]) -> list[dict]` — selector grammar `role:<r>` / `name:<n>`; exact-match only; unknown selector ⇒ `control.PolicyError`.
- Produces: `control.apply_allocation(cfg, store, pc, core: int, lab: int, actor: str, source_event_id: str|None) -> dict` — writes policy rows (priority 20 for operator, 40 for adaptive), pauses/unpauses at 0, writes slots otherwise, always audits.
- Produces: `control.slot_plan(core: int, lab: int, budget: int, lab_agents: int) -> dict[str,int]` (pure, tested).
- Produces: `opc-paperclip agent concurrency show` reports `source: bridge_adaptive` when `metadata.opcBridgeAllocation.maxConcurrentRuns == current`.

- [ ] **Step 1: Write the failing tests**

```python
def test_zero_share_pauses_only_that_track(allocation_fixture):
    allocation_fixture.apply(core=100, lab=0)
    assert allocation_fixture.paused("Prototyper") and allocation_fixture.paused("Scientist")
    assert not allocation_fixture.paused("Fullstack Engineer")

def test_hard_lock_survives_a_bridge_restart(allocation_fixture):
    allocation_fixture.apply(core=100, lab=0)
    allocation_fixture.restart()
    allocation_fixture.reconcile()
    assert allocation_fixture.paused("Scientist")          # re-asserted from policy + ledger

def test_unlock_refuses_when_holds_were_changed(allocation_fixture):
    allocation_fixture.apply(core=100, lab=0)
    allocation_fixture.operator_sets_hold("Scientist", "manual")
    assert allocation_fixture.resume("lab").refused is True

def test_slots_follow_the_split(allocation_fixture):
    assert control.slot_plan(70, 30, 6, 2) == {"core": 4, "lab_each": 1}
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** resolution, `slot_plan`, pause/resume with the ledger and settle polling (`PATCH` then poll `GET /api/agents/:id` until `lifecycleState ∈ {paused, ready}` or 60 s), re-assert on boot, and the helper's third source.

- [ ] **Step 4: Verify live** — `tests/admission.sh` (Task 18) is the gate; here run the pure tests + a manual `docker compose exec event-bridge opc-control allocation --core 100 --lab 0` and inspect `curl /api/agents` statuses.

- [ ] **Step 5: Commit** — `git commit -m "feat: track-aware allocation with native agent pause"`

---

### Task 18: Live admission gate

**Files:**
- Create: `tests/admission.sh`
- Modify: `tests/fresh-install.sh`

**Interfaces:**
- Consumes: Task 17.

- [ ] **Step 1: Write the failing test** `tests/admission.sh`:

1. Record statuses of the three lane agents.
2. `opc-control allocation --core 100 --lab 0 --reason test`.
3. Assert lab agents `paused`, core unchanged; assert a `track:lab` ticket in `todo` assigned to Prototyper is not claimed within 20 s (status stays `todo`, no run row `running`).
4. `docker compose restart event-bridge paperclip`; assert the lock is still effective (no lab run started, policy still 100/0).
5. Adaptive pass (`opc-control allocation --mode adaptive`) does not flip it (operator override wins).
6. `opc-control resume --track lab --reason test`; assert lab agents leave `paused` only because the ledger says we paused them.

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Fix** what the test exposes (settle waits, ledger checks, `agents.status` refresh).

- [ ] **Step 4: Run and confirm pass**; also `tests/connectivity.sh` (agent status effects) and `tests/audit-bootstrap.sh`.

- [ ] **Step 5: Commit** — `git commit -m "test: live admission and hard-lock gate"`

---

### Task 19: Force stop (owner-authorized)

**Files:**
- Modify: `opc_bridge/control.py`, `opc_bridge/api.py`, `opc_bridge/cli.py`
- Create: `tests/force-stop.sh`, `patches/event-bridge/tests/test_force_stop.py`

**Interfaces:**
- Produces: `control.force_stop(pc, run_id: str, actor: str, source_event_id: str) -> dict` — cancels one run, polls ≤ 60 s for `cancelled`, posts an `OPC_CONTROL:` comment on the issue, writes audit; raises `control.ForceStopError("not_cancellable"|"timeout"|"not_found")`.
- Produces: `POST /v1/control/force-stop {run_id, authorization_event_id, command}`.

- [ ] **Step 1: Write the failing tests**

```python
def test_cancels_only_the_named_run(force_fixture):
    force_fixture.two_running_runs()
    control.force_stop(force_fixture.pc, "run-1", "operator:x", "e"*64)
    assert force_fixture.pc.cancelled == ["run-1"]
    assert force_fixture.pc.runs["run-2"]["status"] == "running"

def test_terminal_run_is_not_cancellable(force_fixture):
    with self.assertRaises(control.ForceStopError) as e:
        control.force_stop(force_fixture.pc, force_fixture.succeeded_run, "op", "e"*64)
    assert e.exception.reason == "not_cancellable"

def test_audit_and_comment_are_written(force_fixture):
    control.force_stop(...)
    assert force_fixture.store.audit_rows()[-1]["action"] == "force_stop"
    assert force_fixture.pc.comments[-1]["body"].startswith("OPC_CONTROL: force-stop run=")
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement**, then the live test: create a temporary `process`-adapter agent whose command is `sleep 300`, wake it on a ticket, wait for `running`, post `!opc force-stop run <id>` to the control channel **as the owner key** (test resolves the owner’s nsec from `.env`/`/keys` only when `OPC_TEST_OWNER_NSEC` is exported; otherwise it skips the signed path and asserts the ops CLI path, printing `SKIP owner-signature`), call the API, assert one run `cancelled`, the other untouched, workspace still on disk, status reported `interrupted`, and a second call with the same event id returns 409.

- [ ] **Step 4: Run and confirm pass** — `tests/force-stop.sh && tests/event-bridge.sh`.

- [ ] **Step 5: Commit** — `git commit -m "feat: owner-authorized force stop of a single run"`

---

## Phase 4 — Health monitoring

### Task 20: Health classifier and reminder dedupe

**Files:**
- Create: `patches/event-bridge/opc_bridge/health.py`, `patches/event-bridge/tests/test_health.py`
- Extend: `opc_bridge/store.py` (`run_health`)

**Interfaces:**
- Produces: `health.classify(run: dict, last_output_at: float|None, agent_status: str|None, now: float, slow: int, stall: int) -> str` returning `healthy|slow|suspected_stalled|lost|unknown`.
- Produces: `health.HealthMonitor(cfg, store, pc, enqueue)` with `tick(now: float) -> int` implementing first-notify + reminder cadence + recovery, keyed `run|<id>|<state>`.
- Produces: `health.NEVER_CALLS = ("cancel_run",)` — enforced by a test that asserts the module has no reference to `cancel_run` (static check via `inspect.getsource`).

- [ ] **Step 1: Write the failing tests**

```python
def test_gateway_run_without_pid_is_unknown_not_stalled():
    assert health.classify({"id": "r", "status": "running", "lastEventAt": None}, None, "idle", now=10_000, slow=900, stall=1800) == "unknown"

def test_silence_past_stall_with_suspicion_signal_is_stalled():
    run = {"id": "r", "status": "running", "outputSilence": {"level": "critical", "lastOutputAt": 1000.0}}
    assert health.classify(run, 1000.0, "idle", now=1000+1801, slow=900, stall=1800) == "suspected_stalled"

def test_running_while_issue_terminal_is_lost():
    assert health.classify({"id": "r", "status": "running", "issueStatus": "done"}, None, "idle", 10_000, 900, 1800) == "lost"

def test_reminder_cadence_and_recovery(monitor_fixture):
    monitor_fixture.run_stalled()
    assert monitor_fixture.tick(1000) == 1
    assert monitor_fixture.tick(1000 + 60) == 0
    assert monitor_fixture.tick(1000 + 1800) == 1        # reminder
    monitor_fixture.run_progressed()
    assert monitor_fixture.tick(1000 + 1801) == 1        # recovered event

def test_health_module_never_calls_cancel():
    assert "cancel_run" not in inspect.getsource(health)
```

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** classification with an explicit authority order (run status → `lastEventAt` → `lastOutputAt` → `outputSilence.level` → agent status → pid presence), the dedupe/reminder logic, and the `unknown` default when no signal exists. Emit `opc.run.*` events through `store.enqueue_event`.

- [ ] **Step 4: Run and confirm pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat: deterministic run health classification without cancellation"`

---

### Task 21: Health monitor live wiring and alerts

**Files:**
- Modify: `opc_bridge/main.py` (start monitor thread), `opc_bridge/deliver.py` (health events share the outbox), `docker-compose.yml` (env defaults)
- Create: `patches/event-bridge/tests/test_health_live.py` (fake-mode), `tests/health-live.sh` (optional, documented)

**Interfaces:**
- Produces: monitor tick every `OPC_HEALTH_INTERVAL`; alerts routed as `opc.run.stalled|lost|recovered` through the same destination ladder.

- [ ] **Step 1: Write the failing test** — a fake-mode integration: feed `live-runs` + `heartbeat-runs` fixtures into `HealthMonitor.tick` and assert one event per state transition, correct `event_type`, and the rendered message names the run/ticket but **no** remediation command.

- [ ] **Step 2: Run and confirm failure.**

- [ ] **Step 3: Implement** the wiring and env plumbing.

- [ ] **Step 4: Verify live** — `docker compose up -d event-bridge`; `docker compose exec event-bridge python3 -m opc_bridge.cli state` shows `health: ok`, and with a deliberately stalled fixture (`OPC_TEST_NOW` + fake mode) the event lands in the audit feed.

- [ ] **Step 5: Commit** — `git commit -m "feat: health monitor alerts through the event outbox"`

---

## Closeout

### Task 22: Documentation, gates and fresh-install proof

**Files:**
- Modify: `AGENTS.md`, `SETUP.md`, `tests/audit-bootstrap.sh`, `tests/connectivity.sh`, `tests/fresh-install.sh`

**Interfaces:**
- Produces: AGENTS sections `Event Bridge` (identity, one writer per state, no watcher), `Autonomy Control` (precedence, tracks→agents, pause/force-stop semantics); SETUP runbook (env table, `!opc` grammar, control channel join, backfill, upgrade/recreate commands, failure modes).
- Produces: `tests/fresh-install.sh` runs `tests/event-bridge.sh`, `tests/event-identity.sh`, `tests/event-loop.sh`, `tests/autonomy.sh`, `tests/admission.sh`, `tests/force-stop.sh` (signed path skipped when no owner key, printed) — so a clean clone proves the loop.

- [ ] **Step 1: Write the failing documentation gates** in `tests/audit-bootstrap.sh`:

```bash
has "event bridge: identity producer"   patches/buzz/generate-keys.sh  'gen paperclip'
has "event bridge: compose service"     docker-compose.yml            'event-bridge:'
has "event bridge: state volume"        docker-compose.yml            'opc-event-state:/var/lib/opc-bridge'
has "event bridge: owner-only force stop" patches/event-bridge/opc_bridge/control.py 'OPC_OPERATOR_PUBKEY'
has "event bridge: no cancel in health" patches/event-bridge/opc_bridge/health.py   'never cancel'
```

- [ ] **Step 2: Run and confirm failure** — `tests/audit-bootstrap.sh`.

- [ ] **Step 3: Write the docs and gates.**

- [ ] **Step 4: Full verification (the real gate)**

```bash
scripts/prepare.sh
docker compose build
docker compose up -d
tests/audit-bootstrap.sh && tests/connectivity.sh && tests/event-bridge.sh \
  && tests/event-identity.sh && tests/event-loop.sh && tests/autonomy.sh \
  && tests/admission.sh && tests/force-stop.sh && tests/migrations.sh
```
Expected: every gate green, bridge healthy, `paperclip` identity visible, one message per event.

- [ ] **Step 5: Commit** — `git commit -m "docs: event & autonomy control architecture, runbook and gates"`

---

## Self-review notes (author)

- Spec §3.5 event types → Tasks 2/4/20/21. §3.6 contract → Task 2. §3.7 delivery → Tasks 6/12.
- §3.3/3.4 identity and least privilege → Task 9. §3.2/§3.3 event source choice → Tasks 1/4.
- §4 decision loop → Task 11/16. §4.4 wake gate → Task 8.
- §5 mandate → Tasks 14/15. §5.3 hard rules → Task 14. §6 tracks → Task 13. §7 allocation → Task 17.
- §8 pause/force stop → Tasks 17/18/19. §9 health → Tasks 20/21. §10 precedence → Task 14.
- §11 phases → phase boundaries are the task-group boundaries above; each phase ends with a live gate (12, 16, 18+19, 21).
- Review Focus lines map to: 1 → Task 6/12; 2 → Task 17/18; 3 → Task 8/15/19; 4 → Task 5/6; 5 → Task 20.
