# upstream/ Outdated Report — Design Spec

日期: 2026-08-25
狀態: 已實作 (`scripts/outdated.sh` + `tests/outdated.sh`)

## 背景

`scripts/upgrade.sh <proj> <tag>` 要求操作者**自己知道** tag。要知道就得逐個 submodule 跑
`git ls-remote --tags`, 而四個 repo 的 tag 命名沒有一條共通規則, 於是這件事實際上沒人在做:
`AGENTS.md` 那行 pin 清單在寫下這份 spec 時已經過期 (還寫著 hermes `v2026.8.16` 與 paperclip
的 canary tag, 真實 pin 是 `v2026.8.19` 與 `v2026.817.0`)。

目標: 一個 `npm outdated` 等價物, 回答「現在 pin 在哪、上游有沒有更新的 stable tag、差幾個版」。

## 量到的事實 (2026-08-25)

| component | pin | 家族 | 家族內最新 | 差 |
|---|---|---|---|---|
| buzz | `desktop-v0.5.14` | `desktop-v<semver>` | `desktop-v0.5.18` | 4 |
| hermes | `v2026.8.19` | `v<date>` | `v2026.8.19` | — |
| paperclip | `v2026.817.0` | `v<date>.0` | `v2026.824.0` | 1 |
| tencentdb | `v2.0.0` | `v<semver>` | `v2.0.1` | 1 |

tag 空間比想像的髒, 這是整份設計的成因:

- **buzz 180 個 tag / 12 個家族**: `v*`(98)、`mobile-v*-rc.N`(22)、`desktop-v*`(16)、
  `desktop/v*-rcN`(12)、`mobile-v*`(10)、`chart-v*`、`relay-v*`、`sprout-desktop-latest`…
  跨家族比較毫無意義 —— 一個 desktop pin 不可以被「升級」成 mobile release。
- **paperclip 1293 個 tag, 其中 1118 個是 `canary/v*-canary.N`**, stable `v*` 只有 21 個,
  另有 8 個 per-package tag (`@paperclipai/server@0.3.1` 之類) 與 legacy `v0.3.x`。
- **hermes 有 4 分量的 hotfix 形狀** (`v2026.8.16.2`, `v2026.5.29.2`), 與 3 分量的常規 tag 混住。
- 四個 submodule 目前**都正好停在某個 tag 上** (`git tag --points-at HEAD` 各回一個)。

兩件會誤導人的量測:

1. **`git describe` 不能用來讀 pin。** buzz 被它報成
   `mobile-v0.11.0-rc.2-22-g391495e7d`, paperclip 被報成
   `@paperclipai/adapter-claude-local@0.3.1-2649-g213dabab4` —— 兩個都是錯的家族, 而 HEAD 其實
   正好落在 `desktop-v0.5.14` 與 `v2026.817.0`。describe 挑「最近可達的 tag」, 在多家族 repo 裡
   這個定義與「我 pin 的是哪個 release」無關。這正是本工具要防的錯誤, 所以它只用
   `git tag --points-at HEAD`。
2. **paperclip 的版號是計劃發佈日, 不是 commit 日。** `v2026.824.0` 指的 commit
   (`664052f8`) committer date 是 **2026-08-17 20:47**, 只比 `v2026.817.0` 的 commit
   (`213dabab`, 19:27) 晚 80 分鐘。所以報告裡那一欄叫 `tagged` 而不是 `released` —— 它是被
   tag 的 commit 的日期, 是唯一真的量到的東西。

## 目標 / 非目標

目標: 唯讀報告 + 可直接貼的 `scripts/upgrade.sh` 指令 + 可被 script 消費的 exit code。

非目標:

- **不升版、不 fetch tag、不改 ref/HEAD/worktree。** 升版仍然只有 `scripts/upgrade.sh` 一條路。
- **不查 stack 其他 pin** (nix 2.35.2、nixpkgs rev、RustFS、rabbitmq、`mc`、omp): 它們住在
  Dockerfile 裡, 沒有可排序的 tag namespace, 是另一個問題。
- **不做 `--json`**: 現在沒有任何消費者 (YAGNI)。

## 介面契約

```
scripts/outdated.sh [buzz|hermes|paperclip|tencentdb ...]   # 預設全部
```

component 名稱與 `upgrade.sh` 完全一致 (含 `tencentdb` → `upstream/tencentdb-agent-memory`
這個目錄名不一致), 所以建議指令可以直接複製。

exit code 沿用 npm: **0** 全部最新 / **1** 有更新可用 / **2** 報告不完整。**2 蓋過 1** ——
一份殘缺的報告絕對不可以讀起來像乾淨的。

## 演算法: stable 家族從 pin 推導

沒有 per-project 的 pattern 表 (那會是第二個要跟著 pin 一起維護的地方, 而這個 repo 已經在
`AGENTS.md` 上示範過這種東西會過期)。規則只有一條:

1. 把 pin 拆成 **literal prefix + 純數字版本**: `desktop-v` + `0.5.14`、`v` + `2026.817.0`。
   拆法是「去掉尾端那串 `[0-9.]`」, 也就是錨在最後一個非數字字元上 —— 這是 `desktop-v` 與
   `@scope/pkg@` 這種 prefix 能被完整保留的原因。拆之前先剝掉一段尾隨的 pre-release
   (`-rc.1` / `-canary.0`), 讓 pre-release pin 至少還能說出自己屬於哪個家族。
2. 候選 = 遠端 tag 中 **prefix 完全相同** 且 **純數字分量數 ≥ pin 的分量數** 者。

這一條規則同時做完三件事: 錨在數字分量上就等於排除了 `-rc.N`/`-canary.N`/`-beta.N`/
`-nightly.N`, 不需要維護後綴黑名單; literal prefix 讓 buzz 的 12 個家族互不干擾; 允許
**更多**分量讓 hermes 的 `v2026.8.16.2` 這種 hotfix 形狀仍然合格, 而不是變成看不見。
換 pin 到別的家族, 報告自己會跟過去。

排序**自己算** (逐分量數值比較, 缺的分量當 0), 不用 `sort`/collation, 也不依賴
`--sort=-v:refname`: `desktop-v0.5.9` 在字典序上大於 `desktop-v0.5.18`。整個 script 只有一份
比較器 (`VCMP_AWK`), 由 `ver_gt` 與 `family_latest` 共用。

`behind` = 家族內嚴格新於 pin 的 tag 數。這也是 paperclip 的 1118 個 canary 與 legacy
`v0.3.x` 不會污染這個數字的原因。

## 資料取得與降級

- pin: `git tag --points-at HEAD`。HEAD 上有多個 tag 時取版本最高的那個可解析者, 並在
  warning 說出用了哪個。
- 遠端 tag: 每個 submodule **一次** `git ls-remote --tags origin`。不 checkout、不寫 ref。
- `tagged` 日期: 先用本地 object (`git log -1 --format=%cs <sha>`); 本地沒有 (乾淨 clone) 才
  退到有界的 `git fetch --depth 1 --no-tags origin refs/tags/<tag>` —— 只抓那一個 tag 的
  object, 不建 ref、不動 HEAD/worktree; 再失敗就印 `?`, 該列其餘資訊照常成立。

| 情況 | 行為 | exit |
|---|---|---|
| submodule 目錄不存在 | 整列 `?` + 提示 `git submodule update --init` | 2 |
| HEAD 不在任何可解析 tag 上 | 整列 `?` + `not on a tag` | 2 |
| origin 連不上 | current 照印, 其餘 `?` + `could not list tags` | 2 |
| pin 的家族沒有 stable tag (例如 canary pin) | 其餘 `?` + `no stable tags in family` | 2 |
| 只有日期查不到 | 日期 `?`, 其餘照算 | 依實際新舊 (0/1) |
| 未知 component 參數 | usage | 2 |

任一 component 失敗**不中止**其他 component 的報告。

## hermes 的第二個 pin

hermes 被 pin 兩次: submodule, 以及 frontdoor image 自己 bake 的 checkout
(`patches/buzz/Dockerfile` 的 `git clone --depth 1 --branch <tag>`)。`upgrade.sh` 會對齊兩者,
但沒有任何東西會發現它們漂移。報告在選到 hermes 時比對這兩個 pin, 不一致就 warning + exit 2。
抽取用的是與 `upgrade.sh` 相同的 sed + 「必須恰好一個」斷言 —— 這是刻意接受的一行 regex 重複
(替代方案是共用 helper, 但那會讓一個唯讀查詢與會重建容器的 script 共命運)。

## 測試

`tests/outdated.sh` 完全離線: 在 fixture root 裡以假 `git` 跑**真的** script (與
`tests/upgrade-workflow.sh` 同一套手法), tag 宇宙來自 `$FAKE_DATA/<submodule>.tags`。釘住的東西:

- 四列表格 + summary + 建議指令 + exit 1
- pre-release (`-rc.1`/`-canary.0`/`-beta.1`/`-nightly.0`) 落選; 跨家族 (`mobile-v*`、
  `desktop/v*`、`v0.5.99`、`@paperclipai/...`) 落選; `desktop-v0.5.9 < desktop-v0.5.18`
- 4 分量 hotfix 合格但不會變成「最新」
- 全新 → exit 0; component filter 生效
- 五條降級路徑各自的訊息與 exit code (無日期 / 未 tag / 連不上 / 家族無 stable / pin 漂移)
- **唯讀性**: 呼叫紀錄裡不得出現 `checkout`; 本地已有 object 時不得出現 `fetch`

## 文件

`AGENTS.md`: 常用指令加一行、檔案地圖補 `scripts/` 與 `tests/` 兩處、把過期的 pin 清單修正並
改成「真正的 pin 問 `scripts/outdated.sh`」。
