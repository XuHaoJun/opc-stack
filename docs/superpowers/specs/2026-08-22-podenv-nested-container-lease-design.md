# Podenv — Nested Container Lease Design Spec

日期: 2026-08-22
狀態: 設計完成 (Phase 0 量測已完成), 未實作

## 背景

devenv 的定位是**快速 prototype 與 modern project**: 共用後端 + multi-tenant 切分, 一個
`devenv provision` 就拿到隔離的 postgres/valkey。這個定位要維持不變。

它蓋不到的是**不能 multi-tenant 的 daemon**, 以及**很老舊的版本**。例子: 超舊版 mysql
(5.5/5.7)、Milvus、單租戶設計的 daemon、以及任何「上游只以 image 形式存在」的東西。把它們
一個一個塞進 devenv 是錯的 —— 那會讓 devenv 從「共用後端租約」變成「任何開發資源都在這裡」,
定位就消失了; 而每加一個專案就改一支 provider + 改 compose 也不可能是常態工作流。

`docs/superpowers/specs/2026-08-18-devenv-resource-provisioning-design.md` 已經預留了這個
決定。它的「非目標」寫著「容器化資源 (任意 image)。需要時走 podman sidecar, 屬另一個 spec」,
排除理由寫著「代價是不能測試容器拓撲本身…真的需要時再回頭評估」。**本 spec 就是那一項。**

## 考慮過並排除

### Coolify / OpenShip (self-hosted PaaS)

兩者都是**掛 host docker socket 的控制面**:

- OpenShip (`github.com/oblien/openship`, 2026-07 發布) 的文件原話: API container 掛 host
  docker socket 讓 control plane「build + run your apps as host containers」, 並自己註明
  「it's host-privileged through the socket, so run it only on a trusted host」。stack 是
  postgres + redis + api + dashboard + edge, edge 以 `network_mode: host` 佔 80/443。
- Coolify 的安裝腳本要 root、自己裝 Docker Engine 24+、改 daemon 設定、建 `/data/coolify`、
  配 SSH key; 面板 8000, 實際跑 app 靠 host docker。最低 2 core / 2GB RAM / 30GB。

排除的**主要**理由不是重量, 是**它們不能是 agent 呼叫的那一層**。把 Coolify/OpenShip 的 API
token 交給以 `--yolo` 跑的 agent, 等於把 docker.sock 用 HTTP 包一層再交出去 —— 兩者都能以
任意 image 配任意 bind mount 開容器, 所以 `-v /:/host` 只是換了個入口。compose 裡看不到
socket, 不變量 6 卻在實質上破了, 而且會通過所有靜態稽核。**這比直接掛 socket 更危險。**

它們**可以**放在另一個位置 (純 operator 工具, 跑在 stack 外, agent 只拿到連線字串), 那個擺法
不動不變量 6。仍然排除, 因為它撞「部署假設」: AGENTS.md 要求「乾淨機器 `git clone` →
`scripts/setup.sh` 之後全部功能可用, 不需要任何手動補步驟」。一旦某個專案的 DB 住在 Coolify
裡, 那個專案就不再能從這個 repo 重現。

### DinD (docker:dind)

實務上要 `privileged`, 連官方的 `dind-rootless` image 文件都要求 `--privileged`。直接違反
不變量 6。這也是「DinD 問題很多」在本 repo 的硬版本: **podman 不需要 privileged, DinD 需要。**

### repo 內宣告 + operator 跑一次 compose

不需要巢狀 runtime、留在版控裡、工程量最小。排除的唯一理由是**它不能自助** —— 見下節的目標 1。

## 目標

1. **Agent 自助。** prototyper / scientist 在跑 ticket 的過程中自己決定需要一顆舊 daemon 並
   取得它, 不必停下來等人。這一條直接排除任何拿得到 host socket 的方案。
2. **寬介面 + lease 包裝層。** 底層是完整 podman (能 build、能測 Dockerfile), 上面一層與
   devenv 同形的 lease 指令服務「只想要一顆 mysql」的場景。
3. **耐久。** 開機自動叫回, 只有人跑 `release` 才消失 (不變量 6b)。正式專案可以依賴它。
4. **不動不變量 6 的兩條。** 無 host mount、無 privileged。
5. **與 devenv 不打架**, 而且「devenv 已提供就優先」要靠機制而非只靠文字。

## 非目標

- **安全邊界。** 真正的邊界是**外層那個 docker 容器**, 不是 podman。rootless userns 是為了
  不需要 privileged, 不是為了防 agent。與 devenv 的「安全模型」同一個立場。
- **磁碟配額。** 做不到 (見「量測結果」§8), 只有可觀測性。
- **per-lease 記憶體/CPU 上限。** 做不到 (見「量測結果」§4)。整條 lane 一個上限做得到。
- 自動回收、排程、對帳。手動 `podenv release`, 照不變量 6b。
- image allowlist / 供應鏈檢查。
- 發給 hermes 專家。podenv 是 **paperclip lane only** —— 理由見下面的專節,
  `SOUL.md` 完全不動。
- 接 board UI。
- 主動支援 `docker compose`。podman 的 socket 本來就說 Docker API, 未來要加不用改架構。

## Phase 0 量測結果

本 repo 的規矩是 runtime 行為**要靠量測驗證, 不要只靠讀 source 判斷** (hermes multiplex 的
provider key 那條紀錄就是活例: 讀 source 得到的因果跟量到的現象相反)。以下全部在 2026-08-22
以丟棄式容器量過, host 是 kernel 7.2.0-1-cachyos / docker storage driver `overlayfs` /
cgroup v2 / seccomp builtin profile / **無 AppArmor、無 SELinux、無 userns-remap**。
量到的 podman 版本 5.8.4, image digest
`sha256:8923deffca4caa8338b5dd4f553a86736f2aab424a4743827fccce632fecd750`。

**其中 §3 與 §4 推翻了設計初版。**

1. **rootless podman 在 docker 容器內只需要 `seccomp=unconfined`。** 無 privileged、無 host
   mount、無 device。反向確認: 拿掉那一行就是 `cannot clone: Operation not permitted`
   (docker 預設 profile 擋帶 `CLONE_NEWUSER` 的 namespace 建立), 所以這個放寬**確實必要**,
   不是保險式地加上去的。
2. **storage driver 是原生 `overlay`。** 不需要 fuse-overlayfs, 也不需要 `/dev/fuse` —— 這
   是 kernel 5.11+ 的 rootless overlay。比 2026-08-18 那份 spec 當時的預估更好。
3. **socket 的存取閘是 uid, 不是 gid。** 原設計是「setgid 目錄 + 共用 gid 3001」, 照
   `nixagents gid 3000` 的前例。setgid 目錄確實讓 socket 繼承了 gid, **但 podman 在建好
   listener 之後才把 socket chmod 回 0600**。試過三種都失敗: umask 無效; 單次背景 chmod 會
   race; 帶驗證的重試迴圈**會報告成功** (`stat` 當下真的是 660) 然後被 podman 改回去 ——
   最惡劣的一種, 修復腳本自己確認成功了。
   跟 podman 的意圖搶 chmod 是錯方向, 它刻意釘 0600。正確機制是**順著它走: uid 對齊** ——
   podenv 的 runtime uid 設成 paperclip `node` 的 **1000**, socket 的 owner 就是 client。
   量測: uid 1000 連上 (`podman version` 的 `.Server.Version` = 5.8.4, 證明是遠端不是本地),
   uid 9999 明確 `connect: permission denied`。
   副作用是**設計少一個約束**: 不需要 `podagents gid 3001` 這個跨 image 必須同數字的東西。
   另外目錄本身是第二道獨立的閘 (uid 對但不能 traverse 目錄時同樣被拒), 兩道閘都留著。
4. **per-lease 記憶體上限做不到。** 實測 `podman run --memory 128m` → nested 容器的
   `memory.max` 是 `max`, **podman 一行警告都沒有**。這正是本 repo 一再記錄的無聲失效類型。
   有**兩個**已量到的成因, 而我**沒有隔離出是哪一個在起作用** (照本 repo 對 hermes multiplex
   憑證那條的做法, 因果不確定就要寫明, 不要把讀出來的推論當量測):
   - `/sys/fs/cgroup` 在容器內是 **`ro` 掛載, root 也寫不了** (`touch: Read-only file system`),
     所以原設計的「entrypoint chown 自己的 cgroup 目錄取得 cgroup v2 delegation」根本不可能
     —— 要做到只能掛 host 的 `/sys/fs/cgroup`, 那就違反不變量 6。
   - `quay.io/podman/stable` 的 `containers.conf` 明確寫著 **`cgroups="disabled"`** 與
     `cgroup_manager="cgroupfs"`。
   兩者任一單獨成立都足以讓 `--memory` 失效, 所以結論 (per-lease 上限不可交付) 是穩的,
   但**不要在 spec 或 commit message 裡把成因說成只有 ro 掛載那一條**。
   可行的替代是**整條 lane 一個上限**: compose 給 podenv service 自己 `mem_limit`。這條與上面
   兩個成因都無關 —— nested 容器的行程是 podenv 容器行程的子孫, 活在 podenv 自己那個被 docker
   限制的 cgroup 裡。
5. **網路有三種, 其中一種不可能。**
   - `quay.io/podman/stable` 的 `/etc/containers/containers.conf` 寫著 `netns="host"`, 所以
     nested 容器**預設共用 sidecar 的 netns**。這條路通 (從 p0-net 上另一個容器打
     `p0-server:80` 拿到 whoami 的回應), 零 publishing。但 `-p` 被整個丟掉 ——
     `podman ps` 的 Ports 欄是空的, **而且沒有警告**, 且所有 lease 共用一個 port 空間。
   - **bridge / netavark 不可能。** netavark 要寫
     `/proc/sys/net/ipv4/conf/podman0/route_localnet`, docker 掛 `/proc/sys` 為 ro,
     非 privileged 改不了 (`IO error: Read-only file system (os error 30)`)。
   - **pasta 成立, 需要 `--device /dev/net/tun`。** 給了之後 `-p 22001:80` 真的生效
     (`podman ps` 顯示 `0.0.0.0:22001->80/tcp`), 每個 lease 有自己的 netns, 從別的容器經
     docker DNS 打 `podenv:22001` 通。沒有這個 device 時 pasta 是
     `Failed to open() /dev/net/tun`。slirp4netns 不在這個 image 裡 (pasta 是現代預設)。
6. **nested 容器反向連 stack 服務可行**, host netns 與 pasta 兩種都通
   (`nc -z devenv-pg 5432` 成功)。
7. **bind-mount 歸屬乾淨。** nested 容器建的檔案落在 uid 1000 (= paperclip 的 `node`),
   **加不加 `--userns=keep-id` 都一樣**。原因不是我最初以為的「rootless 的 container-root
   映射到呼叫者」, 而是 `quay.io/podman/stable` 的 `containers.conf` 寫著 **`userns="host"`**
   (連同 `netns`/`ipcns`/`utsns`/`cgroupns` 全部是 host) —— nested 容器根本沒有自己的 userns。
   量到的結果不變, 但成因不同, 而成因決定了下一句: **我們的 containers.conf 只改 `netns`,
   `userns="host"` 必須留著**, 否則檔案會落在 subuid 區間 (image 的 `/etc/subuid` 給
   `podman:1:999` 與 `podman:1001:64535`), `/prototypes` 就重演不變量 3b 那種擁有權痛苦。
   代價要說清楚: nested 容器之間**共用 sidecar 的 userns**, 彼此隔離很弱 —— 這與「邊界是外層
   docker 容器」的既有立場一致, 不是新的妥協。
8. **磁碟沒有硬上限的路。** docker named volume 沒有 size 旋鈕; 在容器內掛 loopback ext4 要
   `CAP_SYS_ADMIN` (等於回到 privileged)。所以磁碟只能走 devenv 的既有立場: **可觀測性而非
   配額**。

## 架構

### compose service

新的 compose service `podenv`, build context `patches/podenv/` —— 跟 `patches/nix-seed/`
一樣是不屬 submodule 的自有 build context。

```
patches/podenv/Dockerfile               FROM quay.io/podman/stable (pin digest)
patches/podenv/containers.conf          覆蓋上游的 netns="host" → "pasta"
patches/podenv/opc-podenv-entrypoint.sh
patches/podenv/opc-podenv-restore.sh
patches/paperclip/podenv/podenv         CLI (shell, 與 devenv 同結構)
patches/paperclip/skills/podenv/        per-agent opt-in 的 skill
```

**刻意不 COPY nix-seed。** AGENTS.md 已記 seed 是「逐 image 各付一次」的成本
(`COPY --from=nix-seed` 把同一份烤進每個 image 的 layer), 而這個容器沒有人會 shell 進去
工作 —— 它是 runtime host, 不是工作環境。

compose 上的三項宣告, 每一項都要有註解說明為什麼:

```yaml
security_opt:
  - seccomp=unconfined      # 量測 §1: 唯一必要的放寬, 不是 privileged
devices:
  - /dev/net/tun            # 量測 §5: pasta 的 -p 轉發需要
mem_limit: ${PODENV_MEM_LIMIT:-4g}   # 量測 §4: 唯一真的生效的記憶體旋鈕
```

**不需要**的東西 (量到才知道, 所以要寫下來免得日後有人「補上」): `apparmor=unconfined`
(host 未載入 AppArmor)、`label=disable` (無 SELinux)、`/dev/fuse` (原生 overlay)、
`privileged`、任何 host mount。

### 身分與 socket

entrypoint 以 root 起, 做兩件只有 root 能做的事, 然後降權:

1. `chown` storage volume 與 `XDG_RUNTIME_DIR` 給 runtime uid;
2. `chown` socket 目錄給 runtime uid, 目錄 `0700`。

然後 `setpriv --reuid 1000 --regid 1000 --clear-groups` 跑
`podman system service --time=0 unix:///run/podenv/podman.sock`。

**socket 保持 podman 自己的 0600, 不去動它** (量測 §3)。存取閘是 owner uid, 而那個 uid
**必須等於 paperclip 的 `node`**。這是一個跨 image 必須同數字的約束, 與 `nixagents gid 3000`
同一類 (AGENTS.md 原話: 「跨 image 必須同數字 —— 共用 volume 上比對的是數字」), 因此:

- podenv 的 Dockerfile 有一條 **build-time 斷言**: `id -u podman` 不等於 1000 就讓 build 失敗。
  這把「上游 image 換了 uid」從 runtime 的權限錯誤變成 build 時的明確失敗。
  (量到的現況: `quay.io/podman/stable` 的 `podman` 使用者恰好就是 uid 1000, 所以斷言目前是
  免費的。斷言存在的意義是上游哪天改動時**在 build 時**炸, 而不是在 socket 連線時。)

**與 paperclip Dockerfile 那句「Unifying the runtime UIDs instead was rejected」不衝突**,
方向相反: 那句拒絕的是**改動既有 image 的 uid** (paperclip 的 1000 來自上游 node base image,
而既有 home volume 是現有 uid 擁有的 —— 不變量 3b)。這裡是一個**全新的 image、沒有任何既有
volume**, 讓它去對齊既有的 1000。沒有任何既有擁有權被改動。
- `tests/podenv.sh` 有一條結構檢查: paperclip 的 `id -u node` == podenv 的 runtime uid。

### 網路

CLI 的 lease 預設 `--network=pasta` (量測 §5), 並且我們自己的 `containers.conf` 把
`netns` 從上游的 `host` 改成 `pasta`, 讓**寬介面的裸 `podman run` 與 lease 行為一致** ——
否則 agent 會拿到 host netns 而 `-p` 靜靜失效。

**這個檔是最小差異覆蓋, 不是重寫。** 上游那份把 `netns`/`userns`/`ipcns`/`utsns`/`cgroupns`
全設成 host, 加上 `cgroups="disabled"`、`cgroup_manager="cgroupfs"`、`log_driver="k8s-file"`、
`events_logger="file"`、`runtime="crun"`。**只改 `netns` 一行, 其餘逐字保留** —— 特別是
`userns="host"` (量測 §7: 拿掉它 `/prototypes` 的檔案歸屬就壞) 與 `cgroups="disabled"`
(量測 §4)。整份重寫會在看不出關聯的地方壞掉。

`--netns host` 是**顯式**退路 (遇到 pasta 搞不定的 image)。

**不做靜默 fallback。** 如果開機自我檢測發現 pasta 不可用 (別人的機器沒有
`/dev/net/tun`), CLI 拒絕 pasta 並指向 `--netns host`, 而不是自己換過去 —— 靜默降級會讓
agent 以為有 per-lease netns 實際上共用一個。

對外位址兩層:

- **stack 內**: docker DNS, `podenv:<port>`。零 publishing。
- **operator**: podenv service 上發佈一段固定 range 到 **127.0.0.1** (跟 `devenv-pg` 同
  立場 —— 讓**你**能拿 client 接上去, 不是讓 LAN 能)。

`PODENV_PORT_BASE` 預設 23000, `PODENV_PORT_COUNT` 16。**base 必須低於 32768** (kernel
ephemeral range) —— 與 devenv http provider 完全相同的理由, 在 range 內 `bind(0)` 可能搶走
已租但當下沒 listen 的 port。compose 的 `ports:` 與 CLI 的 base/count 是**兩個必須一致的
來源, compose 不會算術**, 所以開機檢查要 warn (照 `DEVENV_HTTP_PORT_RANGE_END` 的既有做法)。

### storage

`opc-podenv-store:/home/podman/.local/share/containers` (image + 容器), 原生 overlay。
`opc-podenv-sock:/run/podenv` (socket, 同時掛進 paperclip)。
`opc-prototypes:/prototypes` (與 paperclip 共用, 讓 `-v /prototypes/foo:/app` 成立)。

**明確不掛**: `opc-keys`、任何 hermes home、`opc-gh-creds`、`opc-prototyper-home`。
由 `tests/podenv.sh` 的結構檢查釘住。

## 介面

### 寬介面

paperclip image 裡有 `podman-remote` client, entrypoint 匯出
`CONTAINER_HOST=unix:///run/podenv/podman.sock`。Agent 直接 `podman build / run / ps`。

`docker exec` 的互動 session 不繼承 entrypoint 的 runtime export (AGENTS.md 已記這個坑),
所以 `CONTAINER_HOST` 也要放進 image 的 `ENV`, 不能只在 entrypoint 匯出。

### lease 包裝層

```
podenv provision <key> --image <ref> --port <container-port> [--as VARNAME]
                       [--env K=V ...] [--netns pasta|host] [--dedicated "<reason>"]

`--port` 是**容器內**那個 daemon 在 listen 的 port (mysql 給 3306)。對外的 port **由 CLI
從 pool 配置**, 呼叫者不指定也不需要知道 —— 它只從輸出的 `.env` 變數讀連線字串。pasta 模式
下這是 `-p <allocated>:<container-port>` 的重映射; `--netns host` 模式下重映射不存在
(量測 §5), 所以那個模式要求 `--port` 已經是全 lane 不衝突的值, CLI 撞到就以 exit 3 拒絕。
podenv release   <key>
podenv list
```

冪等靠與 devenv 相同的手法: 密碼從 `DEVENV_SECRET_SALT` **推導而非儲存** (直接 source devenv
的 `devenv_derive_password`, 不抄一份), 所以重跑交還同一組值。輸出寫進 workspace `.env`,
沿用 devenv 的 `devenv_env_merge` —— 它只丟掉自己即將寫入的 key, 其餘原樣保留
(`patches/paperclip/devenv/devenv:136-145`), 這是共存成立的機制基礎。

**沒有 `--memory`。** 量測 §4: 它不可能生效, 而提供一個什麼都不做的旗標是本 repo 記錄過最多
次的失敗模式。skill 要明講「裸 `podman run --memory` 會被靜靜忽略」, 因為 agent 手上有寬
介面一定會試。

**兩種介面的分工靠 label 而非權限。** lease 建的容器帶 `opc.podenv.lease=<slug>`; 開機
restore 只叫回有這個 label 的, `list` 也只看得到它們。Agent 裸 `podman run` 出來的東西
**不會被叫回、不會被列出**。這個不對稱本身就是「該用 lease 就用 lease」的誘因, 不需要擋。

## 與 devenv 的分工

「devenv 已提供就優先使用」這句話裡有**兩種不同的失誤, 只有一種能靠文字修**。所以分三層。

### (a) 共存: lease key 就是 join 點

`devenv provision myproj --with postgres` 與 `podenv provision myproj --image milvus:v2.5`
用**同一個 key**, 寫同一份 `.env`, 在 `devenv list` 上一個 key 一行、兩邊都顯示。podenv 沿用
devenv 的 key regex (`^[a-z][a-z0-9-]{1,40}$`) 與 env merge, 但**不建 FK** —— podenv 必須在
沒有 devenv lease 的情況下也能單獨成立。

### (b) 變數名分治: 機制, 不是約定

devenv 佔用的名字 (量到的完整清單, 來自
`patches/paperclip/devenv/providers/*.sh`): `DATABASE_URL`、`VALKEY_URL`、`DEV_PORT`、
`DEV_PORT_<n>`、`DEV_URL`、`DEV_HOST`、`HOST`。

podenv **拒絕**寫出其中任何一個。`--as <VARNAME>` 顯式指定, 或從 image 名推導
(`milvus` → `MILVUS_URI`); 落在保留清單裡就直接失敗, 錯誤訊息指向 devenv 的正確指令。

關鍵在保留清單**從 devenv 派生, 不是手抄第二份**。這需要**改 devenv**: 目前那些名字散落在
`providers/*.sh` 的 `printf` 裡, 沒有可引用的定義。所以實作要在 `devenv` 加一個匯出保留名的
函式 (單一正本), podenv `source` 它。這個 repo 已經因為「同一份規則存在兩個
地方」壞過至少三次 (兩份 `paperclip-api` SKILL.md、兩份 `SOUL.md`、nix seed 工具清單),
`scripts/prepare.sh` 裡那些防漂移檢查就是傷疤。兩支 CLI 住在同一個 image, 所以 podenv
直接 source devenv 的定義, 這條線根本不需要漂移檢查。

於是「postgres(devenv) + Milvus(podenv)」不是被允許, 而是**唯一可能的形狀**。

### (c) 路由 gate: 機制擋錯誤, 文字管判斷

`podenv provision --image postgres:16` 直接拒絕, 訊息告訴它去跑
`devenv provision <key> --with postgres`。要 gate 的 image 家族 (`postgres`、`pgvector`、
`valkey`、`redis`) 同樣**從 devenv 的 provider 清單派生**。

但 **postgres 9.6 是 podenv 的正當用例**, 所以這不能是絕對禁止, 而是**要付代價的繞道**:

```
podenv provision legacy-erp --image postgres:9.6 \
  --dedicated "pg9.6, devenv 是 pg18, client API 不兼容"
```

`--dedicated` 的理由字串**存進登記表並出現在 `devenv list`**。這完全照本 repo 自己的前例走:
`prototype destroy` 刻意不給 `--yes`, 因為「那個旗標會讓這條規則變成一行 script 就能繞過」。
理由被持久化並列出來, 才讓它不是橡皮章。

## 為什麼不發給 hermes 專家

「CLI 住 paperclip image」**不是理由** —— 它住那裡是因為我們決定放那裡, 那是循環論證。
真正的理由三條, 第一條是硬的:

1. **存取閘是單一 uid, 而 hermes 是不同的 uid。** 這是量測 §3 的直接後果: socket 保持
   podman 自己的 0600, 閘門是 owner uid = paperclip `node` 的 **1000**; hermes 跑
   **uid 10000** (compose 的 `HERMES_UID`)。一個 uid 閘不可能同時服務兩者。而「用 group
   服務多個消費者」正是量測 §3 證明 podman 會對抗的那條路。所以給 hermes 存取**不是加一個
   掛載或一個旗標, 是換掉存取機制** —— 設計變更, 不是範圍開關。
2. **hermes 專家今天也沒有 devenv 自助。** `devenv-expert-leases` 是「跑 paperclip image,
   因為 devenv CLI 只住在那裡」, 科學家拿到的是**開機時由 compose one-shot 發的常駐租約**,
   它自己不能跑 `devenv provision`。所以 podenv 不給 hermes **沒有製造新的不對稱**, 只是
   延續現狀。這一條很重要: 若哪天決定要給, 該一起改的是 devenv 與 podenv 兩者, 而不是
   把 podenv 當特例處理。
3. **使用場景形狀不同。** `/prototypes` 是 paperclip lane 的東西; 專家的工作住在
   `hermes-profiles`。目前「跑一顆舊 daemon」的需求來源全部是 prototype/專案。

### 若日後要給, 有兩條路 (未量測)

- **常駐租約 (便宜, 不動存取機制)**: 照 `devenv-expert-leases` 一模一樣的形狀做一個
  `podenv-expert-leases` one-shot —— 跑 paperclip image、provision 容器租約、寫進
  `/keys/podenv-scientist.env`, 由 hermes entrypoint 的 `opc_seed_expert_profile()` merge
  進 profile 的 `.env`。**hermes 容器不需要 socket、不需要 podman client、不碰 uid 問題。**
  給的是「常駐租約」不是「自助」。
- **真正的自助 (要動存取機制, 兩個候選都未量測)**: (i) TCP endpoint 配一個只有 hermes +
  paperclip 的專用 compose 網路 —— 沒有 uid 閘, 成員資格就是閘, 代價是日後有人把服務加進
  那個網路就無聲取得存取, 需要結構測試釘住成員清單; (ii) 第二個 `podman system service`
  行程配第二個 socket —— **同一個 graphroot 上跑兩個 service 行程的鎖定行為未量測**,
  不要在沒量之前假設它安全。

### (d) 文字規則放在哪一個檔

有個不對稱值得寫下來。我們在意的失誤是「agent 明明 devenv 就能解決卻用了 podenv」——
而**那個 agent 依定義已經載入了 podenv 的 skill**。所以決策表的**正本**住在
`patches/paperclip/skills/podenv/SKILL.md`。

- `patches/paperclip/skills/devenv/SKILL.md` 只加**一行前向指標**(不是複製決策表)。
- `patches/paperclip/skills/container-tools/` 同樣只加一行指標 —— 那是 agent 想「我需要一個
  工具/服務」時會載入的 skill, 是自然入口, 但決策表不複製過去。

維持單一正本, 所以不需要新的漂移檢查。

「agent 根本沒載入任何 skill, 直接 `podman run postgres:16`」這件事文字治不了 —— 那正是
(c) 的 gate 存在的理由。

`SOUL.md` **完全不動** —— podenv 是 paperclip lane only, 理由見上一節。

## 登記表

同一個 `devenv_control` database, **自己一張表** `podenv_lease` + 一個 `podenv_usage` view。

不塞進 `devenv_tenant` 的理由: 那張表已經是「一個 provider 一組欄位」的形狀
(`valkey_db`、`http_port_start`、`http_port_count`、`http_exposed_at`), 把 OCI 的 port 區塊
塞進去會讓 devenv 的 schema 背 podenv 的概念, 而 port 區塊重疊那套 table-lock 機制也要複製
一份。

`devenv list` 尾巴加一段以 `to_regclass('podenv_lease') IS NOT NULL` 保護的查詢 ——
podenv 沒裝就完全不影響 devenv, 裝了就有單一可觀測面。這是**對 `patches/paperclip/devenv/devenv`
的一處修改**。連同 (b), 本設計碰 devenv 共三處: 新增 `devenv/shared.sh` (兩支 CLI 共用的
真相 —— env merge、密碼推導、owner、保留變數名、provider image 家族)、`devenv` 改成 source
它並刪掉自己那三份重複定義、以及這裡的 guarded 查詢。

schema 由 podenv 自己的 seed 套用, 冪等, 且**開頭先檢查 control schema 是否存在**。這條直接
抄 `devenv_require_control_schema` 的教訓: 當時 schema 不在, 原始訊息卻喊「no free valkey
database id — run `devenv list` and release one」, 於是人去 release 無辜的租約。

`podenv_usage` 顯示: key、image、netns 模式、published port、`--dedicated` 的理由、
磁碟用量 (`podman system df` 的資料, 不是 postgres 的)、created_by、idle。

## Restore

entrypoint 起 `podman system service` 之後**背景**跑 restore —— 背景是必要的, 它要等的
socket 正是即將 exec 的那個行程。這與 `opc-prototype-restore.sh` 是同一個形狀, 同一個理由。

等 socket 可用後, 對每個帶 `opc.podenv.lease` label 的容器先 `podman stop -t 0` 再 `podman
start`, 然後 probe 該租約自己發布的 port 才算數。

**這條原本寫的是相反的結論, 且已被獨立驗證量測推翻**: 舊版主張「podenv 不需要 probe ——
podman 對自己的容器狀態是權威的, 因為容器就是它的子行程, 它死了它們也死了」。第二句
(它死了它們也死了) 是對的, 但第一句 (podman 對自己狀態的記錄可信) 量測為假。實測
(`docker compose restart podenv` 之後): `podman ps` 回報租約 `Up`、記錄的 pid 在 `/proc`
裡已不存在、租約 port 上什麼都沒 listen、從 paperclip curl 回 `000`。`podman ps --sync`
不會修正這個回報 (量測: 跑完仍然 `Up`)。對著這個狀態跑 `podman start <c>` 印出容器名、
exit 0, 但容器仍是死的 —— 是三個候選補救裡**唯一靜默失敗**的一個, 而它正是這支腳本原本
唯一的機制。`podman restart -t 0 <c>` 反而是唯一會**大聲**失敗的候選: `Error: container
<id> conmon exited prematurely, exit code could not be retrieved: conmon process killed`。
唯一測出來會動的順序是 `podman stop -t 0 <c>` 再 `podman start <c>` —— 會印同一句 conmon
錯誤 (可忽略, 因為隨後的 `start` 仍會成功), 但容器真的活過來, curl 拿回 200。

對這個落差的推測 (未證實, 標記為假說而非結論): `docker compose restart` 保留容器自己的
可寫層, 而 podman 在 rootless runtime 用的 `/run/user/<uid>` 狀態就落在那個可寫層裡
(不是獨立 mount —— `/proc/mounts` 量過, 底下沒有專屬的 tmpfs), 於是那份「以為還活著」的
狀態在 restart 後續存下來, podman 因此誤信舊 instance 沒死；`--force-recreate` 會建全新
可寫層, 那份狀態不在了, podman 才正確回報 `exited`, 這也是為什麼單純 `start` 在
`--force-recreate` 後「看起來」有效 —— 但這支腳本不能假設自己被哪條路徑帶起來, 所以無論
如何都不信任記錄的狀態: 一律先逼一次真正的狀態轉換, 再 probe 確認活著, 才算 restore 完成。

**但 `--restart=always` 沒用**: podman 的 restart policy 需要 podman 活著才生效, 而每次開機
是一個新的 service 行程。所以 label + 顯式 `start` 是機制, 不是保險。

## 錯誤處理

立場與 devenv 一致: **問題要在用到資源時炸, 不是在開機時。**

1. **paperclip 不 `depends_on` podenv, 一條邊都沒有。** 這是不變量 8 的教訓: `hermes` 用
   `service_completed_successfully` 等 `devenv-expert-leases`, 結果 one-shot 任何非零 exit
   都會讓整個 agent runtime 起不來。podenv 壞掉只該讓 podenv 壞掉。
2. **exit 4 要講對的話。** 檢測分三種各講各的: socket 不存在 / 存在但連不上 (permission) /
   連上但 self-test 失敗。並附上 entrypoint 寫下的診斷字串 (見下)。
3. **開機自我檢測 + 診斷檔。** entrypoint 跑 `podman info` 與一次不需要網路的
   `podman unshare true`, 失敗就印 WARNING **並把診斷寫進 socket volume 的一個檔**, 讓 CLI
   讀出來 —— 人看到的是一句話, 而不是一層巢狀的 podman 錯誤。**絕不擋 `up`。**
4. **不提供做不到的旋鈕。** 沒有 `--memory`; 磁碟只有可觀測性。

## 可移植性 (別人的機器)

量測 §1–§7 的前置條件是**這台機器的性質, 不是這個 repo 能保證的性質**:

| 需要 | 這台 | 缺了會怎樣 |
|---|---|---|
| unprivileged userns | `=1` | podman 完全不能動 |
| cgroup v2 | 是 | podman 不能動 |
| 原生 rootless overlay (kernel 5.11+) | 7.2 | 退回 vfs (慢且吃磁碟) 或需要 `/dev/fuse` |
| `/dev/net/tun` | 有 | pasta 不可用, 只剩 `--netns host` |
| 無 AppArmor | 是 | 需要額外 `apparmor=unconfined` |
| 無 docker userns-remap | 是 | nested subuid 映射要重新設計 |

處理方式照不變量 8 的立場: **開機自我檢測、印 WARNING、寫診斷檔、絕不擋 `up`。**

## 測試

`tests/podenv.sh`, 結構 + live 各半。

**結構** (靜態, 不需要 stack 在跑):

- podenv service 不掛 `opc-keys`、不掛任何 hermes home、不掛 gh/claude cred volume
- 沒有 `privileged`
- `security_opt` 恰好只有 `seccomp=unconfined`
- `devices` 恰好只有 `/dev/net/tun`
- compose 的 `ports:` range 與 CLI 的 `PODENV_PORT_BASE`/`COUNT` 一致, 且 base < 32768
- paperclip 的 `id -u node` == podenv 的 runtime uid

**live**:

- 從 paperclip 跑得動 `podman info` (uid 對齊的 socket 存取真的成立)
- provision 一個真的容器, 從 paperclip 用 docker DNS 連上
- 重啟 podenv service 後 lease 容器自己回來
- `release` 真的清乾淨 (容器 + volume + 登記 row)
- **(b) 保留變數名的拒絕**真的拒絕
- **(c) 路由 gate 的拒絕**真的拒絕 —— 這條可以用 `redis:5` 免費測到 (redis 是 devenv 提供
  的家族, 所以必須被拒並指向 `devenv provision --with valkey`)
- `mem_limit` 真的生效: 讀 **podenv 容器自己的** `/sys/fs/cgroup/memory.max`。量測確認外層
  docker 的 `mem_limit` 就以這個檔呈現在容器內 (`--memory 128m` → `134217728`)。
  **不要讀 nested 容器的那一份** —— 量測 §4 已證明它永遠是 `max` (沒有 delegation), 對著它
  斷言會讓一條測試在錯的地方變綠

happy path 用 `traefik/whoami` (6MB, 秒起)。真正的 `mysql:5.7` 走 `SETUP.md` 的實例說明,
**不放進 gate** —— 400MB + 慢 init 會讓一條每次都跑的 gate 變成沒人想跑的 gate。

`tests/fresh-install.sh` 要把 podenv 的發佈 range 一起 +1000。

## 延後 / 未決

- **更窄的 seccomp profile。** 現在是 `unconfined`。原則上可以 vendor moby 的
  `default.json` 再只放行帶 `CLONE_NEWUSER` 的 `clone`/`clone3`, 放寬面會小得多。沒做, 因為
  那份 profile 會隨 docker 版本過期, 而**這個容器什麼都沒掛**, 邊界本來就宣告在外層 docker
  容器上。若日後 podenv 要掛任何敏感東西, 這一項要重新評估。
- **`docker compose` 支援。** socket 已經說 Docker API, 加 client 即可, 不用改架構。
- **給 hermes 專家 podenv。** 兩條路與各自的未量測項見「為什麼不發給 hermes 專家」。
- **磁碟壓力通知。** 現在只有 `podenv_usage` 的數字, 沒有任何主動告知。與 devenv 的
  「延後: 自動回收與通知」同一個立場。
