---
name: .base subtree 升級走 CI-runner wrapper 才會自動跑 init.sh
description: 升級 .base subtree 後 root symlinks 必須由 init.sh 重整; CI-runner wrapper（just 優先）自動跑, raw subtree pull / .base/upgrade.sh 會跳過 (但 enforce_wrapper_first_upgrade.sh hook BLOCK)
type: feedback
originSessionId: 21206d57-34a2-4c93-91d9-123d82ae07b1
---
升級 consumer repo 的 `.base` subtree 後,**必須執行 `./.base/init.sh`** 重新建立 root 層的 symlinks(`build.sh` / `run.sh` / `exec.sh` / `stop.sh` / `Makefile`),否則 symlinks 仍指向升級前的路徑。

**現代正確流程:** 走 CI-runner wrapper(just 優先,hook 依 repo 偵測):下游 `just upgrade [vX.Y.Z]`、base self `just -f justfile.ci upgrade [vX.Y.Z]`、legacy 過渡 `make -f Makefile.ci upgrade [VERSION=vX.Y.Z]` -- wrapper 內部自動跑 init.sh resync + `main.yaml @tag` sed。**`enforce_wrapper_first_upgrade.sh` hook BLOCK** 三個 surface (raw `./.base/upgrade.sh` / legacy `./template/upgrade.sh` / `git subtree pull --prefix=.base|template`),迫使走 wrapper (checkpoint protocol 可 lift,refs ADR-00000002 / #117 / #120 / #139 / base#573 / #202)。

**Why:** 2026-04-09 批次升級 17 repos 到 v0.7.1 時,subagent 用 raw `git subtree pull` 跳過 init.sh,結果 4 個 agent repos 的 symlinks 仍指向 v0.5.0 layout (`template/build.sh`),但檔案實際在 `template/script/docker/build.sh`。CI 在 Dockerfile 的 `COPY *.sh /lint/` 階段炸:`"/build.sh": not found`。Hook 後來加進來把這個 footgun 變成 BLOCK。

**How to apply:**

- 永遠走 CI-runner wrapper(`just upgrade` / `just -f justfile.ci upgrade`,過渡期 `make -f Makefile.ci upgrade` 仍接受),不要直接跑 `./.base/upgrade.sh` 或 raw subtree pull(hook 會擋)。批次升級走 `/batch-base-upgrade` slash command。
- 驗證:`ls -la build.sh` 應指向 `.base/script/docker/build.sh`。
- 版本追蹤檔: `.base/.version` (root `.template_version` 自 v0.16.0 移除)。
- 相關: [[feedback_wrapper_first_upgrade]] -- wrapper-first(just 優先)的擴展 rationale 與 fallback 細節。
