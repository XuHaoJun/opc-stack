# Devenv LLM Hard-Cap Lease — Deferred Design

日期: 2026-09-12
狀態: 延後；等待 LiteLLM strict budget reservation 進入 stable，並完成本文件的 fail-closed gate

## 決策摘要

Paperclip 執行的 prototype / engineering project 未來可透過 `devenv` 取得 project-scoped、
OpenAI-compatible LLM lease。Project 只拿 virtual key；provider master key 只存在於 gateway。

本次不實作，理由如下：

1. Bifrost `v2.1.1` 只在 request 前檢查目前 spend，provider response 回來後才記帳。單筆昂貴
   request 與 concurrent burst 都能穿越 budget，不符合 hard-cap admission control。
2. LiteLLM 比 Bifrost 更接近需求：它有 pre-request worst-case estimation、in-flight reservation、
   atomic counter 與 response 後 reconciliation。
3. 最新 stable `v1.100.1` 即使開啟 `fail_closed_budget_enforcement`，known estimate 放不進剩餘
   budget 時仍會把 reservation 縮成剩餘額度後放行，不符合 hard cap。
4. LiteLLM `v1.101.0-rc.2` 已可在 strict mode 對 known estimate 做 reject-before-provider，且能擋
   concurrent oversubscription；但這個行為尚未進 stable。
5. 即使是 RC strict mode，無法估價的 request 仍可能不做 reservation；actual cost 高於 estimate
   時也會把 settled counter 推過上限。OPC 因此仍需一個只允許可保守估價 request 的
   compatibility envelope。

這份文件保存架構決策、版本門檻與驗證 gate，不是第二套工作 backlog。是否排程與何時重啟由
Paperclip issue 負責；不新增根目錄 `ROADMAP.md`，避免與 Paperclip 的 canonical work plane 重疊。

## 問題與範圍

Agent 建立 AI 應用時可能需要 vision、text、embedding 等 LLM capability。目前若直接把 stack 的
provider credential 寫入 project `.env`，會產生三個問題：

- provider master key 到處複製，難以輪替與稽核；
- 一次性 project 可消耗整個 provider account 的額度；
- project 無法得到自己的 usage、budget 與 revoke boundary。

目標介面：

```bash
devenv provision receipt-demo --with llm
```

Project `.env` 預期得到：

```dotenv
LLM_BASE_URL=http://litellm-edge:4000/v1
LLM_API_KEY=sk-...
LLM_MODEL=<operator-approved-model-alias>
```

應用程式明確把 `LLM_BASE_URL` 與 `LLM_API_KEY` 傳給 OpenAI-compatible SDK。第一版不輸出
`OPENAI_API_KEY` / `OPENAI_BASE_URL`：Paperclip runtime 目前會繼承 stack 自己的同名變數，常見
`.env` loader 又不覆蓋既有 process env，使用標準名稱可能讓 app 靜默繞過 lease gateway。

## Hard cap 的定義

在 provider 不提供原生 hard limit 的前提下，本設計能主張的 hard cap 是：

> OPC 以保守 pricing 建立的 prepaid accounting cap；每個被允許的 request 必須先原子保留一筆
> 不小於 provider 最終費用的 worst-case credit，放不進剩餘 credit 就不得送往 provider。

它不是 provider invoice 的無條件數學保證。Provider pricing drift、未回報 usage、gateway 看不到的
部分失敗費用或 estimator bug 都可能使 provider 帳單與 OPC accounting 不同。為維持上述主張，
任何不能證明 `actual_cost <= reserved_cost` 的 model、route 或 modality 一律 fail closed。

## 已驗證的差異

研究 checkout：

```text
Bifrost repository: /tmp/bifrost
Bifrost commit:     3a6d7936bdde29af422b19f395005e2bb4bf6a79
Bifrost image:      maximhq/bifrost:v2.1.1

LiteLLM repository: /tmp/litellm
LiteLLM branch:     litellm_internal_staging
LiteLLM commit:     9071ca503e4d7e2dbda542ac3b68b15df015c762
LiteLLM images:     ghcr.io/berriai/litellm:v1.100.1
                    ghcr.io/berriai/litellm:v1.101.0-rc.2
```

### Bifrost

Bifrost 在 pre-request hook 比對目前 usage 與 budget；response 完成後才從 token usage 計算 cost 並
累加。即使 counter update 本身是原子的，admission 與 charge 仍是兩個分離步驟。因此 `$0.90 / $1`
時一筆 `$0.60` request 會先通過，再把 usage 推到 `$1.50`；同時進入的多筆 request 也看不到彼此
尚未結算的費用。

### LiteLLM stable 與 RC

以 production reservation function 做相同 probe：目前 spend `$0.90`、budget `$1.00`、下一筆
worst-case estimate `$0.60`。

|版本 / 模式|Known estimate|兩筆 concurrent `$0.60`|結果|
|---|---|---|---|
|`v1.100.1` default|接受，只 reserve 剩餘 `$0.10`|兩筆皆接受|仍可超額|
|`v1.100.1` strict|接受，只 reserve 剩餘 `$0.10`|兩筆皆接受|strict 尚未守住此路徑|
|`v1.101.0-rc.2` default|接受，只 reserve 剩餘 `$0.10`|可接受最後一筆 partial reservation|保留相容行為|
|`v1.101.0-rc.2` strict|provider call 前拒絕|一筆接受、一筆拒絕|known estimate 可 fail closed|

另外兩個 RC strict probe：

- estimator 回傳 `None`：request 不建立 reservation，退回 read-time enforcement；
- spend `$0.90`、estimate `$0.05`、actual `$0.20`：request 先通過，reconcile 後 counter 為 `$1.10`。

所以 LiteLLM 的 reservation 是較好的基礎，但只有在 estimator 是保守上界時才能形成 hard-cap
admission control。

## 為何選 LiteLLM 作為等待中的方向

相較 Bifrost，LiteLLM 已具備：

- pre-request input token counting；
- 依 `max_tokens` / model ceiling 估算 worst-case output cost；
- reasoning token 使用較高費率的保守 reservation；
- model group 多 deployment 時選較昂貴估價；
- key、team、user、organization 等 budget counter；
- 單 process per-counter lock；
- Redis atomic cross-worker counter；
- provider response 後把 reservation reconcile 成 actual cost；
- strict mode 下 reservation backend 不可驗證時回 503；
- `block_requests_for_models_without_pricing`；
- virtual key、model allowlist、RPM、TPM、`max_parallel_requests`、expiry 與 lifetime budget。

在 Bifrost 上補足這些能力等同自行建立整套 reservation subsystem；在 LiteLLM 上只需收緊尚未
fail closed 的邊界。

## 延後解除條件

只有以下條件全部成立，才能開始實作：

1. LiteLLM stable release 包含 PR #39214 的等價行為：strict mode 對放不進剩餘 budget 的 known
   estimate 在 provider call 前拒絕。
2. Pin 的必須是 stable tag + digest，不使用 RC、dev 或 floating tag。
3. `general_settings.fail_closed_budget_enforcement: true` 經 live gate 證明生效。
4. `litellm_settings.block_requests_for_models_without_pricing: true` 經 live gate 證明生效。
5. OPC edge 對 `reservation_cost is None`、`<= 0`、unsupported route 或 unsupported modality 一律拒絕，
   不得退回 read-time enforcement。
6. 每個 allowlisted model 都有 review 過的 custom pricing；reservation pricing 必須包含明確安全
   margin，且不得低於 provider 當前公開價格。
7. Edge 在 server side clamp output token 上限；不能只相信 caller 傳入的 `max_tokens`。
8. Vision profile 有 image count、image byte size、resolution 與 request body 上限。
9. 指定 vision model 的圖片 input token estimation 經 fixture 與 provider usage 回應交叉驗證，證明
   reservation 不低於 actual cost。
10. Single-worker 模式證明本地 lock 正確；若使用多 worker，必須改用專用 Valkey/Redis 並驗證
    cross-worker atomic admission。
11. Redis、Postgres、pricing lookup 任一不可用時，budgeted inference 都 fail closed，不得送 provider。
12. Streaming cancel、timeout、provider error、retry、fallback 與 background interaction 都有費用歸屬
    測試，且不存在 reservation leak 或未保留就送出的路徑。
13. Project runtime 不再意外繼承 stack 的 provider master key；否則 app 仍可直接繞過 LiteLLM。
14. Project runtime 的 provider-domain direct egress policy 已明確決定。若不阻擋 direct egress，本機制
    只能防止正常 app 誤用，不能作為 hostile-agent security boundary。

## 預定架構

```text
Paperclip project
  │ LLM_API_KEY (project virtual key)
  ▼
litellm-edge
  │ only approved OpenAI-compatible routes
  │ request shape clamp + fail-closed estimator gate
  ▼
LiteLLM
  │ provider master key only exists here
  ├── dedicated Postgres (virtual keys / settled spend / audit)
  ├── dedicated Valkey when multi-worker (in-flight atomic reservations)
  └── provider

`devenv` CLI
  │ provision / reconcile / release
  ▼
llm-lease-broker
  │ LiteLLM master credential only exists here
  ├── LiteLLM management API
  └── devenv control DB stores key hash/id/profile, never plaintext key
```

`litellm-edge` 與 `llm-lease-broker` 分開：data plane 不應能轉送 management routes；Paperclip agent
也不取得 `LITELLM_MASTER_KEY`。

LiteLLM 是 opt-in development resource 的 backend，不接管 Hermes、Buzz、Paperclip、TencentDB
目前使用的模型或 credential。Paperclip 啟動不得依賴 LiteLLM healthy；LiteLLM 故障只影響本次選擇
`--with llm` 的 lease 與使用該 lease 的 app。

## Lease 與 secret lifecycle

LiteLLM DB 保存 virtual key hash，建立後不能取回完整 secret。Broker 應沿用 devenv 的 deterministic
credential 模式：

```text
virtual_key = "sk-" + HMAC(DEVENV_SECRET_SALT, "llm:" + lease_key)
```

實作時使用合適的固定編碼與長度；上式只定義 derivation domain，不定義最終 wire encoding。

Provision：

1. 驗證 lease key 與 operator-owned profile；caller 不能提高 budget 或擴大 model allowlist。
2. 推導 virtual key，呼叫 LiteLLM `/key/generate` 或 reconcile 對應 hash row。
3. 設定 exact model alias、lifetime `max_budget`、RPM、TPM、`max_parallel_requests` 與 expiry policy。
4. LiteLLM 與 registry 都成功後才 merge `LLM_*` 到 project `.env`。
5. 任一步失敗不得留下宣稱可用的 `.env`；create response 遺失時以 deterministic hash reconcile。

Release：

1. 由 registry 取得 LiteLLM key identity，驗證與 deterministic lease key 相符。
2. LiteLLM key delete / revoke 成功後才清 registry provider state。
3. LiteLLM 不可用時保留 registry truth 供重試。
4. 不做自動 GC；`devenv release <key>` 維持唯一回收路徑。

## Operator-owned profile

第一版只提供固定 profile，不允許 agent 自訂任意 provider、model、budget 或 pricing。例如
`vision-receipt` 可固定：

- 一個經驗證的 vision chat model alias；
- exact provider deployment；
- lifetime project budget；
- 保守 custom pricing；
- output token clamp；
- image/request limits；
- RPM、TPM 與低 `max_parallel_requests`；
- `throttle_on_budget_exceeded: false`；
- 禁止 wildcard models 與 direct provider key passthrough。

只有 operator 可以變更 profile。Agent 可選 profile或要求較低額度，不能要求高於 profile ceiling 的值。

## 驗證矩陣

Stable release 出現後，至少需要以下 live proof；只讀 source 或跑 upstream unit tests不算完整 gate：

1. `$0.90 / $1.00` 時送 estimate `$0.60`：429，provider mock 收到 0 次。
2. 兩筆 concurrent `$0.60 / $1.00`：只允許一筆，provider mock 收到 1 次。
3. Estimator `None`：拒絕，provider mock 收到 0 次。
4. Model 沒有 pricing：拒絕，provider mock 收到 0 次。
5. Per-pixel、audio、video 等未批准 route：拒絕，provider mock 收到 0 次。
6. Actual-cost fixture 高於 estimate：測試必須失敗並停用該 profile，不能接受 counter 超額為正常結果。
7. Redis unavailable、DB unavailable、stale counter、counter TTL expiry：全部 fail closed。
8. Multi-worker 同時打相同 key：atomic admission 不超過 prepaid credit。
9. Streaming 完成、client cancel、gateway timeout、provider timeout、retry/fallback：reservation 最終狀態正確。
10. `devenv provision` 重跑、create response 遺失與中途 crash：只存在一把 logical key，回傳同一 credential。
11. `devenv release` backend 失敗：registry 保留；重試成功後 key 失效且 registry 清除。
12. Receipt fixture：圖片 token reservation 大於或等於 provider 回報 cost，並驗證 content logging policy。
13. Project app process 環境與 direct network path 都拿不到 stack provider master key。

## 非目標

- 不把現有 Hermes、Buzz、Paperclip 或 TencentDB 的 LLM traffic 遷移到 LiteLLM。
- 不讓 agent 建立任意 provider credential、model alias 或 budget profile。
- 不宣稱能在 provider 無原生 hard limit 時對最終 invoice 提供無條件保證。
- 不自動部署、對外開放或替 project 購買服務。
- 不在 stable gate 完成前加入 compose service、migration、CLI provider 或長期測試負擔。

## Work tracking

本文件是 Git repo 中的設計與證據 truth。真正承諾實作或等待 upstream 的 durable work，必須建立
Paperclip issue，並把 issue 標成 blocked/deferred，block reason 指向本文件的「延後解除條件」。
當符合條件的 stable tag 發布時，由該 issue 觸發重新 probe；不能因新版號看似較新就直接實作。

## 參考

- LiteLLM virtual keys: <https://docs.litellm.ai/docs/proxy/virtual_keys>
- LiteLLM budgets and rate limits: <https://docs.litellm.ai/docs/proxy/users>
- LiteLLM strict known-estimate fix: <https://github.com/BerriAI/litellm/pull/39214>
- LiteLLM reservation implementation (research revision):
  <https://github.com/BerriAI/litellm/blob/9071ca503e4d7e2dbda542ac3b68b15df015c762/litellm/proxy/spend_tracking/budget_reservation.py>
- LiteLLM production auth callsite (research revision):
  <https://github.com/BerriAI/litellm/blob/9071ca503e4d7e2dbda542ac3b68b15df015c762/litellm/proxy/auth/user_api_key_auth.py>
- Existing devenv design: `docs/superpowers/specs/2026-08-18-devenv-resource-provisioning-design.md`
