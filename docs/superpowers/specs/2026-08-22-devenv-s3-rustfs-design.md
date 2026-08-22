# Devenv S3 Object Storage (RustFS) — Design Spec

日期: 2026-08-22
狀態: 設計已批准，待實作

## 背景

`devenv` 已用共用 PostgreSQL、Valkey 與 HTTP port pool 提供按 lease 隔離的開發資源。Agent 可只申請需要的 provider，例如 `--with postgres`；應用程式只讀 workspace `.env`，不知道 devenv 存在。

Prototype 與 engineering 工作也需要 S3-compatible object storage。把每個工作丟進獨立 container 會落入 podenv lane，增加 daemon 與記憶體成本；共用 object-storage daemon 本身已有 bucket + IAM policy 的 multi-tenant primitive，適合 devenv。

本設計新增 provider `s3`，backend 選 RustFS。它不取代 Buzz 自己的 `buzz-minio`；兩者的 durable owner、credentials、volume 與 lifecycle 必須分離。

## 研究證據

分析時 clone 的 source revisions：

- MinIO server: `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`
- RustFS main: `7143697a5f43118f523bc6ebdee39ea18a70cb8d`
- RustFS release `1.0.0-rc.3`: `1aae6803739a5bac67e0d702ac46d43f09fb06dd`
- MinIO client (`mc`): `77f82e18b5401a65958f1619df6ebb994634bd88`

MinIO server README 明寫 repository 不再維護、community edition 改為 source-only；server 與 `mc` 均為 AGPLv3。RustFS 為 Apache-2.0、仍活躍維護，但 `1.0.0-rc.3` 仍是 pre-1.0 release。

針對 `rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5` 的 throwaway live probe 已驗證：

- `mc ready`
- bucket create/remove
- IAM user create/remove
- custom policy create/attach/remove
- tenant 對自己 bucket 寫入成功
- tenant 對另一 bucket list 得到 `Access Denied`
- 同一 user/policy 重建可冪等 reconcile

同一次 probe 中，`mc admin info` 回 `Unable to get service info`。因此 RustFS 只在本設計列出的 S3 data-plane 與 IAM commands 上視為已驗證；不得宣稱完整 MinIO admin 相容。

## 目標

1. `devenv provision <key> --with s3` 以一個指令取得獨立 bucket 與 credentials。
2. 同 key 重跑拿到相同 bucket、access key 與 secret，並修復缺失的 user/policy/bucket。
3. 一個 tenant 只能操作自己的 bucket；不能 list/read/write 其他 tenant。
4. S3 是 opt-in provider，不改變既有 `postgres,valkey` default。
5. RustFS 故障只影響選到 `s3` 的操作，不阻斷 PostgreSQL、Valkey、HTTP、Paperclip 或 Hermes。
6. Object data 與 IAM state 經 service restart/recreate 保留，只有 operator 執行 `devenv release` 才回收。
7. 乾淨機器 `scripts/setup.sh` 後即可申請 S3，不需手動 bootstrap。

## 非目標

- 完整 MinIO admin API、console 或 AIStor 相容。
- Bucket versioning、lifecycle rules、notifications、replication、object lock、KMS。
- 自動 GC、idle release、quota 或 per-tenant 容量限制。
- 對外網路或遠端瀏覽器可達的 object endpoint。
- 用 object-storage IAM 當 hostile-agent security boundary。既有 devenv 定義仍成立：隔離用於防碰撞與防手滑，不是 OS 級秘密隔離。
- 重用或遷移 `buzz-minio`。
- 同時支援 MinIO/RustFS 的 backend switch。

## 核心決策

### RustFS，不選 MinIO

採用 RustFS 的原因：

- server Apache-2.0；MinIO community server 已停止維護且為 AGPLv3。
- RustFS release source 已包含本設計需要的 MinIO-compatible user/policy routes。
- 所需操作已對固定 release 與固定 `mc` 版本實跑，而不是只看 feature table。

代價：RustFS 尚未 1.0，且已知 `mc admin info` 不相容。應以精確 image digest、窄 acceptance contract 與 live gates 控制風險。

### 使用 pinned `mc`，不自製 admin protocol client

paperclip image 帶一支固定版本 `mc` static binary：

- version: `RELEASE.2025-08-13T08-35-41Z`
- image digest: `minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727`

只呼叫 live probe 已驗證的 commands。`mc` 是 AGPLv3；這不是新 license 類型，現有 compose 已用 `minio/mc:latest` 與 `minio/minio:latest` 服務 Buzz，但新 devenv 路徑仍必須 pin，不延續 `latest`。

不以 RustFS crates 自製 helper：那會新增一個要維護 signing、admin wire format、error mapping 與 cross-architecture build 的 compiled component，只為避開一支既有 client。

## 架構

```text
compose
  devenv-pg       registry + PostgreSQL tenants
  devenv-valkey   Valkey tenants
  devenv-s3       RustFS S3 API, named volume
       ▲
       │ root admin calls (pinned mc, only when s3 selected)
       │
  devenv CLI in paperclip image
       │
       ├── devenv_tenant registry
       └── workspace .env
                 ▲
                 │ AWS/S3 variables only
           tenant application
```

### Compose service

新增 `devenv-s3`：

- image: `rustfs/rustfs:1.0.0-rc.3@sha256:800cf3f352a0a27e3275ca854a51f0027975d7acc7a0d52089a35bcc9fcbf0b5`
- restart: `unless-stopped`
- data: named volume `devenv-s3-data:/data`
- internal API: `devenv-s3:9000`
- console: disabled，不 publish 9001
- healthcheck: RustFS `/health`
- host API: `127.0.0.1:${DEVENV_S3_PORT:-9002}:9000`

Host port 只供同一台 workstation 的 operator client 使用。它不是 browser/public endpoint。若未來要讓遠端 browser 直接使用 presigned URLs，必須另做 public-host/bind 設計；不可悄悄把 loopback 改成 `0.0.0.0`。

paperclip **不得**以 `service_healthy` 依賴 `devenv-s3`。Compose 仍會啟動 service，但 RustFS unhealthy 不得阻止 paperclip 啟動或非 S3 lease 操作。

### Credentials

RustFS root credentials 由 compose env 提供：

- `DEVENV_S3_ROOT_USER`
- `DEVENV_S3_ROOT_PASSWORD`

Tenant secret 使用既有：

```text
devenv_derive_password <key> s3
```

Secret 不存進 registry。`DEVENV_SECRET_SALT` 改變會使所有既有 tenant credentials 失效，與 PostgreSQL/Valkey 現況相同。

`mc` 透過 process env 取得 root endpoint/credentials；provider 不開 shell tracing，不把 root secret寫進錯誤訊息或檔案。和現有 PostgreSQL/Valkey admin credential 一樣，這不是同 UID hostile-process 的安全邊界。

## CLI 與按需語意

介面：

```sh
devenv provision <key> --with s3
devenv provision <key> --with postgres,s3
devenv provision <key> --with postgres,valkey,http,s3
```

規則：

- 未傳 `--with` 時仍為 `postgres,valkey`。
- `s3` 不加入 default。
- provision 只 probe/建立本次 `--with` 指定的 providers；release 只處理 registry 已登記的 providers。
- `--with` 可對既有 lease 增量加入 provider；每個成功的 provider 立即 union 進 `providers`，不移除既有項目。
- 未選 `s3` 時，錯誤的 `DEVENV_S3_HOST` 或 unavailable RustFS 對操作沒有影響。

新增 `providers/s3.sh`，遵守現有契約：

```text
s3_probe
s3_provision <key> <slug>
s3_release <key> <slug>
```

### 名稱

SQL slug `devenv_<key-with-underscores>` 不適合 S3 bucket，因為 `_` 不是合法 DNS bucket character。S3 provider 使用獨立名稱：

```text
devenv-<key>
```

目前 key regex 與長度上限使結果長度為 9..48，落在 S3 的 3..63，且只含小寫字母、數字、hyphen。Bucket、IAM user、policy 使用同一名稱；`devenv-` namespace 保留給 provider。

### Tenant policy

Bucket resource `arn:aws:s3:::devenv-<key>` 允許：

- `s3:GetBucketLocation`
- `s3:ListBucket`
- `s3:ListBucketMultipartUploads`

Object resource `arn:aws:s3:::devenv-<key>/*` 允許：

- `s3:GetObject`
- `s3:PutObject`
- `s3:DeleteObject`
- `s3:AbortMultipartUpload`
- `s3:ListMultipartUploadParts`

不允許 create/delete bucket、policy/IAM 操作或其他 bucket resource。

### Provision sequence

對每個選中的 S3 provider：

1. `s3_probe`。
2. 建立 bucket（已存在視為成功）。
3. 建立或更新 tenant user，使 derived secret 收斂。
4. 建立或更新精確的 bucket policy。
5. attach policy 到 user。
6. 寫入 registry 的 `s3_bucket`，並把 `s3` union 進 `providers`。
7. 所有選中 providers 都成功後，才 atomic merge `.env`。

新 lease 先以空 `providers` 建立 registry row；每個 provider 完成後立即登記。這讓新舊 lease 在後續 provider 失敗時都不會留下「resource 已存在但 registry 說沒有」的狀態。所有選中 providers 都成功後才寫 `.env`；失敗時不寫半成品，重跑會從 registry 與 backend reconcile。

新 lease 的 provision failure 只 rollback 本次 invocation 已建立並登記的 providers，再刪除空 row。既有 lease failure 不 teardown 原有 providers；本次已成功新增的 provider 留在 registry，重跑可繼續完成。

### `.env` contract

S3 provider輸出：

```dotenv
AWS_ENDPOINT_URL=http://devenv-s3:9000
AWS_ACCESS_KEY_ID=devenv-<key>
AWS_SECRET_ACCESS_KEY=<derived>
AWS_REGION=us-east-1
S3_BUCKET=devenv-<key>
S3_FORCE_PATH_STYLE=true
```

前四項採 AWS SDK 常見環境變數；`S3_BUCKET` 與 `S3_FORCE_PATH_STYLE` 是 devenv application contract，不是所有 SDK 都會自動讀取。Skill 必須要求 application 明確把 bucket 與 path-style 設定接進所用 SDK。

Path-style 是必要條件：virtual-host style 會要求解析 `devenv-<key>.devenv-s3`，compose DNS 不提供該 wildcard。

Presigned URL 的第一版合約只保證 S3 signing/data-plane correctness：由同 Docker network 或 workstation loopback 的 credentialless client 可使用。因 endpoint 不公開，遠端 browser reachability 明確不在本次範圍。

以上六個名稱加入 `shared.sh` 的 reserved set，podenv 不得寫入。Provider image-family gate 新增：

```text
s3=s3
minio=s3
rustfs=s3
```

因此現代 S3/MinIO/RustFS image requests 會指向 `devenv provision --with s3`；需要特定舊版或不能 multi-tenant 的 object daemon 才屬 podenv。

## Registry 與 list

`devenv_tenant` 新增：

```sql
s3_bucket text UNIQUE  -- NULL = s3 not provisioned
```

由 `bootstrap.sql` 以 `ALTER TABLE devenv_tenant ADD COLUMN IF NOT EXISTS s3_bucket text UNIQUE` reconcile。`devenv_usage` 與 `devenv list` 顯示 bucket name。

`devenv list` 不同步呼叫 RustFS 或 `mc du`。Listing 是故障時的 operator visibility tool；不能因一個 optional backend timeout 而讓所有 lease 消失。需要容量時，operator 可用該 tenant `.env` 與 host loopback endpoint 執行 `mc du`。

## Release 與 failure semantics

`devenv_teardown` 不再無條件呼叫所有 providers；它只按 registry 的 `providers` release。這是 S3 加入後的必要 correctness change：RustFS down 不得阻止純 PostgreSQL lease 回收。

S3 release 次序：

1. 若 bucket 存在，force-empty 並 remove。
2. 若 user 存在，remove。
3. 若 policy 存在，remove。
4. 成功後清除 `s3_bucket`，並從 `providers` 移除 `s3`。

其他 provider 也在各自 release 成功後清除 allocation columns 並從 `providers` 移除自己。所有 provider 都移除、`providers` 為空後才 delete tenant row。這使跨 backend release 中途失敗時，registry 精確保留尚待回收的資源；重跑不會重做已完成的 destructive step。

每一步對 absent resource 冪等。真正的 backend/admin error 不得 `|| true`：command exit `4`，registry row 保留尚待回收的 provider，operator 修復 backend 後重跑同一個 release。不得把投遞失敗標成已回收。

Exit codes沿用：

- `0`: 成功
- `2`: usage/provider argument 錯誤
- `3`: 有界 pool 用罄；S3 本身第一版無 tenant count pool
- `4`: backend unreachable 或 provider 無法完成 reconcile/release

不得 fallback 到 tenant 共用 root credentials、`buzz-minio` 或臨時 podenv container。

## Verification

新增 `tests/devenv-s3.sh`。Test 只建立並回收自己命名的 gate leases。

### Structural checks

1. RustFS image tag + digest 精確匹配。
2. `devenv-s3-data` named volume 掛到 `/data`。
3. host port bind 為 `127.0.0.1`。
4. console disabled / 9001 未 publish。
5. paperclip 沒有 `devenv-s3: service_healthy` dependency。
6. paperclip image 內 `mc --version` 精確匹配 pinned release。
7. `shared.sh` reserved env names 與 provider image-family gate 完整。

### Live contract

1. 把 S3 host override 成不可達後，`--with postgres` 仍成功。
2. `--with s3` 產出六個 env names；重跑 byte-for-byte 相同。
3. Tenant A 對自己 bucket PUT、GET、LIST、DELETE 成功。
4. Multipart upload 成功。
5. Credentialless client 可使用 presigned URL 下載；probe 在同 Docker network 或 workstation loopback 執行，不宣稱遠端 browser reachability。
6. Tenant A 對 tenant B bucket 的 LIST、GET、PUT 都得到 `AccessDenied`。
7. Force-recreate `devenv-s3` 後，object 與 tenant credential 仍可用。
8. Release A 後 bucket/user/policy 不存在；tenant B 完整保留。
9. RustFS unavailable 時，新 S3 provision exit `4`，不留 registry row或 `.env` 半成品。
10. RustFS unavailable 時，`devenv list` 仍列出 registry leases。
11. RustFS unavailable 時，純 PostgreSQL lease release 不受影響。

### Clean install

- `tests/fresh-install.sh` 清除/offset `DEVENV_S3_PORT`，避免 rehearsal 與 live stack 衝突。
- Fresh-install gate 執行 `tests/devenv-s3.sh`。
- `tests/audit-bootstrap.sh` 檢查 RustFS volume、root credential source、pinned `mc` 與 schema producer。

## 文件與操作面

實作同步更新：

- `.env.example`: `DEVENV_S3_ROOT_USER`、`DEVENV_S3_ROOT_PASSWORD`、`DEVENV_S3_PORT`
- `SETUP.md`: `--with s3`、host loopback inspect、release destructive semantics；既有單機若需 recreate/boot 的可貼指令，不新增 migration script
- `patches/paperclip/skills/devenv/SKILL.md`: provider、六個 env names、path-style wiring、按需/default、failure exit 4
- `AGENTS.md`: 架構、volume、常用指令、按需故障隔離、RustFS 已知相容邊界、檔案地圖與 gate

## 預期修改面

- `docker-compose.yml`
- `.env.example`
- `SETUP.md`
- `AGENTS.md`
- `patches/paperclip/Dockerfile`
- `patches/paperclip/devenv/devenv`
- `patches/paperclip/devenv/shared.sh`
- `patches/paperclip/devenv/bootstrap.sql`
- `patches/paperclip/devenv/providers/s3.sh`（新增）
- `patches/paperclip/skills/devenv/SKILL.md`
- `tests/devenv-s3.sh`（新增）
- `tests/audit-bootstrap.sh`
- `tests/fresh-install.sh`

`upstream/` 不直接編輯；`scripts/prepare.sh` 只在 implementation/verification 階段同步 patch。

## Risks 與控制

| Risk | Control |
|---|---|
| RustFS pre-1.0 行為漂移 | tag + digest pin；只升版時重跑完整 live gate |
| MinIO admin compatibility 不完整 | 只用已驗證 commands；`mc admin info` 明列為 unsupported evidence |
| optional backend 拖垮 stack | paperclip 無 health dependency；只在選中 provider 時 probe/release |
| credential 或 bucket 漂移 | derived secret + idempotent bucket/user/policy reconciliation |
| cross-tenant access | bucket-scoped IAM policy + A/B negative tests |
| release 半成功卻丟失 truth | backend cleanup 全成功後才刪 registry；錯誤 exit 4 |
| presigned URL 被誤認為公開 | loopback-only 與 remote-browser non-goal 寫進 contract、skill、tests |
| `latest` 靜默改版 | RustFS 與新 `mc` 路徑都 pin tag + digest |
| 開發資料無限長大 | manual release 不變；list 顯示 bucket，operator 顯式檢查/回收 |

## Acceptance criteria

1. `devenv provision demo --with s3` 在乾淨安裝產出可用且冪等的 bucket credentials。
2. `devenv provision demo --with postgres` 不接觸 RustFS；RustFS 故障時仍成功。
3. S3 tenant 只能完成自己 bucket 的核心 object/multipart operations。
4. Cross-tenant LIST/GET/PUT 均由 backend policy 拒絕。
5. Restart/recreate 不丟 object 或 IAM state。
6. `devenv release demo` 完整刪除該 tenant S3 state，且不碰其他 tenant。
7. Release/provision failure 保留 registry truth，不留下被宣稱成功的半狀態。
8. `tests/devenv-s3.sh`、既有 connectivity/scientist/podenv gates 與 fresh-install rehearsal 通過。
