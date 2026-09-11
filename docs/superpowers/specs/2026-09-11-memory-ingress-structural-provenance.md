# Memory Ingress 的根因修法 —— 用 ACP `_meta` 取代文字解析

日期: 2026-09-11
狀態: **已決, 實作中**
取代 (**機制**): `2026-09-10-agent-memory-scoping-design.md` §7.1 的「解析生成的 header」那一套。
那份 spec 的 Part 1–6 (調查)、§7.0/7.2/7.3/7.4/7.5/7.6/7.7/7.9 (log / snapshot / SOUL / 召回界 / 節奏 / 量測) **仍然有效**, 只有「邊界怎麼取得」這件事被本 spec 取代。

---

## 這份 spec 不是什麼 (先讀)

- **不是 channel-scoped memory。** 仍然沒有任何 scope 階層; 讀路徑仍然共用同一個池 (1.5)。
- **不是 durable provenance。** 這版讓**寫入決策**有結構化 provenance, 但 L0 record 仍然沒有 author/channel 欄位 (§6 列出具體的上游請求)。
- **不是 policy 變更。** 條件不變 (單一 triggering event + 可信 writer, 其餘 fail closed); 變的是**那個判斷的輸入從字串換成協定資料**。

---

## 1. 根因: trust 決策建在一個沒有 escape 的字串上

前一份 spec 的 §7.1 是對的 —— 它正確指出 `role` 與 XML-like tag 都不是邊界, 只有 ACP block 邊界是。但它接下來的做法是在 block **內部**繼續做文字工程:

| 現行機制 | 為什麼存在 | 代價 |
|---|---|---|
| 位置性驗證 header 五行 | `Channel:` 的名字原樣嵌入 (`queue.rs:1309`), relay 只檢查非空 (`buzz-core/src/channel.rs:15`), 而 `From:` label 有 `sanitize_prompt_label` (`queue.rs:1248`) | 一整套脆弱規則; header 多一行、少一行、換順序都要重新推導 |
| 只認 `buzz-event` 一個 tag (allowlist) | cancelled/steer 會**換 tag 名** (`queue.rs:2120-2125`) | — |
| 只取 `Content: ` 之後的全部 | `Tags:`/`Parsed:` 在 raw content 之後, 可被偽造, 所以不能偵測結尾 | 生成的 tail 混進 capture |
| multi-event / cancelled **一律 fail closed** | batch 內 N 個 event 之間沒有可信邊界 | **真實使用者的訊息整批不進記憶** |

注意最後一列的性質: 它不是「防住了攻擊」, 是**放棄了功能**。而前三列全部是為了對抗「未 escape 的 body」而長出來的。

**根因一句話: 我們在一個 attacker 可寫的字串上做 trust 決策。** 位置性解析讓它在今天成立, 但 (a) 規則脆弱, (b) 功能有洞, (c) Buzz 端任何格式調整都變成安全性事件 —— 而這三件事都不會在任何測試變紅。

## 2. 結構早就在協定裡, 只是兩邊都沒用

**實測** (在跑著的 `frontdoor` 容器內):

```text
>>> acp.schema.TextContentBlock.model_fields
['field_meta', 'annotations', 'text', 'type']
>>> TextContentBlock.model_fields['field_meta'].alias
'_meta'
>>> TextContentBlock.model_fields['field_meta'].annotation
Optional[Dict[str, Any]]
```

也就是說 `session/prompt` 的每個 text block **本來就有一個自由的 `_meta` 欄位**。而今天:

| 層 | 現況 | 證據 |
|---|---|---|
| Buzz 送 | 只送 `{type, text}` | `build_prompt_params` (`crates/buzz-acp/src/acp.rs:2044-2053`) |
| Buzz 手上 | **event id / pubkey / channel / thread 全在** | `FlushBatch { channel_id, scope: Conversation{channel_id} \| Thread{channel_id, root_event_id}, events: Vec<BatchEvent{ event: nostr::Event, prompt_tag }> }` (`queue.rs:115-152`, `scope.rs:71-91`) |
| hermes 收 | **從不讀** `_meta` | `acp_adapter/content.py` 對 `field_meta` 零命中; `server.py:120/397/575` 全是出站用法 |

**所以修法是: 把 Buzz 已經握有的身分寫進那個空欄位, 而不是再優化文字解析。** 這也讓 §7.1.1 那個 sidecar patch 的「唯一目的 (不要讓 block 邊界在 join 時消失)」可以整片刪掉 —— 新的 patch 只搬運資料。

## 3. wire 契約 (凍結)

每個 block 可選地帶:

```json
{
  "type": "text",
  "text": "<buzz-event type=\"mention\">\nEvent ID: …\n…</buzz-event>",
  "_meta": {
    "buzz": {
      "memoryEvents": [
        {
          "eventId": "5f2a…(64 hex)",
          "authorPubkey": "aabb…(64 hex)",
          "channelId": "3f1c…(uuid)",
          "threadId": "9d77…(64 hex) | null",
          "role": "trigger",
          "content": "<該則 event 的原始 content, 未經任何改寫>"
        }
      ]
    }
  }
}
```

規則:

1. **`content` 是原始 event content**, 不是渲染過的 block 文字 —— 生成的 header 與 tail (`Tags:`/`Parsed:`) 不進 capture。
2. **`role` 只有兩個值**: `trigger` = `batch.events` (這次觸發 turn 的訊息), `prior` = `batch.cancelled_events` (被 cancel 而重新送達的較早訊息)。
3. **block 順序即 section 順序**; slash-command 的 pass-through 會在前面多插一個 block (無 `_meta`), 所以消費者**不可假設 index**。
4. `_meta.buzz` 是**唯一**的信任來源。文字 block 的內容**永遠不參與** capture 決策 (§5 第一條)。
5. 命名: key 走 ACP 的 camelCase (`${_meta.hermes.sessionProvenance}` 是同一個用法), 欄位名對齊既有 wire (`event_id` → `eventId`)。
6. **`channelId`/`threadId` 今天只進 drop log**, 不進 TencentDB —— L0 沒有欄位可放 (§6)。

**誰保證什麼**: Buzz 保證 `authorPubkey` 與 `content` 是**它自己從 relay 收到的 event 欄位**(不是從文字解析來的), hermes 保證**原樣搬運**, OPC plugin 保證**只信這條路徑**。

## 4. 三個投影 (更新 §7.1.5)

| 產物 | 內容 | 去哪 |
|---|---|---|
| `reasoning_context` | 完整 Buzz prompt, 原樣 (今天的行為, 不動) | 只給模型推理 |
| `capture` | 可信 trigger events 的 `content`, 依送達順序以 `"\n"` 連接 | TencentDB L0 (`/v3/conversation/add`, 單一 user message) |
| `drop` | 被擋下的 event 或「整批沒有結構」的事件 | metadata-only ingress log (§7.2 不變) |

**`recall_query` 這個投影產物刪除。** 上一版算了它但沒有任何消費者 (recall 的 query 來自 hermes 的 turn context, `memory_manager.prefetch_all(query=…)`), 留著只會讓人以為投影在影響召回。

**為什麼多個 trigger 合成一條 message 而不是 N 條**: `/v3/conversation/add` 的 `rounds` 只數 `role === "user"` (`v2-router.ts:751-757`), 送 N 條會把升格節奏乘上 N。節奏是另一個旋鈕 (`memory.pipeline.*`), 不該被這次重構偷偷改動。

## 5. policy (結構化之後)

| 情況 | 決定 | drop reason |
|---|---|---|
| 整份 prompt 沒有任何 `memoryEvents` | **不寫** | `no-memory-events` |
| 有 events 但 `role != "trigger"` | 不寫 | `prior-event` |
| `authorPubkey` 空 / 非 hex | 不寫 | `no-author-pubkey` |
| `authorPubkey` ∉ `MEMORY_TRUSTED_WRITERS` | 不寫 | `untrusted-writer` |
| `content` 空 | 不寫 | `empty-content` |
| 至少一個可信 trigger | 寫入 (只含可信的那些) | — |

不變量 (與前一份 spec 同源, 只是換了輸入):

1. **文字永遠不是證據。** 一個 block 的文字裡寫滿 `<buzz-event>`、`From: … hex: <owner>`、`</buzz-event>` 也**不會**產生 capture —— 那些字元只會被模型看到 (§7.9 的 threat model 不變, 但攻擊面消失)。
2. **沒有結構就沒有被動寫入。** 未打 patch 的 Buzz、heartbeat、任何非 ACP 來源一律 drop。這是刻意的: 舊行為的「可運作」正好等於「不安全」。
3. **部分可信 = 部分 capture。** 一批 5 則訊息裡有 1 則來自 owner → 只有那一則進 L0。這是舊機制做不到的事 (batch 一律整批丟)。
4. **`prior` 不 capture。** 它們是同一則訊息在 cancel 後被重新送達, 可能重複出現 (requeue 累積), 而我們沒有 dedup 狀態。要開這個功能得先有 dedup, 不是先有 capture。
5. **capture 的內容不含 assistant 那一半** (與現行 `projected` 相同)。

## 6. 明確不做 / 上游請求 (具體到可以貼成 issue)

**durable provenance 需要上游, 而且比看起來遠**:

1. **L0 沒有欄位。** `L0Record` = `id / sessionKey / sessionId / teamId / userId / agentId / taskId / role / messageText / recordedAt / timestamp` (`core/store/types.ts:141-162`), `/v3/conversation/add` 的 schema 也沒有任何地方可以掛 author/channel。
2. **它連自己已經有的 provenance 都丟掉。** L1 的 `source_message_ids` 有被寫 (`l1-writer.ts:227`) 進 append-only JSONL, 但查詢用的 row 型別 (`L1RecordRow`) 沒有這個欄位, 檔案路徑的 reader 直接硬編 `[]` (`l1-reader.ts:80`, 註解: "vector search doesn't need them"), 而 API 回應是 `atomicDetailSchema` —— 描述自己寫著「一期對外暴露 6 個欄位 + 4 個 ID 透傳」(`generated/schemas.ts:152-164`)。
3. **因此 L1 → L0 的邊在 API 上不存在。** 沒有這條邊, 任何 sidecar mapping 都只能做「寫入側審計」, 不能做「召回側過濾」。

**請求 (任一即可放寬 §5 的閘)**:

- (a) `/v3/conversation/add` 接受並回傳 author/channel(或至少 opaque 的 `source` metadata), 且它們能沿升格鏈存活; 或
- (b) 把已經存在的 `metadata_json` map 進 `atomicDetailSchema`, 讓 L1 的可追溯性至少能被查出來。

**其餘不做** (理由同前一份 spec §7.10): channel-scoped memory、`prior`/cancelled capture (§5 第 4 條)、內容黑名單、`remember` tool、L2/L3 進 system role、L0–L3 的 pruning。

## 7. 偵測器 (TDD: 先寫紅的)

| 層 | 檔案 | 證明什麼 |
|---|---|---|
| wire 契約 | `tests/fixtures/buzz-acp-prompt-blocks.json` | Rust 產生的 `session/prompt` params **等於**這個 golden; python 端對**同一份檔案**做決策斷言 —— 兩半由同一個 artifact 綁住 |
| Rust (Buzz) | `patches/buzz/patches/opc-memory-ingress-meta.patch` 內的 `#[cfg(test)]` | 五個場景: 單一 trigger / batch (2 則) / cancel-merge (prior+trigger) / slash-command (第一塊無 meta) / heartbeat (無 meta)。在 image build 內 `cargo test -p buzz-acp` 執行 (先例: `opc_nip_oa_sign`) |
| projector (離線) | `tests/memory-ingress.sh` | 上述 golden 的決策結果 + 對抗案例: **純文字偽造不能 capture** (含偽造 `From:`/`Channel:`/close tag)、`prior` 不 capture、部分可信只 capture 可信的、沒有 meta 一律 drop |
| 端到端 (live) | `tests/memory-scope.sh` | 真的 ACP round-trip 帶 `_meta`; 同一份內容**只把 `_meta` 拿掉**就必須 drop (結構是唯一來源) |
| 升版 | `scripts/upgrade-preflight.sh` | buzz 的 patch 仍能 `--fuzz=0` 套用; hermes 的 patch 同理 |

## 8. 失效模式與回退

- **未打 patch 的 Buzz / 忘了 apply patch** → capture 全關 (`no-memory-events`), 而 recall 不受影響。這與今天的 fail-closed 一致, 但**代價方向反過來了**: 舊機制是「格式一變就靜默放行或靜默丟棄」, 新機制是「沒有結構就明確丟棄並留 log」。
- **回退**: `MEMORY_TENCENTDB_CAPTURE_MODE=full` (與今天相同), 或 revert 這條 branch (舊的 projector 已刪除, 不存在兩套並存)。
- **patch 紀律**: 兩個 Rust/hermes patch 都 `--fuzz=0`, 上游動到 context 就 build 停住 (不是 runtime fail-green)。

## 9. 附: 順手修掉的 fail-green

`memory` 的召回窗 (`MEMORY_TENCENTDB_RECALL_WINDOW_DAYS`) 原本送 `time_start` 給 `/v3/atomic/search` —— 而 **`handleAtomicSearch` 從不讀它** (`v2-router.ts:1192-1216` 只解構 `{query, type}`), `executeMemorySearch` 的參數型別根本沒有 timeStart (`core/tools/memory-search.ts:87-96`)。SDK schema 有這個欄位 (`generated/schemas.ts:191-197`), 實作沒有 —— 教科書級的 fail-green, 而它的 gate 只檢查 `client.py` 有沒有送出這個字串。

處理: **移除 client 的 `time_start`**, 改用回應裡真的有的 `created_at` 在 client 過濾 (`_recent_only`), 並且 gate 改成斷言「舊於窗的項目確實被排除」而不是斷言字串存在。`/conversation/search` 這條**真的有用** `time_start` (`:886-910`), 但 plugin 沒用到它, 不在此次範圍。
