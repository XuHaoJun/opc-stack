# OPC Stack

Buzz(對話)+ Hermes(agent runtime)+ Paperclip(work 控制面)+ TencentDB-Agent-Memory(Knowledge Plane)的 docker compose 部署。Nodalis 為 evidence-gated governance,本 repo 不實作(架構決策見 `docs/nodalis-prd-v10.1.md`)。

## 服務

| 服務 | 說明 | port |
|---|---|---|
| `buzz` | Nostr relay(+ pg/redis/minio) | 3000 |
| `frontdoor` | buzz-acp → `hermes acp`(與 buzz 共用 netns) | — |
| `hermes` | gateway API server (dashboard 關閉) | 8642 |
| `hermes-dashboard` | web dashboard over the buzz front door's hermes home (sessions + live logs/thinking) | 9119 |
| `paperclip` | canonical work control plane | 3100 |
| `tencentdb-core` / `-hub` / `-proxy` | memory gateway / panel+knowledge / LLM proxy | 8420 / 8125+8424 / 8096 |

LLM 全棧使用 OpenCode Go(`https://opencode.ai/zen/go/v1`),`.env` 填 `OPENCODE_API_KEY` 一個 key 即可。Hermes 的記憶走官方 `memory_tencentdb` provider,直連 `tencentdb-core`。

## 快速開始

```bash
scripts/setup.sh              # 新機器一鍵: .env → submodule init → prepare → build → up
scripts/prepare.sh            # patches/ → upstream/ 同步(改 patch 後、build 前必跑)
docker compose up -d --build  # 啟動/重建
scripts/test-connectivity.sh  # 連通性測試(不碰 LLM)
docker compose logs -f <svc>  # 看日誌
```

改動一律改 `patches/<proj>/`,不直接改 `upstream/`(git submodule,乾淨 checkout)。

## 文件

- `AGENTS.md` — 架構、不變量、已知坑(改動前必讀)
- `SETUP.md` — 安裝、設定頁、agent wiring
- `docs/nodalis-prd-v10.1.md` — 架構決策(PRD v10 / v10.1)
- `docs/superpowers/` — 設計與實作計畫
