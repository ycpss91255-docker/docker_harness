#!/usr/bin/env bash
# check_readme_framework.sh - Claude Code PostToolUse hook
#
# Fires on Edit / Write / MultiEdit. When the touched file is a
# downstream repo's English README.md or a doc/README.<lang>.md
# translation, verify it conforms to the canonical framework spec
# derived from .base/README.md (the framework reference).
#
# Checks (per file):
#   [1] CI status badge present
#       (regex: actions/workflows/main.yaml/badge.svg)
#   [2] 4-language switch link present
#       (literal: **[English](README.md)**)
#   [3] No `> **TL;?DR**` blockquote (must be `## TL;DR` H2)
#   [4] No stale `.base/build.sh` symlink target
#       (must be `.base/script/docker/build.sh` since v0.1.0)
#   [5] No `.template_version` reference
#       (version pin moved to `.base/.version` since v0.16.0)
#   [6] Tests section links to TEST.md
#       (regex: \(doc/test/TEST.md\) somewhere in file)
#   [7] No stale paths in the Directory Structure tree
#       (walks the code-fence following `## Directory Structure`
#       or its zh-TW / zh-CN / ja heading, reconstructs each leaf
#       path by accumulating parent directories from indent depth,
#       and verifies the path exists in repo_root. Symlinks count
#       as existing as long as the link itself is present, even if
#       the target is broken — uses `-e || -L`.)
#
# Drift check (only when editing the English README.md, not a
# translation):
#   [drift] each translation file (zh-TW / zh-CN / ja) must (a) exist
#   and (b) contain the CI badge if the English file has it. The
#   second branch nudges fanout-pending state into view.
#
# Scope: only acts on agent/<repo>/, app/<repo>/, env/<repo>/,
# multi_run/. Skips .base/ (the framework reference itself),
# archive/, org-profile/.
#
# Non-blocking - always exit 0. Findings emitted as
# {systemMessage, hookSpecificOutput} JSON like every other check_*
# hook in this repo.

set -uo pipefail

# walk_tree_paths <readme-file>
# Parses the Directory Structure code-fence and emits one TAB-separated
# `<line_num>\t<rel_path>` per leaf path. Tree art lines without an
# identifiable leaf and ellipsis lines are skipped. The leading repo
# header line (e.g. `ros1_bridge/`) is NOT emitted; rel_path is always
# relative to the repo root. Symlink notation `foo -> target` reports
# only `foo` (the symlink name). Trailing `/` on directories is stripped.
#
# Implemented in Python rather than awk because the unicode tree
# characters (├ └ ─ │) are multi-byte UTF-8 and Alpine's awk does not
# handle multi-byte slicing reliably. Python's str.startswith works on
# code points and produces stable behaviour across image variants.
walk_tree_paths() {
  local file="$1"
  python3 - "${file}" <<'PY'
import re
import sys

HEAD_RE = re.compile(
    r"^## *(Directory Structure|目錄結構|目錄架構|"
    r"目录结构|ディレクトリ構成|ディレクトリ構造) *$"
)
# Each indent unit is exactly 4 columns: "│   " or "    ".
INDENT_UNIT_RE = re.compile(r"^(│   |    )")
LEAF_RE = re.compile(r"^(├── |└── )(.*)$")

def main(path):
    in_section = False
    in_fence = False
    parents = []  # parents[i] = directory name at indent level i

    with open(path, encoding="utf-8") as fp:
        for lineno, raw in enumerate(fp, 1):
            line = raw.rstrip("\n")

            if HEAD_RE.match(line):
                in_section = True
                in_fence = False
                continue
            if in_section and line.startswith("## "):
                in_section = False
                in_fence = False
                continue
            if not in_section:
                continue
            if line.startswith("```"):
                in_fence = not in_fence
                continue
            if not in_fence:
                continue

            # Count indent levels.
            rest = line
            level = 0
            while True:
                m = INDENT_UNIT_RE.match(rest)
                if not m:
                    break
                level += 1
                rest = rest[len(m.group(0)):]

            leaf_match = LEAF_RE.match(rest)
            if not leaf_match:
                continue
            rest = leaf_match.group(2)

            # Strip symlink target / comment / whitespace.
            if " -> " in rest:
                rest = rest.split(" -> ", 1)[0]
            rest = re.sub(r"\s+#.*$", "", rest)
            rest = rest.strip()

            if not rest or rest in ("...", ".."):
                continue
            rest = rest.rstrip("/")

            # Build full path from parents[0:level] + this leaf.
            full = "/".join(parents[:level] + [rest])

            # Update parents stack to depth `level + 1` ending with rest.
            parents = parents[:level] + [rest]

            sys.stdout.write(f"{lineno}\t{full}\n")

if __name__ == "__main__":
    main(sys.argv[1])
PY
}

is_downstream_readme() {
  local path="$1"
  case "${path}" in
    */README.md|*/doc/README.zh-TW.md|*/doc/README.zh-CN.md|*/doc/README.ja.md) ;;
    *) return 1 ;;
  esac

  local repo_root
  case "${path}" in
    */doc/README.*) repo_root="${path%/doc/README.*}" ;;
    *) repo_root="${path%/README.md}" ;;
  esac

  case "${repo_root}" in
    */template|*/archive/*|*/org-profile) return 1 ;;
  esac

  local short parent
  short="$(basename "${repo_root}")"
  parent="$(basename "$(dirname "${repo_root}")")"
  case "${parent}/${short}" in
    agent/*|app/*|env/*) ;;
    */multi_run) ;;
    *) return 1 ;;
  esac

  printf '%s' "${repo_root}"
  return 0
}

check_one() {
  local file="$1"
  local lang_label="$2"
  local prefix
  if [[ -n "${lang_label}" ]]; then
    prefix="[${lang_label}] "
  else
    prefix=""
  fi

  local findings=""
  [[ ! -f "${file}" ]] && return 0
  local contents
  contents="$(cat "${file}" 2>/dev/null || true)"

  if ! grep -q 'actions/workflows/main.yaml/badge.svg' <<< "${contents}"; then
    findings+="  ${prefix}[1] missing CI badge: expected ![CI](.../actions/workflows/main.yaml/badge.svg)"$'\n'
  fi

  if ! grep -q '\*\*\[English\](README.md)\*\*' <<< "${contents}"; then
    findings+="  ${prefix}[2] missing 4-language switch link: '**[English](README.md)** | **[繁體中文](...)** | ...'"$'\n'
  fi

  if grep -qE '^>[[:space:]]*\*\*TL;?DR\*\*' <<< "${contents}"; then
    findings+="  ${prefix}[3] TL;DR is a blockquote; framework expects '## TL;DR' H2"$'\n'
  fi

  if grep -qE '.base/build\.sh[[:space:]]+#' <<< "${contents}"; then
    findings+="  ${prefix}[4] stale path '.base/build.sh' - should be '.base/script/docker/build.sh'"$'\n'
  fi

  if grep -q '\.template_version' <<< "${contents}"; then
    findings+="  ${prefix}[5] obsolete '.template_version' reference - version pin lives in '.base/.version' since template v0.16.0"$'\n'
  fi

  if ! grep -q '(doc/test/TEST.md)' <<< "${contents}"; then
    findings+="  ${prefix}[6] missing 'See [TEST.md](doc/test/TEST.md) for details.' under '## Tests'"$'\n'
  fi

  # [7] Directory Structure tree must not list paths that do not exist
  # in repo_root. Each leaf path is reconstructed from indent depth and
  # verified via `-e` (file/dir exists) or `-L` (broken symlink). The
  # `-L` fallback keeps `build.sh -> .base/script/docker/build.sh`
  # green when the target dir is absent (e.g. when checking a fresh
  # clone before init.sh has materialized .base/).
  local line_num rel_path
  while IFS=$'\t' read -r line_num rel_path; do
    [[ -z "${rel_path}" ]] && continue
    if [[ ! -e "${repo_root}/${rel_path}" && ! -L "${repo_root}/${rel_path}" ]]; then
      findings+="  ${prefix}[7] line ${line_num}: stale path '${rel_path}' (not found in repo)"$'\n'
    fi
  done < <(walk_tree_paths "${file}")

  printf '%s' "${findings}"
}

main() {
  local input file_path repo_root
  input="$(cat)"
  file_path="$(printf '%s' "${input}" | jq -r '
    .tool_input.file_path
    // .tool_response.filePath
    // empty
  ' 2>/dev/null)"

  [[ -z "${file_path}" ]] && return 0

  repo_root="$(is_downstream_readme "${file_path}")" || return 0

  local all_findings=""
  local lang_label=""

  case "${file_path}" in
    */doc/README.zh-TW.md) lang_label="zh-TW" ;;
    */doc/README.zh-CN.md) lang_label="zh-CN" ;;
    */doc/README.ja.md) lang_label="ja" ;;
    *) lang_label="" ;;
  esac

  all_findings+="$(check_one "${file_path}" "${lang_label}")"

  if [[ -z "${lang_label}" ]]; then
    local lang trans
    for lang in zh-TW zh-CN ja; do
      trans="${repo_root}/doc/README.${lang}.md"
      if [[ ! -f "${trans}" ]]; then
        all_findings+="  [drift] missing translation: doc/README.${lang}.md"$'\n'
        continue
      fi
      if grep -q 'actions/workflows/main.yaml/badge.svg' "${file_path}" \
         && ! grep -q 'actions/workflows/main.yaml/badge.svg' "${trans}"; then
        all_findings+="  [drift] doc/README.${lang}.md has not adopted the framework yet (no CI badge while English README has one)"$'\n'
      fi
    done
  fi

  all_findings="${all_findings%$'\n'}"

  if [[ -z "${all_findings}" ]]; then
    return 0
  fi

  local msg
  msg="$(printf 'README framework drift in %s:\n%s\n\nReference: ros1_bridge PR #63 applied this framework first.' "${repo_root}" "${all_findings}")"
  jq -n --arg m "${msg}" '{
    systemMessage: $m,
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: $m
    }
  }'

  return 0
}

main "$@"
