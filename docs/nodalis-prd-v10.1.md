# Nodalis / OPC Agent OS — v1.0.1 Architecture Reset + Knowledge Plane

- **版本**：v1.0.1（v10.1）
- **日期**：2026-08-16
- **前一版**：`nodalis-prd-v10.md` / v1.0
- **狀態**：Architecture reset retained / Knowledge Plane added
- **核心決策**：**完整保留 v10 的 adopt-first 架構與 Buzz / Paperclip / Hermes / Nodalis authority 分工；新增 TencentDB Agent Memory 作為正式的 OPC Knowledge Plane，負責跨 agent、跨 task、跨 session 的 Chat Memory / Skill / Wiki / CodeGraph。它不接管 Paperclip work truth、不接管 Git/docs source truth，也不得直接作為 authorization / production policy truth。**

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

> **「現成元件已經能覆蓋多少 OPC operating model？只有哪些能力值得自己擁有？」**

v10.1 保留 v10 的答案，並補上一個 v10 漏掉的正交問題：

> **「work 有 Paperclip、execution 有 Hermes、conversation 有 Buzz；那整個 OPC 跨 agent 長期累積的 shared knowledge 放哪裡？」**

答案是：**TencentDB Agent Memory 作為 Knowledge Plane。**

## v1.0.1 決策

### Decision A — 停止目前 v0.9 greenfield kernel 的主線實作

不刪除 repo、不丟棄 v0.9 的研究成果，但將其視為：

```text
reference architecture
+ formal-governance research backlog
+ future thin-kernel design source
```

**不再把 Workflow IR / Restate interpreter / verifier / custom WorkItem / custom attention ledger 當成目前第一個要交付的產品。**

### Decision B — 第一個真實 OPC stack 使用四個 operational planes

v10 的三層組合完整保留，v10.1 只新增 Knowledge Plane；TencentDB **不是插在 Buzz → Hermes → Paperclip 的控制鏈中間**，而是 execution 的 shared knowledge side plane：

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
          │ Front-door Hermes    │◄──────────────┐
          │ intent / dialogue /  │ recall/capture│
          │ research / triage    │               │
          └─────────┬────────────┘               │
                    │ scoped paperclip-task-bridge│
                    ▼                            │
          ┌──────────────────────┐               │
          │      Paperclip       │               │
          │ CANONICAL WORK PLANE │               │
          │ issue / pipeline /   │               │
          │ case / approval /    │               │
          │ heartbeat / budget   │               │
          └──────┬─────┬─────────┘               │
                 │     │                         │
        ┌────────┘     └──────────────┐          │
        ▼                             ▼          │
   Hermes workers               Coding workers  │
   research/general        Codex / Claude / ...  │
        │                             │          │
        └────── learn / recall ───────┴──────────┤
                                                ▼
                                  ┌────────────────────────┐
                                  │ TencentDB Agent Memory │
                                  │ CANONICAL KNOWLEDGE    │
                                  │ Chat Memory / Skill    │
                                  │ Wiki / CodeGraph       │
                                  └────────────────────────┘
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

### Decision F — TencentDB Agent Memory 是正式 Knowledge Plane，但不是 source-of-truth replacement

v10.1 新增：

```text
TencentDB Agent Memory
- Chat Memory
- Skill
- Wiki
- CodeGraph
- Team / Agent asset scope
- Agent Loadout / visibility / ACL
```

它回答：

> **「整個 OPC 已經知道什麼、學會什麼、有哪些 reusable knowledge / SOP / code relationship 可供下一個 agent 使用？」**

但 authority 必須嚴格分開：

```text
Paperclip = work truth
Git/docs/source systems = factual/source truth
TencentDB Agent Memory = learned / derived knowledge truth
Hermes = execution
Buzz = conversation
Nodalis (future) = governance
```

硬規則：

1. TencentDB 的 `task_id` 只作 correlation，可引用 Paperclip Issue/Case ID；**不得成為第二套 task state**。
2. Wiki / CodeGraph 是 source material 的 derived knowledge representation；原 repo / 文件仍是 factual source of truth。
3. Memory recall 可以影響 reasoning；**不得直接決定 capability、credential、production approval、payment、destructive action 或 bounded external authorization**。
4. Chat Memory / Skill 從 private → team promotion 必須是顯式 lifecycle；**不把每段 conversation / 每個成功 task 自動升格成 OPC-wide knowledge**。
5. 第一階段 Hermes 使用官方 `memory_tencentdb` integration；其他 runtimes 不因架構圖存在就強制全部走 Memory Proxy。

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


## 1.1 為什麼 v10.1 不是 v11

v10.1 **不改變 v10 的 architecture authority reset**：

```text
Buzz owns conversation
Paperclip owns durable work
Hermes / other runtimes own execution
Nodalis remains evidence-gated governance
```

只補上 v10 漏掉的第五個 concern：

```text
TencentDB Agent Memory owns shared reusable knowledge assets
```

因此這是 minor architecture correction，而不是再次翻轉 core authority。

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

## 2.7 TencentDB Agent Memory 已具備獨立 Knowledge Plane 所需的 upstream surface

本節為 v10.1 新查證；來源是 TencentDB Agent Memory 官方 repository / changelog，不是本專案推測。

官方目前把系統定位為 **team-level memory hub**，並把四類內容統一成 reusable memory assets：

```text
Chat Memory
Skill
Wiki
CodeGraph
```

官方 changelog 對四類資產的描述包含：

- Chat Memory：跨 session 的 layered memory；
- Skill：從成功任務提煉 reusable SOP，帶版本、資源、觸發邊界、步驟與驗證；
- Wiki：把文件整理成 structured pages + links；
- CodeGraph：索引 repository 的 files / symbols / calls / impact paths。

Memory Hub 另有：

```text
Team / Agent
Owner / version / status
private / team / restricted / agent visibility
Agent Loadout
Wiki / CodeGraph build workflow
```

因此它不是單純「vector DB wrapper」，足以承擔 OPC Knowledge Plane。

### Hermes integration 不是 future speculation

官方 README 已提供 existing Hermes 的直接安裝方式：

```yaml
memory:
  provider: memory_tencentdb
```

Hermes plugin 透過 Memory Gateway 做 capture / recall / search；因此 Buzz 目前已接通的 Hermes 可以先直接成為第一個 Knowledge Plane consumer，不需要 Nodalis 中介。

### Memory Proxy 先視為 optional expansion

官方也已有 Memory Proxy / SDK，可讓其他 agent/runtime 取得 team memory；但 v10.1 **不因此要求 Codex / Claude / 所有 future agent 全部立即統一接入**。原因：

```text
Hermes native integration 已存在 → 低風險先驗證
其他 runtime → 依真實 workload 再選 MCP / SDK / Proxy
```

這維持 v10 的 adopt-first 原則，而不是因為 upstream 功能存在就一次導入全部 surface。

### Maturity note

目前官方公開線仍在 2.0 beta 系列，且 issue tracker 有 memory extraction / replay / integration robustness 類問題。因此 Knowledge Plane 必須可降級：

```text
memory unavailable / recall wrong
→ agent reasoning degraded
→ Paperclip work state 不壞
→ execution truth 不壞
→ production authorization 不被 memory 接管
```

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

## 3.4 Knowledge Plane decision — TencentDB is additive, not a fourth work orchestrator

三個候選架構原本是在比較 **work/control topology**，因此 v10.1 不新增「Buzz + TencentDB」之類的第四種 competing orchestrator option。

TencentDB 是正交 side plane：

```text
Integrated Mode:
Buzz + Paperclip + Hermes/other runtimes
                  ↕
          TencentDB Agent Memory

Lean Mode:
Buzz + Hermes Kanban
        ↕
TencentDB Agent Memory
```

也就是：**不論最後選 Paperclip Integrated Mode 或 Hermes Lean Mode，Knowledge Plane 都可存在；它不決定 work authority。**

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
| Agent-local transient session / scratch context | **runtime 自己** | Paperclip / TencentDB 不複製每個 runtime internal state |
| Shared long-term Chat Memory | **TencentDB Agent Memory** | runtime consume / capture；Paperclip 只提供 task correlation |
| Reusable Skill asset | **TencentDB Agent Memory**（knowledge asset） | runtime 執行 skill；source repo 可保留 skill source/export |
| Derived Wiki / CodeGraph | **TencentDB Agent Memory**（knowledge representation） | 原始 docs / Git repo 仍是 factual source truth |
| Knowledge visibility / loadout | **TencentDB Memory Hub** | Team / Agent / ACL 只控制 knowledge access，不等於 Paperclip RBAC/work assignment |
| Runtime dangerous-command approval | **Hermes runtime approval** | 只管 tool safety |
| Business / work approval | **Paperclip approval / review** | Buzz 可投影 UI，不作 canonical decision |
| Conversation notification | **Buzz projection** | source event 仍來自 Paperclip |
| Git / artifact | repo / artifact backend | issue / memory 只保存 refs 或 derived representation |
| Production authorization / credentials | **Paperclip approval + runtime/deployment policy；future Nodalis if needed** | TencentDB memory 永遠不是 authorization truth |
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

Knowledge Plane 也受同一個 anti-shadow 原則，但方向相反：

```text
TencentDB task/team metadata       = correlation / knowledge scope
Paperclip issue/project/pipeline   = work authority
```

禁止：

```text
Memory task status → 驅動 Paperclip work state
Memory recalled approval → 當成 production permission
Memory Skill 自己建立另一套 durable scheduler
```

允許：

```text
Paperclip issue id → memory.task_id / source_ref
Paperclip completed artifact → knowledge extraction candidate
Memory recall → 提供 agent reasoning context
```

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

# 9A. TencentDB Agent Memory — OPC Knowledge Plane

這是 v10.1 唯一新增的 architecture plane。

## 9A.1 它解決的問題

v10 已回答：

```text
Buzz       → human 在哪裡說話？
Paperclip  → durable work 在哪裡？
Hermes     → agent 怎麼做事？
Nodalis    → 若治理不足，誰補 formal governance？
```

但沒有回答：

```text
跨 session 的經驗在哪裡？
不同 agent 如何共享已學到的知識？
成功 SOP 如何變成 reusable skill？
大量 docs / code 如何按需提供給 agents，而不是每次重新研究？
```

TencentDB Agent Memory 承擔這個 concern。

## 9A.2 四種資產的 OPC mapping

| TencentDB asset | OPC 用途 | 不應成為 |
|---|---|---|
| **Chat Memory** | 長期偏好、已知背景、過去 interaction/decision context | Paperclip execution log replacement |
| **Skill** | 可重用 SOP / procedure / agent capability packaging | 未審核一次成功就自動成為公司政策 |
| **Wiki** | PRD、architecture、domain knowledge 的 agent-readable derived representation | 原始文件 source of truth |
| **CodeGraph** | repo symbol/call/impact navigation，支援 code reasoning | Git repository replacement |

## 9A.3 Source truth 與 Knowledge truth 分離

必須區分：

```text
Git repository        = code truth
PRD/docs/source files = document truth
Buzz                   = conversation truth
Paperclip              = work/execution coordination truth
TencentDB              = reusable learned/derived knowledge truth
```

例如：

```text
Git: nodalis-prd-v11.md
         │ build/index
         ▼
TencentDB Wiki: Nodalis architecture pages
```

若兩者不一致，**回原始 source 判斷 freshness**；不可因 memory/wiki recall 比較方便就反轉 authority。

Knowledge asset 應盡量保存：

```text
source_ref
source_version / commit hash（能取得時）
created_at / refreshed_at
owner
visibility
```

如果 upstream schema 暫時無法完整表達，先以 metadata / naming convention 保存；不要為了補欄位 fork Memory Core。

## 9A.4 Hermes integration — 第一階段直接使用 upstream provider

既有 Buzz → Hermes path 已成立，所以第一個 integration 直接是：

```text
Buzz
 ↓
Hermes (opc-front-door)
 ↕ memory_tencentdb
TencentDB Memory Gateway / Hub
```

官方 existing-Hermes path 使用：

```yaml
memory:
  provider: memory_tencentdb
```

第一階段只要求：

```text
capture works
recall works
active search works
memory outage does not break Hermes execution
```

不 fork Hermes memory system；不經 Nodalis proxy。

## 9A.5 Agent identity / loadout mapping

TencentDB 的 Team / Agent 是 **knowledge scope identity**，不是 Paperclip organizational authority。

建議：

```text
TencentDB Team: opc

Agent loadouts:
- hermes-front-door
- hermes-research
- hermes-reviewer
- coding-agent-*（只有真的接入 memory 時建立）
```

例：

```text
hermes-front-door
  Chat Memory: personal/opc context
  Wiki: OPC architecture / product knowledge
  Skill: triage / create-paperclip-work

hermes-reviewer
  Wiki: architecture/security
  CodeGraph: target project
  Skill: adversarial-review
```

**Role/Seat 不必一個對應一個永久 Memory Agent。** 只有需要不同 ACL / loadout / isolation 時才拆 identity。

## 9A.6 Paperclip integration — 先做 correlation，後做 crystallization

### Phase K1 — Correlation only

Paperclip work 進入 Hermes 時，把 canonical identifiers 帶進 memory context：

```text
team_id  = opc
agent_id = hermes-...
task_id  = Paperclip issue/case id
```

`task_id` 的意義只有：

> 「這份 memory 是在哪個 canonical work context 產生的？」

不得讓 TencentDB 自己維護：

```text
queued / running / blocked / done
assignee
pipeline stage
approval state
```

### Phase K2 — Completed work → knowledge candidate

不是同步整個 issue DB，而是在 work 結束後提煉：

```text
Paperclip completed work
       │
       ├─ important decision / explanation → Wiki candidate
       ├─ repeatable successful procedure  → Skill candidate
       ├─ durable context / lesson         → Chat/Scenario Memory
       └─ code source                      → CodeGraph refresh trigger/ref
```

這是 knowledge crystallization，不是 data replication。

## 9A.7 Promotion policy — capture freely, share deliberately

OPC 只有少量 humans，也不能讓 team knowledge 無限制污染。

預設 lifecycle：

```text
runtime capture
   ↓
private / task-scoped memory
   ↓
extract candidate
   ↓
review / confidence / source check
   ↓
promote to team asset
```

尤其 Skill：

```text
一次跑成功
≠ OPC SOP
```

第一階段 team Skill promotion 需要 human 或明確 trusted-review workflow；未來有足夠 evidence 才自動化。

## 9A.8 Retrieval rule — memory is advisory context, not policy input

允許：

```text
research context
past architecture rationale
known user preference
related SOP
code impact hint
past failure lesson
```

禁止直接使用 recalled memory 作：

```text
capability grant
credential selection
production target authorization
payment/refund authorization
external recipient authorization
legal/financial commitment approval
```

若 memory 提到：

```text
「上次 human 說 production 可以自動 deploy」
```

它只是一段 context；真正 permission 必須回 canonical policy / Paperclip approval / deployment backend / future Nodalis governance 查驗。

## 9A.9 Memory Proxy / other runtimes — 延後全面鋪設

TencentDB 已提供讓其他 agent/runtime 接入 shared memory 的 Proxy / SDK 能力，但 v10.1 的 default rollout 是：

```text
K0: Hermes native provider
K1: Paperclip task correlation
K2: Wiki / Skill / CodeGraph asset curation
K3: 有真實需求才接 Codex / Claude / other runtime
```

不要第一天就：

```text
所有 LLM traffic → Memory Proxy
所有 agent 自動 capture
所有 asset 全 team visible
```

否則還沒知道 retrieval quality，就先把所有 runtime 與 failure domain 綁到同一 service。

## 9A.10 Failure / degradation semantics

TencentDB 不可用：

```text
Paperclip work state       不受影響
Hermes execution           繼續（memory degraded）
Buzz conversation          繼續
Git/docs source            仍可直接讀
production authorization   不受影響
```

錯誤 recall：

```text
agent 可重新查 source
source ref 優先
不可把 recall 當 authorization
```

因此 Knowledge Plane 是重要的 productivity / continuity plane，**不是 execution availability hard dependency**。

## 9A.11 Maturity / portability

TencentDB Agent Memory 目前仍在快速迭代。採用原則：

```text
use upstream integration
keep canonical sources external
export/backup knowledge assets when practical
avoid custom schema fork
avoid making execution correctness depend on memory internals
```

若未來更換 memory backend，最重要能帶走的不是 embedding index，而是：

```text
source-linked Wiki
Skill source/version/resources
Chat Memory export
CodeGraph rebuild source refs
Team/Agent loadout conventions
```

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
custom generic memory / knowledge engine
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

## 11.6 Experience compounds — now delegated to a real Knowledge Plane

v0.9 的 Experience / Memory 思路沒有消失；v10.1 將其 implementation authority 交給 TencentDB Agent Memory：

```text
conversation/task experience
→ private memory / candidate
→ reviewed Wiki / Skill / CodeGraph asset
→ future agents recall/reuse
```

Nodalis 不重做 MemoryPort backend / workflow memory engine；若未來需要 formal crystallization policy，只在 **promotion/admission boundary** 補 governance，而不是重寫 storage/retrieval system。

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
7. 部署 TencentDB Agent Memory（至少 Memory Core/Gateway；需要資產管理時啟 Memory Hub）。
8. 將 `opc-front-door` Hermes 掛 `memory_tencentdb` provider；先不要求所有 worker/runtime 接入。
9. 建立最小 `opc` Team / Agent loadout，測：
   - session A capture → session B recall；
   - memory service 停止時 Hermes 仍可做無 memory 的 work；
   - recalled content 不可被當成 Paperclip approval / production permission。

### Exit

```text
沒有第二套 work truth
Hermes/Codex 都能被 Paperclip 正確 dispatch
comment/status/review 能完整回寫
human 可以看到 agent 正在做什麼
Hermes 能跨 session recall 已捕捉的 OPC context
Memory outage 不會破壞 Paperclip work/execution truth
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

### Knowledge Plane — 第一階段 curation

M1 同時建立少量、可人工檢查的 OPC knowledge assets：

```text
1 個 OPC architecture Wiki
1 個 active project Wiki / source set
1 個 CodeGraph（若目前 project 適合）
2–5 個人工接受的 Skills
```

只驗證：

```text
不同 Hermes profile 是否能依 loadout 取得不同 knowledge
來源是否可回溯
knowledge 是否真的減少重複 research/context reconstruction
```

不要以「memory 數量」作成功指標。

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
多少次 memory recall 真正避免重複 research/context reconstruction
多少次 recall 錯誤/過期而需要回 source 修正
多少個 completed work 值得升成 Wiki / Skill candidate
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

Knowledge Plane 的去留則獨立判斷：若 TencentDB 帶來明顯 continuity/reuse 價值就保留；若 integration burden 高於收益，可以替換 backend，**但不把 knowledge concern 再塞回 Paperclip 或 Nodalis work engine。**

---

# 15. Minimal Custom Code Budget

v1.0 原則：**custom code 必須是 glue 或真正差異化，不重做 upstream。**

第一階段允許自己寫：

```text
1. Paperclip → Buzz notification bridge
2. deployment adapter / MCP（若 Coolify/Compose 沒現成）
3. small policy wrappers for production credentials/actions
4. observability exporter if needed
5. Paperclip completed-work → TencentDB knowledge-candidate thin bridge（只有真實需求時）
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

## R7 — Knowledge pollution / stale memory

**Mitigation**：private/task-scoped capture first；team promotion explicit；Wiki/Skill 保存 source refs/version；重要決策回 source 驗證。

## R8 — TencentDB metadata 被誤當第二套 work model

**Mitigation**：Team/Agent/Task 只作 knowledge scope/correlation；Paperclip 是唯一 work status/assignment/pipeline authority。

## R9 — Memory recall 被誤當 authorization

**Mitigation**：architecture hard rule：memory advisory only；production/payment/credential/external-contact authorization 必須查 canonical policy / approval source。

## R10 — Memory service maturity / outage 擴大 failure domain

**Mitigation**：Hermes memory integration 必須可 fail-open to **no-memory execution**（不是 fail-open governance）；Paperclip/work truth 不依賴 memory；其他 runtime integration 分階段導入。

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
| Shared team knowledge plane | **強（+ TencentDB）** | **強（+ TencentDB）** | v0.9 MemoryPort 尚需實作 |
| Wiki / Skill / CodeGraph assets | **TencentDB** | **TencentDB** | 需自建/adapter |
| Knowledge/work authority separation | 可 | **最清楚** | 可，但需全自建 |
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
│                  Front-door Hermes                          │◄────────────┐
│ dialogue / clarify / triage / quick research               │             │
│ paperclip-task-bridge (SCOPED)                              │             │
│ Hermes Kanban: OFF                                         │             │
└──────────────────────────┬──────────────────────────────────┘             │
                           │ create/comment/update task                    │
                           ▼                                               │
┌─────────────────────────────────────────────────────────────┐             │
│                       Paperclip                             │             │
│              CANONICAL WORK CONTROL PLANE                  │             │
│                                                             │             │
│ Issue / Comment / Project / Pipeline / Case                 │             │
│ Approval / Heartbeat / Budget / Workspace / Run             │             │
└──────────────┬──────────────────────┬───────────────────────┘             │
               │                      │                                     │
               ▼                      ▼                                     │
┌────────────────────────┐   ┌───────────────────────────────┐              │
│ Hermes worker profiles │   │ Specialized agent runtimes    │              │
│ general / research     │   │ Codex / Claude / OpenCode... │              │
│ Kanban: OFF            │   │                               │              │
└────────────┬───────────┘   └──────────────┬────────────────┘              │
             │ learn/recall                 │ optional future integration    │
             └───────────────┬──────────────┘                               │
                             ▼                                              │
              ┌─────────────────────────────────────┐                       │
              │       TencentDB Agent Memory        │───────────────────────┘
              │   CANONICAL KNOWLEDGE PLANE         │   recall/capture
              │ Chat Memory / Skill / Wiki/CodeGraph│
              │ Team / Agent Loadout / ACL           │
              └─────────────────────────────────────┘

Paperclip significant events
        │
        ▼
thin Buzz notifier / plugin
        │
        ▼
Buzz thread / inbox
```

Authority reminder：

```text
Buzz      = conversation truth
Paperclip = work truth
Hermes    = execution
TencentDB = shared learned/derived knowledge
Git/docs  = factual/source truth
Nodalis   = future governance only if evidence demands it
```

## Lean Mode（可選）

若最終證明 heterogeneous workforce / Paperclip process model 都用不到：

```text
Buzz → Hermes ACP → Hermes Kanban / Projects / Swarm
                   ↕
           TencentDB Agent Memory
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
Buzz + Paperclip + Hermes + TencentDB Agent Memory
Paperclip = work truth
Hermes = runtime
Buzz = conversation
TencentDB = knowledge truth (not source/work/policy truth)
Nodalis kernel = freeze
```

### 現在不做

```text
重寫 dynamic workflow kernel
重寫 work tracker
重寫 runtime durability
重寫 conversation surface
把 Hermes Kanban 與 Paperclip 同時開成 durable work system
自己重做 generic memory / wiki / skill / codegraph engine
把 TencentDB memory 當成 Paperclip task state 或 production authorization source
第一天就強迫所有 runtimes 經 Memory Proxy
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
D2 Memory Backend Deferred                       → superseded: TencentDB Agent Memory is v10.1 default Knowledge Plane, but execution remains independent
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
nodalis-prd-v10.md
TencentDB-Agent-Memory official main README / CHANGELOG / releases (web verification, 2026-08-16)
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

TencentDB Agent Memory (official upstream, verified 2026-08-16)
- https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/main/README.md
- https://github.com/TencentCloud/TencentDB-Agent-Memory/blob/feat/server_team/CHANGELOG.md
- https://github.com/TencentCloud/TencentDB-Agent-Memory/releases
```

---

# 22. One-sentence Architecture Rule

> **先讓 Buzz 負責「說話」、Paperclip 負責「工作」、Hermes/其他 runtime 負責「做事」；讓 TencentDB Agent Memory 負責「整個 OPC 已經知道與學會什麼」；只有當這些現成元件無法安全治理「准不准這樣做」時，才讓 Nodalis 回來做 thin governance。**


---

# 23. v10 → v10.1 Changelog / Preservation Check

## 新增

- TencentDB Agent Memory 升格為正式 **Knowledge Plane**。
- 四類 knowledge assets：Chat Memory / Skill / Wiki / CodeGraph。
- Knowledge authority 與 source/work/policy authority 的硬邊界。
- Hermes `memory_tencentdb` 為第一個預設 integration path。
- Paperclip → memory correlation / completed-work crystallization 的分階段策略。
- private → team knowledge promotion policy。
- memory outage / stale recall / authorization misuse / metadata-shadow-state 風險與 mitigation。
- M0/M1/M2 加入 memory smoke、curation、reuse-quality metrics。

## v10 既有核心決策全部保留

以下 **沒有被 v10.1 推翻**：

```text
1. v0.9 greenfield Nodalis kernel 仍 freeze。
2. Integrated Mode 仍以 Paperclip 為唯一 canonical work plane。
3. Hermes Kanban 在 Integrated Mode 仍 OFF；Lean Mode 才可 canonical。
4. Buzz 仍只作 conversation / intent / notification surface。
5. Paperclip ↔ Hermes upstream adapter / scoped task bridge 仍是主要 integration path。
6. Dynamic workflow 仍先用 Pipeline + Issue/Case graph 表達，不先做 typed IR/verifier。
7. Approval semantics 仍區分 Hermes runtime / Paperclip business / Buzz UX。
8. Nodalis 仍只有在 N1–N5 真實 governance trigger 命中時才復活。
9. Minimal Custom Code 原則仍成立：glue or true differentiation only。
10. v0.9 的 single authority / retry-vs-concurrency / provenance / attention 原則仍保留。
```

## v10.1 新的 hard boundary

```text
TencentDB Agent Memory
  可以影響 reasoning / recall / reuse
  不可以取代 work truth
  不可以取代 source truth
  不可以取代 authorization truth
```

如果未來這三條被打破，視為 architecture regression，而不是 integration convenience。
