---
name: 不要 cd 切目錄，用 -C / 相對路徑
description: Bash session cwd 持久且 Monitor 繼承，cd 後再用相對路徑會在後續 tool call 斷掉
type: feedback
originSessionId: 57c42783-dd59-4158-905a-b8d90ffa7347
---
不要 `cd` 切換工作目錄。改用 `make -C <dir>`、`git -C <dir>`、`docker build ... <context>` 之類把目錄當參數傳。能相對就相對 — 從 workspace root 用相對路徑（`.claude/scripts/...`、`.claude/test/...`）。

**Why:** Bash session cwd 在多個 tool call 間持久，Monitor 工具會繼承當下 cwd。一旦 `cd .claude/test` 跑完 make 後沒回來，下次 Monitor 用 `.claude/scripts/wait-pr-ci.sh` 就 exit 127 找不到檔案。寫絕對路徑 (`/home/yunchien/workspace/...`) 雖然會動但綁死特定機器，跨機器或路徑變動就壞。

**How to apply:**
- 預設不 `cd`，從 workspace root 操作：`just -f .claude/test/justfile check`（CI 走 `.claude/test/ci.sh check` driver）、`git -C path subcmd`
- 真的要切目錄就 inline 一條 bash：`(cd path && cmd)` 子 shell 不污染 session
- 路徑用相對（`.claude/...`）而非絕對（`/home/yunchien/...`）— 別人/別機器一樣能跑
- 已經 cd 過了，下一個 Bash 先 `cd /home/yunchien/workspace/docker` 收回來再做事
