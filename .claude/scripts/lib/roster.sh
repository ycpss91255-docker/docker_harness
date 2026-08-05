#!/usr/bin/env bash
# roster.sh -- the single reader for lib/roster.tsv, the one list of
# ycpss91255-docker repos (refs #272).
#
# Why a library rather than a copied array: the roster used to live in four
# places, and two of them disagreed about whether app/realsense_ros2 was in the
# fanout. The verifier therefore iterated 2 repos while the upgrader had opened
# PRs for 3, and `--expect` still exited 0 -- a verification step that
# structurally could not fail for the repo most likely to need it. One file,
# one reader, every consumer asks.
#
# Source, do not execute. Functions (all print one item per line):
#   roster_fanout_paths  <active|parked|all>   workspace-relative checkouts
#   roster_fanout_repos  <active|parked|all>   GitHub repo names
#   roster_mutation_paths                      generic-mutation default scope
#   roster_mutation_repos                      ditto, as repo names
#   roster_settings_repos                      sync-org-repo-settings scope
#   roster_required_check <repo>               required check ('' when none)
#   roster_file                                path to the data file
#
# The state each column encodes, and how a row earns it, is documented at the
# top of roster.tsv; this file only reads.

if [[ -n "${_DOCKER_LIB_ROSTER_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_ROSTER_SOURCED=1

readonly _ROSTER_LIB_DIR="${BASH_SOURCE[0]%/*}"
readonly _ROSTER_FILE="${ROSTER_FILE:-${_ROSTER_LIB_DIR}/roster.tsv}"

# roster_file -- print the data file path (so a consumer can name it in an
# error message instead of the reader).
roster_file() { printf '%s\n' "${_ROSTER_FILE}"; }

# _roster_select <field-num> <filter-field> <filter-value> -- print field
# <field-num> of every row whose <filter-field> equals <filter-value>, skipping
# `-` placeholders. <filter-value> `all` matches every row.
#
# Rows are emitted in file order, and the file is sorted by repo name, so every
# consumer iterates in the same deterministic order -- which is what lets two
# of them be compared for equality at all.
_roster_select() {
  local want_col="$1" filter_col="$2" filter_val="$3"
  [[ -f "${_ROSTER_FILE}" ]] || return 1
  awk -F'\t' -v want="${want_col}" -v fcol="${filter_col}" -v fval="${filter_val}" '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    (fval == "all" || $fcol == fval) && $want != "-" { print $want }
  ' "${_ROSTER_FILE}"
}

# roster_fanout_paths <active|parked|all> -- the `.base` subtree fanout scope,
# as workspace-relative checkout paths. batch-base-upgrade.sh opens the PRs
# over this; check-template-versions.sh verifies over the SAME call, which is
# the whole point of the file.
roster_fanout_paths() {
  local scope="${1:-active}"
  [[ "${scope}" == all ]] && { _roster_select 2 3 all; return; }
  _roster_select 2 3 "${scope}"
}

# roster_fanout_repos <active|parked|all> -- same set, as GitHub repo names.
roster_fanout_repos() {
  local scope="${1:-active}"
  [[ "${scope}" == all ]] && { _roster_select 1 3 all; return; }
  _roster_select 1 3 "${scope}"
}

# roster_mutation_paths -- default scope of the generic cross-repo mutation
# engine. Deliberately wider than the fanout: it includes `template`, whose
# subtree is reseeded by init.sh rather than upgraded by the fanout.
roster_mutation_paths() { _roster_select 2 4 yes; }

# roster_mutation_repos -- same set, as GitHub repo names.
roster_mutation_repos() { _roster_select 1 4 yes; }

# roster_settings_repos -- repos whose GitHub settings sync_org_repo_settings
# owns. A superset of the fanout: base, template, docker_harness, multi_run,
# .github and the adjacent tooling repos all follow the shared conventions.
roster_settings_repos() { _roster_select 1 5 yes; }

# roster_required_check <repo> -- the required status-check context on that
# repo's main, or empty when the repo deliberately requires none. Unknown repo
# -> empty output and a non-zero return, so a caller can tell "no check
# required" from "not in the roster".
roster_required_check() {
  local repo="$1" row
  [[ -f "${_ROSTER_FILE}" ]] || return 1
  row="$(awk -F'\t' -v r="${repo}" '
    /^[[:space:]]*#/ { next }
    $1 == r { print $6; found = 1; exit }
    END { if (!found) exit 1 }
  ' "${_ROSTER_FILE}")" || return 1
  [[ "${row}" == "-" ]] && return 0
  printf '%s\n' "${row}"
}
