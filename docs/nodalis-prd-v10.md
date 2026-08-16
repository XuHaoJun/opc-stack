# Nodalis / OPC Agent OS — v1.0 Architecture Reset

- **版本**：v1.0（v10）
- **日期**：2026-08-15
- **前一版**：`nodalis-prd-v9.md` / v0.9
- **狀態**：Architecture reset / implementation decision
- **核心決策**：**暫停 v0.9 的 greenfield Nodalis kernel 實作；先採用 Buzz + Paperclip + Hermes 的組合，讓現成元件承擔 surface / work control / runtime。Nodalis 降為「有證據才實作」的 optional thin governance kernel。**

---

# 0. Executive Decision

v0.9 的核心假設之一是：

```text
Buzz      ≈ conversation surface
Paperclip ≈ optional work projection
Hermes    ≈ agent runtime
Nodalis   = workflow / governance / work canonical authority
```

Hermes Agent 0.20.1 的 source code 已使這個假設失效一半：Hermes 現在不只是 runtime，而是已包含：

```text
Projects
Kanban task DB
atomic task claim
claim TTL / heartbeat / stale reclaim
attempt history
review state
blocking / unblock
comments / attachments
dependency links
worker dispatcher
profile-based worker assignment
Kanban Swarm
LLM task decomposition
workspace / worktree integration
web Kanban dashboard
```

同時，Paperclip master 已正式提供 Hermes adapter，且提供 Hermes → Paperclip 的 scoped task bridge；Buzz 也已正式把 Hermes Agent 列為 ACP preset runtime。

因此本版不再問：

> 「如何自己重做一套 agent OS，再把 Hermes / Paperclip / Buzz 接進來？」

而改問：

> **「現成三個元件已經能覆蓋多少 OPC operating model？只有哪些能力值得自己擁有？」**

## v1.0 決策

### Decision A — 停止目前 v0.9 greenfield kernel 的主線實作

不刪除 repo、不丟棄 v0.9 的研究成果，但將其視為：

```text
reference architecture
+ formal-governance research backlog
+ future thin-kernel design source
```

**不再把 Workflow IR / Restate interpreter / verifier / custom WorkItem / custom attention ledger 當成目前第一個要交付的產品。**

### Decision B — 第一個真實 OPC stack 使用三層組合

```text
                    HUMAN
                      │
                      ▼
               ┌────────────┐
               │    Buzz    │
               │ conversation│
               │  + mobile  │
               └─────┬──────┘
                     │ ACP: hermes-acp
                     ▼
          ┌──────────────────────┐
          │ Front-door Hermes    │
          │ intent / dialogue /  │
          │ research / triage    │
          └─────────┬────────────┘
                    │ scoped paperclip-task-bridge
                    ▼
          ┌──────────────────────┐
          │      Paperclip       │
          │ CANONICAL WORK PLANE │
          │ issue / pipeline /   │
          │ case / approval /    │
          │ heartbeat / budget   │
          └──────┬─────┬─────────┘
                 │     │
        ┌────────┘     └──────────────┐
        ▼                             ▼
   Hermes workers               Coding workers
   research/general        Codex / Claude / OpenCode / ...
```

### Decision C — **Paperclip 是 integrated mode 的唯一 canonical work plane**

在這個 deployment mode 中：

```text
Paperclip Issue / PipelineCase / Run = durable work truth
```

**Hermes Kanban 不可同時成為第二套 durable work authority。**

Paperclip-managed 或 Buzz-front-door Hermes profiles 預設：

```text
Hermes kanban toolset     DISABLED
Hermes kanban dispatcher  DISABLED / unused
```

如需工具限制：Paperclip Hermes adapter 本身已有 `toolsets` allowlist；Hermes 也已有 `disabled_toolsets` configuration。

### Decision D — Buzz 只做 conversation / intent / notification surface

Buzz 的 workflow engine 可以用於：

```text
message/reaction-triggered automation
notification
small webhook glue
simple approval/delay interaction
```

但**不作 OPC work orchestration authority**。

### Decision E — Nodalis 只有在「formal governance gap」被真實 workload 證明後才復活

未來若需要，Nodalis 不再復活成整套 Agent OS，而是：

```text
Nodalis Governance Kernel
- plan admission / verification
- policy envelope
- provenance / control-taint
- high-risk action gateway
- optional attention governance
```

它位於 Paperclip / runtime 的 action admission 邊界，而不是重做：

```text
chat
board
projects
agent runtime
worktree
heartbeat
ticket tracker
company/org UI
```

---

# 1. 為什麼是 v10，而不是 v9.1

這不是局部修正。

v0.9 的架構是：

```text
Nodalis owns workflow semantics + work truth
external systems are adapters/projections
```

v1.0 改成：

```text
Adopt-first
Paperclip owns work truth
Hermes owns agent execution
Buzz owns conversation surface
Nodalis owns nothing until a missing invariant is proven valuable
```

這是 architecture authority 的重新分配，因此必須升 major decision version。

---

# 2. Code Evidence

以下皆來自本次提供的 source code，而不是產品宣傳頁。

## 2.1 Buzz 已直接支援 Hermes Agent

Buzz preset runtime：

`buzz-main/desktop/src-tauri/src/managed_agents/discovery/presets.rs:156-164`

```rust
PresetHarness {
    id: "hermes",
    label: "Hermes Agent",
    command: "hermes-acp",
    args: &[],
    ...
}
```

Buzz ACP README 也明列 Hermes Agent 為 Tier-2 preset：

`buzz-main/crates/buzz-acp/README.md:264-272`

```text
Buzz Desktop supports registering any ACP-speaking agent tool...
Tier-2 ... Hermes Agent ...
```

並且 Buzz 對 Hermes 有 runtime-specific startup handling：

`buzz-main/crates/buzz-acp/src/config.rs:709-725`

```rust
"hermes" | "hermes-agent" | "hermes-acp"
    => [("HERMES_ACP_SKIP_CONFIGURED_MCP", "1")]
```

這表示 **Buzz ↔ Hermes 不是理論上「都支援 ACP 所以應該可接」；Buzz source 已經特別處理 Hermes。**

## 2.2 Paperclip 已直接支援 Hermes Agent

`paperclip-master/packages/adapters/hermes/src/index.ts:1-8`

```text
Hermes Agent adapter for Paperclip.
Runs Hermes Agent ... as a managed employee in a Paperclip company.
```

adapter 宣告：

```text
supportsSessionResume: true
nativeContextManagement: confirmed
```

並支援：

```text
hermes_local
hermes_gateway
```

因此 **Paperclip → Hermes** 已是 upstream-supported path。

## 2.3 Hermes → Paperclip 也已經是正式 path

Paperclip 的 Hermes package 內建：

`packages/adapters/hermes/skills/paperclip-task-bridge/SKILL.md`

source 明寫：

```text
This is the Hermes-to-Paperclip direction,
separate from Paperclip waking Hermes...
```

它提供：

```text
list-assigned
create-task
comment
update-status
```

而且 bridge key 可被限制到：

```text
parentIssueId(s)
projectId(s)
```

source line 43 明確規定 scoped key：

```text
can create tasks only inside that boundary,
can comment/update only bridge-created or assigned issues,
and cannot use company-wide issue list/search/read surfaces.
```

所以前門 Hermes 可以安全地把 Buzz conversation materialize 成 Paperclip work，而不需要拿一把 company-wide admin token。

## 2.4 Hermes 0.20.1 已經有自己的 work control plane

`hermes_cli/config_defaults.py:2415+`：

```text
Kanban multi-agent coordination
- dispatcher loop
- stale reclaim
- promote dependency-satisfied tasks
- spawn workers
- review dispatch
- per-profile concurrency cap
- auto decomposition
```

`tools/kanban_tools.py:2356-2478` 把以下都正式註冊為 `toolset="kanban"`：

```text
kanban_show
kanban_list
kanban_complete
kanban_block
kanban_request_review
kanban_request_changes
kanban_heartbeat
kanban_comment
kanban_attach
kanban_create
kanban_unblock
kanban_link
```

這不是 UI-only feature；agent 本身可以改變 work graph。

## 2.5 但 Hermes Kanban 尚未等價於 Paperclip Pipeline

Hermes schema 自己寫得非常清楚：

`hermes_cli/kanban_db.py:1369-1373`

```text
Forward-compat for v2 workflow routing.
In v1 ... dispatcher doesn't consult them for routing yet.
```

以及 `1451-1457`：

```text
v2 ... use step_key to drive per-stage workflow routing;
in v1 ... kernel ignores it.
```

相對地，Paperclip 已有 first-class：

`packages/db/src/schema/pipelines.ts`

```text
pipelines
pipeline_stages
pipeline_transitions
```

以及 `pipeline_cases.ts`：

```text
stageId
parentCaseId
leaseToken
leaseExpiresAt
childCount
terminalChildCount
blockers
issue links
```

因此 Hermes 0.20.x **大幅吃掉 task orchestration，但尚未吃掉 Paperclip 的 generic process/case model。**

## 2.6 Hermes Project 與 Paperclip Project 也不是同一層

Hermes `projects_db.py:1-18` 自己把 Project 定義為：

```text
human-named, multi-folder workspace
Desktop session grouping
Kanban task worktree anchor
per-profile store
```

所以 Hermes Project 偏向：

```text
runtime / workspace / repo grouping
```

Paperclip Project 則位於 company / issue / pipeline business control plane。

名稱一樣，不應因此合併語意。

---

# 3. 三種候選架構重新評估

## Option 1 — 繼續 Nodalis v0.9 Greenfield

```text
Buzz → Nodalis → Paperclip(optional)
             → Hermes/Codex/...
             → Restate
             → custom WorkItem
             → custom verifier
```

### 優點

- formal verifier / policy envelope 最完整；
- dynamic graph 語意完全自有；
- provenance/control-taint、attention budget 可以做到 v0.9 的強度；
- 不被 Paperclip/Hermes data model 限制。

### 缺點

- 重做的東西突然變得非常多是 upstream 已經做好的：
  - task / board
  - project/workspace
  - claim/heartbeat
  - review
  - agent dispatch
  - runtime integration
  - mobile/conversation surface
- M0 要先花數週證明 durable/replay kernel，卻還沒有實際 OPC workload 證明 formal verifier 是目前最痛的問題。

### v1.0 結論

**不再作 default path。**

---

## Option 2 — Buzz + Hermes only

```text
Buzz
  ↓ native hermes-acp
Hermes
  ↓
Hermes Projects + Kanban + Swarm + Dispatcher + Dashboard
```

### 優點

- 最少元件；
- Hermes Kanban 與 Hermes runtime 高度整合；
- dynamic decomposition / child task / review 是 agent-native；
- 對純 Hermes workforce 的 OPC 非常合理；
- 不需要同步 Paperclip work truth。

### 缺點

- workforce 主要綁 Hermes profile model；
- Codex / Claude / OpenCode 等異質 runtime 沒有像 Paperclip 那樣自然地成為同一 control plane 下的一等 worker；
- staged business process / generic Case / company budget / org governance 較弱；
- Hermes Kanban v1 workflow-template routing 還未真正被 kernel 使用；
- 若之後再加入 Paperclip，migration/sync 成本會增加。

### 適用

```text
1 human
+ 幾乎所有 worker 都是 Hermes
+ 不需要 generic business pipeline
```

### v1.0 結論

**保留為 Lean Mode，但不是目前長期推薦模式。**

---

## Option 3 — Buzz + Paperclip + Hermes / heterogeneous workers

```text
Buzz               = human conversation
Front-door Hermes  = dialogue / triage
Paperclip          = canonical work control plane
Hermes             = general/research worker runtime
Codex/Claude/...   = specialized runtime
```

### 優點

- 三組 integration 都已存在足夠的 upstream support；
- 不需自建 chat、task tracker、agent runtime；
- Paperclip 已提供多 runtime adapters：Hermes、Codex、Claude、OpenCode、Pi、Gemini、Grok、Cursor 等；
- 適合「少量 humans + many heterogeneous agents」；
- stable process 用 Paperclip Pipeline/Case；
- agent 可透過 child issues 做動態 decomposition，而不是所有事情都先畫死 Pipeline；
- Buzz 可保留 agent-first conversation UX。

### 缺點

- 必須嚴格禁止 Hermes Kanban 成為 shadow work plane；
- Buzz 與 Paperclip 之間仍需要很薄的 notification/projection integration；
- formal safety 不如 v0.9：沒有 Nodalis 等級的 typed Workflow IR / control-taint verifier / attention formalism。

### v1.0 結論

**採用。**

---

# 4. Canonical Authority Matrix

這一章是整個 v1.0 最重要的規則。

| Concern | Canonical authority | 其他系統的角色 |
|---|---|---|
| Human conversation | **Buzz** | Paperclip 只保存與 work 有關的 comment |
| Intent triage | **Front-door Hermes** | 可 materialize 為 Paperclip issue |
| Durable work item | **Paperclip Issue** | Buzz message / Hermes task 不是 truth |
| Stable business process | **Paperclip Pipeline / Case** | Hermes 不自行維護第二套 stage |
| Work assignment | **Paperclip** | Runtime 只接收 assignment |
| Agent execution | **Hermes / Codex / Claude / other adapter** | Paperclip 觀測 / wake |
| Agent-local session/memory/skills | **runtime 自己** | Paperclip 不複製 cognitive state |
| Runtime dangerous-command approval | **Hermes runtime approval** | 只管 tool safety |
| Business / work approval | **Paperclip approval / review** | Buzz 可投影 UI，不作 canonical decision |
| Conversation notification | **Buzz projection** | source event 仍來自 Paperclip |
| Git / artifact | repo / artifact backend | issue 只保存 references |
| Hermes Kanban | **disabled in integrated mode** | Lean Mode 才可 canonical |
| Buzz Workflow | surface automation only | 不作 work/process authority |

核心規則：

> **一個概念只能有一個 durable writer authority。**

---

# 5. Shadow Control Plane Rule

v0.9 最值得保留的新洞察，不是某個 crate，而是這條規則：

> **A runtime must not be allowed to create an alternate durable work graph behind the canonical control plane.**

在 integrated mode：

```text
Hermes kanban_create          DENY
Hermes kanban_link            DENY
Hermes autonomous dispatcher  OFF
Hermes Kanban Swarm           OFF
```

Agent 若要產生新的 durable work：

```text
Hermes
  ↓ paperclip-task-bridge / Paperclip API
Paperclip child issue / case
  ↓ assign/wake
worker runtime
```

這條規則同樣適用其他 runtime：

```text
Codex internal todo          = local scratch only
Claude subagent task list    = local scratch only
OpenCode internal plan       = local scratch only
```

只要它要跨 invocation、要被其他 agent 接手、要被 human 追蹤，就必須 materialize 到 Paperclip。

---

# 6. Dynamic Workflow 的新定義

v0.9 把 dynamic workflow 建成 formal executable graph。

v1.0 先使用更務實的兩層模型：

## 6.1 Stable process → Paperclip Pipeline

適合：

```text
idea → research → implementation → review → release
incident → triage → fix → verify → close
content → draft → review → publish
```

Pipeline 定義 stage / transition / approval / automation。

## 6.2 Run-specific decomposition → Issues / child issues

Agent 在真實執行時依情境：

```text
create child issue
assign different agent
add blocker/dependency
request review
create follow-up
```

也就是：

```text
Stable grammar        = Pipeline
Realized work graph   = Issue / Case hierarchy + dependencies
Execution trace       = Runs + comments + activity
```

這已經非常接近 v0.9 想要的：

```text
template / realized graph / trace
```

但**暫時沒有 formal typed IR + static verifier**。

這個缺口先量，不先造。

---

# 7. Buzz 的正確位置

Buzz **可以和 Hermes 組合，而且 upstream 已直接支援。**

因此不需要自己寫 `ConversationPort -> Hermes` 的厚 adapter。

推薦：

```text
Buzz managed agent
runtime = Hermes preset (`hermes-acp`)
profile = opc-front-door
```

Front-door Hermes 的職責：

```text
conversation
clarification
quick research
triage
判斷是否值得建立 durable work
建立 Paperclip task
查詢自己可見的 work
向 human 摘要結果
```

不應負責：

```text
持久化另一份 Kanban
自己建立跨 worker durable dependency graph
production authorization truth
company-wide Paperclip admin
```

## 7.1 Buzz Workflow 要不要用？

要，但只用在 surface automation：

```text
reaction → webhook
message → notification
scheduled reminder
simple request_approval
```

Buzz `WorkflowDef` source 仍是：

```text
trigger + ordered steps[]
```

action 也是 closed set：

```text
send_message
send_dm
set_channel_topic
add_reaction
call_webhook
request_approval
delay
```

它不是 integrated OPC dynamic work graph 的 authority。

---

# 8. Paperclip 為什麼仍值得保留，而不是只用 Hermes Kanban

Hermes 0.20.1 的 Kanban 很強，因此 Paperclip 的必要性**確實下降**。

但本專案仍有一個 Hermes Kanban 無法漂亮取代的需求：

> **heterogeneous agent workforce。**

Paperclip repository 已有多種 adapter，例如：

```text
Hermes
Codex
Claude
OpenCode
Pi
Gemini
Grok
Cursor
OpenClaw
```

這更符合 OPC 的長期 model：

```text
human 很少
agent 很多
agent 不必全部是同一 runtime
```

Paperclip 另外還有：

```text
company-scoped work
issue/comment audit trail
pipeline/case
approval
heartbeat
budget
agent registry
workspace/run supervision
```

Hermes Kanban 則最強在：

```text
Hermes-native task execution
profile dispatch
repo/worktree
swarm
agent-driven decomposition
```

因此不是「Paperclip 比 Hermes Kanban 好」，而是：

```text
如果所有 worker = Hermes → Hermes Kanban 更簡單
如果 workforce = Hermes + Codex + Claude + ... → Paperclip 更適合作 canonical plane
```

本專案採第二種。

---

# 9. Approval Semantics 必須拆開

三套系統都有 approval/review 字樣，但語意不同。

## 9.1 Hermes approval

```text
command/tool safety
MCP write trust gate
interactive dangerous action permission
```

它保護 execution environment。

## 9.2 Paperclip approval/review

```text
business/process approval
work review
pipeline gate
board governance
```

它保護 work lifecycle。

## 9.3 Buzz approval

```text
conversation UX / small automation interaction
```

## Rule

不可因 Buzz 按過一次 approve，就視為 Hermes dangerous shell permission 或 Paperclip production approval。

若未來需要跨系統 approval，必須明確做：

```text
projection + signed/canonical decision reference
```

而不是文字同步。

---

# 10. v0.9 哪些東西先放棄

以下全部從近期 implementation critical path 移除：

```text
custom Workflow IR v1
Minimal Guard language
Normalized Verification CFG
custom Restate interpreter
custom WorkItem
custom lease/heartbeat implementation
custom dynamic child-run mechanism
custom canonical conversation model
custom project/workspace abstraction
custom runtime adapter framework
custom Council service/pattern runtime
custom attention ledger as formal budget
custom workflow evolution/crystallization engine
```

理由不是它們沒有價值，而是：

> **現在沒有證據證明這些價值大於「先把現成 stack 真正跑起來」的 opportunity cost。**

---

# 11. v0.9 哪些研究成果保留

以下不是 code scope，但保留成 system invariants / future admission requirements。

## 11.1 Single authority

禁止 shadow work plane。

## 11.2 High-risk actions need explicit policy boundary

production / money / irreversible external action 不能只靠 agent prompt 自律。

第一版可先由：

```text
Paperclip approval
+ runtime tool approval
+ deployment backend policy
```

組合。

## 11.3 Retry semantics ≠ concurrency semantics

v0.9 對 `operation_key` / attempt / fencing 的分析保留，未來寫 integration adapter 時必須沿用。

## 11.4 Provenance remains valuable

但先以 references / activity / run records 做 practical provenance。

只有真實 incident 證明 prompt injection / implicit control flow 是主要治理痛點後，才實作 v0.9 的 full data/control taint model。

## 11.5 Human attention remains a product metric

先量：

```text
human approvals/day
human comments/questions per resolved task
blocked waiting for human
approval latency
```

暫時不自建 formal four-dimensional verifier budget。

---

# 12. Nodalis 的新定位

`Nodalis` 名稱保留，但目前**不是一個必須部署的 service**。

## 12.1 Phase 0

```text
Nodalis = architecture / operating model / integration conventions
```

## 12.2 若未來復活

只做：

```text
                 Nodalis Governance Gateway
                            │
         ┌──────────────────┼──────────────────┐
         ▼                  ▼                  ▼
  Paperclip mutation   deploy.production   external.message
         │                  │                  │
         └──── policy / provenance / approval ┘
```

不做：

```text
chat
board
issue tracker
agent runtime
workspace manager
company UI
```

這會把 v0.9 幾十個模組收斂成真正有差異化的 3–5 個：

```text
nodalis-policy
nodalis-provenance (optional)
nodalis-action-gateway
nodalis-audit
nodalis-attention (optional)
```

---

# 13. 何時才允許重新開始寫 Nodalis Kernel

至少有一個 hard trigger 被真實 workload 命中。

## Trigger N1 — Unverified dynamic work repeatedly causes real failures

例如：

```text
agent-generated child work repeatedly bypasses required review
wrong capability reaches production
workflow shape itself becomes safety problem
```

此時才需要 typed plan admission / verifier。

## Trigger N2 — Paperclip Pipeline + issue graph 無法表達重要 runtime workflow

不是「看起來不優雅」，而是有 ≥3 個真實 workload 需要：

```text
runtime conditional graph
bounded loops
quorum join
formal dynamic spawn admission
```

而現成模型造成實際錯誤/大量人工 glue。

## Trigger N3 — Provenance 問題產生真實 security incident / near miss

此時復活：

```text
data provenance
control taint
purpose-scoped attestation
```

## Trigger N4 — Human governance 真正成為瓶頸

至少觀察到：

```text
approval fatigue
rubber stamping
每天 interaction 數過高
大量 task blocked on human
```

才實作 attention budget / batching / standing approvals 的 formal layer。

## Trigger N5 — Durable cross-system side effects 需要更強 execution contract

如果 Paperclip + runtime adapter 在：

```text
crash recovery
ambiguous delivery
replay
idempotency
revocation
```

產生真實不可接受問題，再引入 Restate/Temporal-backed action gateway。

---

# 14. Implementation Plan

## M0 — Freeze + Compose（現在）

### 目標

證明「不用 Nodalis kernel」能不能跑真正的 OPC work loop。

### 實作

1. 暫停 v0.9 kernel feature work；保留 branch/tag。
2. 部署 Paperclip。
3. 在 Paperclip 設定至少：
   - Hermes general/research agent
   - Codex 或 Claude coding agent
4. Hermes integrated profiles：
   - 不啟用 `kanban` toolset；
   - 不啟用 Kanban dispatcher。
5. 跑 5 個真實 workload：
   - research
   - technical decision
   - code change
   - review/fix loop
   - deployment preparation
6. 所有 durable work 都必須能在 Paperclip issue/case 中找到。

### Exit

```text
沒有第二套 work truth
Hermes/Codex 都能被 Paperclip 正確 dispatch
comment/status/review 能完整回寫
human 可以看到 agent 正在做什麼
```

---

## M1 — Buzz Front Door

### 實作

1. Buzz 使用內建 Hermes preset：

```text
command = hermes-acp
```

2. 建立 `opc-front-door` Hermes profile。
3. 安裝 / materialize `paperclip-task-bridge` skill。
4. 只給 scoped bridge key：

```text
projectId / parentIssueId boundary
```

5. Front-door 判斷：

```text
small conversational work → 直接回答
需要追蹤/多 agent/長時間 → 建 Paperclip task
```

6. Front-door profile 同樣禁用 Hermes Kanban。

### Paperclip → Buzz

第一版不必做完整雙向同步。

只做一個薄 notification bridge：

```text
Paperclip event
  → bridge/plugin
  → Buzz message
```

只投影：

```text
needs-human
completed
failed
blocked
important review request
```

Buzz message 保留 `paperclip_issue_id` / URL/ref；不複製 canonical state。

---

## M2 — Real Workload Evaluation

至少跑 **20 個真實 intent**，不要 synthetic benchmark。

記錄：

```text
多少 intent 只需要 Buzz+Hermes
多少 materialize 成 Paperclip issue
多少需要 child tasks
多少需要 Pipeline
多少次 human intervention
多少次 shadow-state temptation
多少次因缺 formal verifier 出錯
多少次 Paperclip 模型真的表達不了需求
```

### 決策

若 formal gaps 很少：

```text
正式放棄 Nodalis kernel
Nodalis 只保留為 architecture name / conventions
```

若 N1–N5 之一有明顯 evidence：

```text
只實作對應的 thin governance module
```

不得因為 v0.9 已經寫了很多設計，就把它全部實作出來。

---

# 15. Minimal Custom Code Budget

v1.0 原則：**custom code 必須是 glue 或真正差異化，不重做 upstream。**

第一階段允許自己寫：

```text
1. Paperclip → Buzz notification bridge
2. deployment adapter / MCP（若 Coolify/Compose 沒現成）
3. small policy wrappers for production credentials/actions
4. observability exporter if needed
```

第一階段禁止自己寫：

```text
new task tracker
new chat
new Kanban
new project system
new agent runtime
new workflow engine
new durable runtime
new memory engine
```

---

# 16. Risk Register

## R1 — Paperclip 與 Hermes Kanban 再次產生雙 truth

**Mitigation**：integrated profiles 禁 Kanban toolset；CI/config check。

## R2 — Front-door Hermes 拿到過大的 Paperclip 權限

**Mitigation**：只用 `scope.kind = task_bridge`，限制到 parent/project；source 已提供此 security model。

## R3 — Buzz 與 Paperclip notification 同步失敗

**Mitigation**：Buzz 只是 projection；human 隨時可回 Paperclip 查 canonical state；bridge at-least-once + event id dedup 即可。

## R4 — Paperclip 太 company-simulation、OPC 用不到

**Mitigation**：不要求建立複雜虛擬 org；只用 agent registry + issue/project/pipeline/approval。若 20 個 workload 後發現 Paperclip 大多是負擔，切 Lean Mode（Buzz + Hermes Kanban）比維護 Nodalis 更容易。

## R5 — 沒有 formal verifier，agent 可能做出錯誤 work graph

**Mitigation**：先以 Paperclip approval / scoped keys / runtime tool approval / deployment permission 限制 side effects。若真實 failure 命中 N1，再做 Nodalis admission verifier。

## R6 — Upstream churn

**Mitigation**：三層都透過已存在的正式邊界組合：

```text
Buzz ↔ Hermes = ACP
Paperclip ↔ Hermes = adapter / gateway
Hermes → Paperclip = scoped REST task bridge
Paperclip → Buzz = 自有 thin projection
```

不要 fork 三個 core。

---

# 17. Decision Matrix

| 能力 | Buzz + Hermes | Buzz + Paperclip + Hermes | Nodalis v0.9 |
|---|---:|---:|---:|
| Conversation UX | **強** | **強** | 需自建/adapter |
| Hermes runtime integration | **原生** | **原生** | adapter |
| Heterogeneous workers | 中 | **強** | 強，但需實作 adapters |
| Agent-visible work board | **強** | **強** | 需自建 |
| Dynamic task decomposition | **強** | 強（child issues/tasks） | **形式化最強** |
| Stable pipeline/case | 弱/未完成 | **強** | 可表達但需全自建 |
| Business approval | 中 | **強** | **形式化強** |
| Runtime command safety | **強** | **強** | 依 runtime |
| Formal static verifier | 無 | 無 | **強** |
| Control-taint provenance | 無 | 無/弱 | **強** |
| Formal attention budget | 無 | 無 | **強** |
| Replayable custom graph | 無 | 依 Paperclip/runtime | **強** |
| Build cost | **低** | **低～中** | **極高** |
| Upstream leverage | **最高** | **最高** | 低 |
| 適合目前 OPC 驗證 | 強 | **最強** | 過早 |

---

# 18. Final Architecture

## Recommended Integrated Mode

```text
┌─────────────────────────────────────────────────────────────┐
│                         Buzz                                │
│  conversation / mobile / notifications / quick approvals   │
└──────────────────────────┬──────────────────────────────────┘
                           │ native ACP preset: hermes-acp
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  Front-door Hermes                          │
│ dialogue / clarify / triage / quick research               │
│ paperclip-task-bridge (SCOPED)                              │
│ Hermes Kanban: OFF                                         │
└──────────────────────────┬──────────────────────────────────┘
                           │ create/comment/update task
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                       Paperclip                             │
│              CANONICAL WORK CONTROL PLANE                  │
│                                                             │
│ Issue / Comment / Project / Pipeline / Case                 │
│ Approval / Heartbeat / Budget / Workspace / Run             │
└──────────────┬──────────────────────┬───────────────────────┘
               │                      │
               ▼                      ▼
┌────────────────────────┐   ┌───────────────────────────────┐
│ Hermes worker profiles │   │ Specialized agent runtimes    │
│ general / research     │   │ Codex / Claude / OpenCode... │
│ Kanban: OFF            │   │                               │
└────────────────────────┘   └───────────────────────────────┘

Paperclip significant events
        │
        ▼
thin Buzz notifier / plugin
        │
        ▼
Buzz thread / inbox
```

## Lean Mode（可選）

若最終證明 heterogeneous workforce / Paperclip process model 都用不到：

```text
Buzz → Hermes ACP → Hermes Kanban / Projects / Swarm
```

此時 **Paperclip 完全移除**，Hermes Kanban 才升為 canonical work plane。

禁止存在：

```text
Paperclip canonical + Hermes Kanban canonical
```

的混合模式。

---

# 19. Final Decision

### 現在做

```text
Buzz + Paperclip + Hermes
Paperclip = work truth
Hermes = runtime
Buzz = conversation
Nodalis kernel = freeze
```

### 現在不做

```text
重寫 dynamic workflow kernel
重寫 work tracker
重寫 runtime durability
重寫 conversation surface
把 Hermes Kanban 與 Paperclip 同時開成 durable work system
```

### 之後只有在有 evidence 時才做

```text
Nodalis thin governance kernel
```

它必須回答一個非常具體的問題：

> **「Paperclip + Hermes + Buzz 已經能做的事情之外，我們還缺哪個會直接改善安全、自治程度或 human attention 的不可替代能力？」**

若無法用真實 failure / workload 回答，就不寫。

---

# 20. Superseded v0.9 Decisions

以下 v0.9 決策在 v1.0 被 supersede：

```text
ADR-001 Greenfield Nodalis Kernel              → deferred / evidence-gated
ADR-002 Own Workflow Semantics                 → Paperclip-first for current implementation
ADR-004 Work Is Projection of Workflow         → Paperclip Issue/Case is current work truth
D1 ConversationPort                            → Buzz native Hermes ACP path first
M0 Restate kernel spike                        → replaced by compose spike
M1 custom human control surface                → Paperclip + Buzz existing surfaces
M3 custom WorkItem/lease/heartbeat              → use Paperclip; Hermes local liveness remains runtime-local
```

以下 v0.9 的 principles **沒有被否決**，只是尚不值得自建：

```text
Dynamic graph / static governance
single canonical truth
retry vs concurrency separation
logical operation identity
provenance / implicit flow
human attention economics
immutable/auditable execution history
```

這些變成 future governance requirements，而不是目前 implementation backlog。

---

# 21. Sources Inspected

本決策直接檢查：

```text
hermes-agent-main.zip        version 0.20.1
paperclip-master.zip
buzz-main.zip
nodalis-prd-v9.md
```

主要 code evidence：

```text
Hermes
- pyproject.toml
- hermes_cli/kanban_db.py
- hermes_cli/config_defaults.py
- hermes_cli/kanban_swarm.py
- hermes_cli/projects_db.py
- tools/kanban_tools.py

Paperclip
- packages/adapters/hermes/src/index.ts
- packages/adapters/hermes/skills/paperclip-task-bridge/SKILL.md
- packages/db/src/schema/pipelines.ts
- packages/db/src/schema/pipeline_cases.ts
- packages/db/src/schema/issues.ts
- packages/db/src/schema/heartbeat_runs.ts
- doc/SPEC.md

Buzz
- desktop/src-tauri/src/managed_agents/discovery/presets.rs
- crates/buzz-acp/README.md
- crates/buzz-acp/src/config.rs
- crates/buzz-workflow/src/schema.rs
- crates/buzz-core/src/kind.rs
```

---

# 22. One-sentence Architecture Rule

> **先讓 Buzz 負責「說話」、Paperclip 負責「工作」、Hermes/其他 runtime 負責「做事」；只有當三者無法安全治理「做什麼」時，才讓 Nodalis 回來負責「准不准這樣做」。**
