---
name: .base subtree 升級走 CI-runner wrapper（just 優先）
description: 升級 .base subtree 一律走 CI-runner wrapper；just 優先（just upgrade / just -f justfile.ci upgrade），make -f Makefile.ci 為 legacy 過渡；raw ./.base/upgrade.sh 被 enforce_wrapper_first_upgrade.sh BLOCK 直到 checkpoint ACK
type: feedback
originSessionId: 33bd5c5e-e564-48bf-b038-bcaab5b8b2f6
---
升級 `.base` subtree 一律先走 CI-runner wrapper,只在 wrapper 不可用 / target 出問題時才退回 raw `./.base/upgrade.sh` (raw .sh / legacy `./template/upgrade.sh` / `git subtree pull --prefix=.base|template` 三個 surface 都被 `enforce_wrapper_first_upgrade.sh` hook BLOCK,須走 checkpoint protocol ack 才能放行,refs ADR-00000002 / #120 / #139 / base#573 / #202):

wrapper 由 hook 依 repo 自動偵測(優先序 justfile > justfile.ci > Makefile.ci),用對應的 canonical:

- 下游 consumer(常見):`just upgrade vX.Y.Z`(無參數=最新);檢查新版 `just upgrade-check`
- base self:`just -f justfile.ci upgrade vX.Y.Z`
- Legacy(過渡期仍接受,直到下游 .base flip 到 justfile.ci):`make -f Makefile.ci upgrade VERSION=vX.Y.Z`
- Raw fallback(被 hook 擋,需要 ACK):`./.base/upgrade.sh [vX.Y.Z]`,舊 checkout 仍可能 `./template/upgrade.sh`
- 批次跨 repo 升級:`/batch-base-upgrade`

**Why:** 使用者要求把 wrapper 設成主要入口,raw sh 留作 fallback。base#573 把 CI runner 從 `Makefile.ci` 換成 `justfile.ci`(單一 runner = just),所以 hook 從「make-only 偵測」改成 wrapper-adaptive(justfile / justfile.ci / Makefile.ci 三者按序偵測,各自導向對應 canonical),並 rename `enforce_make_first_upgrade.sh` -> `enforce_wrapper_first_upgrade.sh`(runner-neutral 命名,跨 make->just 遷移不需再改)。#120 / #139 把規則 promote 成 hook BLOCK;#202 完成 just 遷移。

**How to apply:** 跟使用者討論升級流程、寫文件範例、跑實際升級時都套這個順序(just 優先)。
範例指令、CLAUDE.md Workflows 列表、template README「Updating」章節都以 just 為主。
過渡期下游 `.base` 還是 Makefile.ci 的 repo,hook 會自動導向 make canonical,不用特別處理。
相關: [[feedback_base_subtree_upgrade]] -- init.sh 自動 resync 的細節。
