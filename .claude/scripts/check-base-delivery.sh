#!/usr/bin/env bash
# log-allow:script -- emits data-product output (an audit report read by a human and grepped by release verification) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# check-base-delivery.sh -- audit whether the files `.base` installs into a
# consumer actually ARRIVED there, per repo, across the whole roster.
#
# WHY THIS IS NOT check-template-versions.sh. That script answers "which
# release is this repo pinned to" by fetching `.base/.version`, and it is
# run inside release verification and `/batch-base-upgrade --expect`, where
# it must stay one cheap request per repo. This asks a different question --
# "did that release's files land" -- with a different probe (one repository
# tree read per repo), a different denominator (repos that carry `.base`,
# discovered rather than declared) and a different verdict. Folding it into
# a script whose name says "versions" would make every release check pay for
# an audit it did not ask for, and would leave the two questions sharing one
# exit status. The reuse that matters is the roster, and both read it
# through the same lib/roster.sh call.
#
# WHY THE QUESTION EXISTS. Every file init.sh writes into a consumer arrives
# only when init.sh runs, and init.sh runs only as the resync step of an
# upgrade. A repo that cannot upgrade therefore carries none of them, and
# the version marker still reads clean. The base-version monitor workflow
# (#777 / PR #778) is the worked example: written by init.sh since it
# merged, present in zero repos, reported by nothing until someone asked.
#
# WHERE THE EXPECTED LIST COMES FROM. `base`'s own init.sh, via
# `--list-installed-paths`. A copy kept here would decay the first time
# init.sh learned to install one more file -- which is the same failure this
# script exists to catch, one layer up. Deriving it means a base release
# that installs something new is audited for it with no edit here.
#
# Usage:
#   check-base-delivery.sh [options]
#
# Options:
#   --scope <active|parked|all>  Roster fanout scope (default: all rows).
#                          `.base`-carrying repos are discovered from the
#                          probe, not from this column, so `all` is the
#                          honest default and a stale column shows up as a
#                          disagreement rather than a silent skip.
#   --only <r1,r2,...>     Limit to these repos. A roster path
#                          (app/realsense_ros2) or a bare name both work.
#   --skip <r1,r2,...>     Exclude these repos, same spelling rules.
#   --manifest <file>      Read the expected paths from <file> (one per
#                          line) instead of asking base's init.sh. For
#                          auditing against a release other than the one
#                          the local checkout is on.
#   --list-repos           Print the effective repo list and exit, probing
#                          nothing (the shared roster call, for comparing
#                          scopes against batch-base-upgrade.sh).
#   -h, --help             Show this help
#
# Environment:
#   BASE_CHECKOUT     Path to the base checkout (default: the workspace
#                     sibling `base` beside this repo).
#   BASE_INIT         The command asked for the expected manifest
#                     (default: ${BASE_CHECKOUT}/dist/script/base/init.sh).
#                     Called with --list-installed-paths.
#   DELIVERY_PROBE    The command asked what a repo contains. Called with
#                     one argument, the repo name; must print one
#                     repo-relative path per line and exit 0, or exit
#                     non-zero for "could not read this repo". Default: a
#                     `gh api` read of the repository tree at main.
#
# Output, in the order that matters:
#   1. what was audited (manifest size, roster scope, consumers found)
#   2. ADOPTION GAPS -- per installed file, how many consumers LACK it,
#      worst first. This is the line that has to be unmissable.
#   3. PER REPO -- version, missing count, and the missing paths
#   4. VERDICT -- one greppable sentence naming the worst gap
#
# Exit:
#   0 = every consumer in scope carries every installed path
#   1 = at least one consumer is missing a path, or could not be read
#   2 = arg error, empty selection, or the manifest could not be obtained
#       (an audit that checked nothing is a failed audit, not a clean one)

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/roster.sh disable=SC1091
source "${SCRIPT_DIR}/lib/roster.sh"

readonly ORG="ycpss91255-docker"
readonly VERSION_MARKER=".base/.version"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() {
  printf '[check-delivery] ERROR: %s\n' "$*" >&2
}

# _default_base_init -- base's init.sh in the sibling checkout. The roster
# records base's path as `-` (nothing here iterates base BY path), so the
# workspace layout is the only thing that can answer where it is.
_default_base_init() {
  local _workspace="${SCRIPT_DIR%/.claude/scripts}"
  _workspace="$(cd -- "${_workspace}/.." &> /dev/null && pwd)"
  printf '%s\n' "${BASE_CHECKOUT:-${_workspace}/base}/dist/script/base/init.sh"
}

# _gh_probe <repo> -- every path in <repo>'s default-branch tree.
#
# One request per repo rather than one per expected path, and `truncated`
# is a hard failure rather than a shrug: a partial tree makes present files
# look missing, which is precisely the wrong direction for an audit whose
# whole output is a missing-file count.
_gh_probe() {
  local _repo="$1" _json
  _json="$(gh api "repos/${ORG}/${_repo}/git/trees/main?recursive=1" 2>/dev/null)" \
    || return 1
  [[ -n "${_json}" ]] || return 1
  if [[ "$(jq -r '.truncated' <<< "${_json}")" == "true" ]]; then
    err "${_repo}: the tree read came back truncated -- refusing to report counts from a partial listing"
    return 1
  fi
  jq -r '.tree[].path' <<< "${_json}"
}

# _load_manifest <outfile> <manifest_file> -- the expected paths, either
# from an explicit file or from base's init.sh.
#
# An empty manifest aborts. Zero expected paths means every repo has
# everything it was supposed to get, reported cheerfully, for the rest of
# time -- the failure mode of a check that structurally cannot fail.
_load_manifest() {
  local _out="$1" _file="$2" _init

  if [[ -n "${_file}" ]]; then
    [[ -r "${_file}" ]] || { err "manifest file not readable: ${_file}"; return 2; }
    grep -v '^[[:space:]]*$' "${_file}" | LC_ALL=C sort -u > "${_out}" || true
  else
    _init="${BASE_INIT:-$(_default_base_init)}"
    [[ -x "${_init}" ]] || {
      err "cannot run the manifest command: ${_init} (set BASE_CHECKOUT, BASE_INIT or --manifest)"
      return 2
    }
    "${_init}" --list-installed-paths 2>/dev/null \
      | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u > "${_out}" || true
  fi

  if [[ ! -s "${_out}" ]]; then
    err "the expected-path manifest came back empty -- an audit over no paths passes every repo"
    return 2
  fi
}

# _select_repos <skip_csv> <only_csv> <scope> -- the effective repo list,
# one name per line. `--only` / `--skip` accept a roster path or a bare
# name; the basename is what both are compared on, because the probe
# addresses repos by name and a caller pasting from either roster column
# should not have to know that.
_select_repos() {
  local _skip_csv="$1" _only_csv="$2" _scope="$3"
  local -a _repos=()
  local _r

  if [[ -n "${_only_csv}" ]]; then
    local -a _wanted=()
    IFS=',' read -ra _wanted <<< "${_only_csv}"
    local _w
    for _w in "${_wanted[@]}"; do
      _repos+=("${_w##*/}")
    done
  else
    mapfile -t _repos < <(roster_fanout_repos "${_scope}")
  fi

  if [[ -n "${_skip_csv}" ]]; then
    local _skip_set=" ${_skip_csv//,/ } "
    _skip_set="${_skip_set// \// }"
    local -a _kept=()
    for _r in "${_repos[@]}"; do
      [[ "${_skip_set}" == *" ${_r} "* ]] && continue
      _kept+=("${_r}")
    done
    _repos=("${_kept[@]+"${_kept[@]}"}")
  fi

  printf '%s\n' "${_repos[@]+"${_repos[@]}"}"
}

main() {
  local _only_csv="" _skip_csv="" _scope="all" _manifest_file="" _list_only=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --only) _only_csv="${2:?--only requires a value}"; shift 2 ;;
      --skip) _skip_csv="${2:?--skip requires a value}"; shift 2 ;;
      --scope) _scope="${2:?--scope requires a value}"; shift 2 ;;
      --manifest) _manifest_file="${2:?--manifest requires a value}"; shift 2 ;;
      --list-repos) _list_only=1; shift ;;
      *) err "unknown arg: $1"; usage; exit 2 ;;
    esac
  done

  case "${_scope}" in
    active|parked|all) ;;
    *) err "unknown --scope: ${_scope} (active|parked|all)"; exit 2 ;;
  esac

  local -a _repos=()
  mapfile -t _repos < <(_select_repos "${_skip_csv}" "${_only_csv}" "${_scope}")
  local -a _pruned=()
  local _r
  for _r in "${_repos[@]+"${_repos[@]}"}"; do
    [[ -n "${_r}" ]] && _pruned+=("${_r}")
  done
  _repos=("${_pruned[@]+"${_pruned[@]}"}")

  # An audit over nothing reports no gaps, and would do so forever.
  if (( ${#_repos[@]} == 0 )); then
    err "no repos selected -- nothing to audit (roster: $(roster_file))"
    exit 2
  fi

  if (( _list_only )); then
    printf '%s\n' "${_repos[@]}"
    return 0
  fi

  local _tmp
  _tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${_tmp}'" EXIT

  local _manifest="${_tmp}/manifest"
  _load_manifest "${_manifest}" "${_manifest_file}" || exit 2

  local -a _expected=()
  mapfile -t _expected < "${_manifest}"

  local _probe="${DELIVERY_PROBE:-}"
  local _rows="${_tmp}/rows"        # repo<TAB>state<TAB>version<TAB>missing-csv
  local _gaps="${_tmp}/gaps"        # one line per (repo, missing path)
  : > "${_rows}"
  : > "${_gaps}"

  local _consumers=0 _unreadable=0 _incomplete=0
  local _tree="${_tmp}/tree"
  for _r in "${_repos[@]}"; do
    # A probe's stderr is NOT swallowed. The default probe explains a
    # truncated tree read there, and that explanation is the difference
    # between "this repo is unreadable" and "this report's counts are
    # wrong" -- the reader has to be told which.
    if [[ -n "${_probe}" ]]; then
      "${_probe}" "${_r}" > "${_tree}" || { : > "${_tree}"; _probe_rc=1; }
    else
      _gh_probe "${_r}" > "${_tree}" || { : > "${_tree}"; _probe_rc=1; }
    fi
    if [[ -n "${_probe_rc:-}" ]]; then
      unset _probe_rc
      printf '%s\tUNREADABLE\t-\t-\n' "${_r}" >> "${_rows}"
      (( ++_unreadable ))
      continue
    fi

    if ! grep -qxF "${VERSION_MARKER}" "${_tree}"; then
      printf '%s\tNO-BASE\t-\t-\n' "${_r}" >> "${_rows}"
      continue
    fi

    (( ++_consumers ))
    local -a _missing=()
    local _p
    for _p in "${_expected[@]}"; do
      grep -qxF "${_p}" "${_tree}" && continue
      _missing+=("${_p}")
      printf '%s\n' "${_p}" >> "${_gaps}"
    done

    local _joined="-"
    if (( ${#_missing[@]} > 0 )); then
      _joined="$(printf '%s,' "${_missing[@]}")"
      _joined="${_joined%,}"
      (( ++_incomplete ))
    fi
    printf '%s\tCONSUMER\t%s\t%s\n' "${_r}" "$(_pinned_version "${_r}")" "${_joined}" >> "${_rows}"
  done

  _report "${_manifest}" "${_rows}" "${_gaps}" \
    "${#_repos[@]}" "${_consumers}" "${_incomplete}" "${_unreadable}" \
    "${#_expected[@]}"

  if (( _incomplete > 0 || _unreadable > 0 )); then
    exit 1
  fi
}

# _pinned_version <repo> -- the release the repo's subtree claims. Read
# through the same probe seam so the audit stays offline-testable; a probe
# that only lists paths (the default tree read does) cannot answer it, and
# an unknown version is not a delivery failure.
_pinned_version() {
  local _repo="$1"
  if [[ -n "${DELIVERY_VERSION_PROBE:-}" ]]; then
    "${DELIVERY_VERSION_PROBE}" "${_repo}" 2>/dev/null || printf 'unknown'
    return 0
  fi
  curl -fsSL --max-time 10 \
    "https://raw.githubusercontent.com/${ORG}/${_repo}/main/${VERSION_MARKER}" \
    2>/dev/null || printf 'unknown'
}

# _report -- the whole data product. Ordered so the number that matters is
# read first: a per-repo table alone is something a human scans and gives
# up on, and "every repo is missing the monitor" has to survive that.
_report() {
  local _manifest="$1" _rows="$2" _gaps="$3"
  local _n_repos="$4" _n_consumers="$5" _n_incomplete="$6" _n_unreadable="$7"
  local _n_paths="$8"

  printf 'Base delivery audit -- %s\n' "${ORG}"
  printf '  manifest : %s paths init.sh installs into a consumer\n' "${_n_paths}"
  printf '  scope    : %s roster repos, %s carrying .base' \
    "${_n_repos}" "${_n_consumers}"
  if (( _n_unreadable > 0 )); then
    printf ', %s UNREADABLE' "${_n_unreadable}"
  fi
  printf '\n\n'

  printf 'ADOPTION GAPS -- how many of the %s .base repos LACK each file\n' \
    "${_n_consumers}"
  if [[ -s "${_gaps}" ]]; then
    LC_ALL=C sort "${_gaps}" | uniq -c | sort -rn \
      | while read -r _count _path; do
        printf '  %s of %s  %s\n' "${_count}" "${_n_consumers}" "${_path}"
      done
    local _clean
    _clean=$(( _n_paths - $(LC_ALL=C sort -u "${_gaps}" | wc -l) ))
    printf '  (%s of %s paths present in every .base repo)\n' \
      "${_clean}" "${_n_paths}"
  else
    printf '  none -- every .base repo carries all %s paths\n' "${_n_paths}"
  fi
  printf '\n'

  printf 'PER REPO\n'
  local _repo _state _ver _missing
  while IFS=$'\t' read -r _repo _state _ver _missing; do
    case "${_state}" in
      NO-BASE)
        printf '  %-24s %-12s no .base subtree -- not a consumer\n' \
          "${_repo}" "-"
        ;;
      UNREADABLE)
        printf '  %-24s %-12s UNREADABLE -- the probe could not read this repo\n' \
          "${_repo}" "-"
        ;;
      *)
        if [[ "${_missing}" == "-" ]]; then
          printf '  %-24s %-12s complete\n' "${_repo}" "${_ver}"
        else
          printf '  %-24s %-12s missing %s: %s\n' "${_repo}" "${_ver}" \
            "$(tr ',' '\n' <<< "${_missing}" | wc -l)" "${_missing}"
        fi
        ;;
    esac
  done < "${_rows}"
  printf '\n'

  if (( _n_incomplete == 0 && _n_unreadable == 0 )); then
    printf 'VERDICT: all %s .base repos carry every one of the %s installed paths.\n' \
      "${_n_consumers}" "${_n_paths}"
    return 0
  fi

  local _worst_line _worst_count _worst_path
  _worst_line="$(LC_ALL=C sort "${_gaps}" | uniq -c | sort -rn | head -1)"
  _worst_count="$(awk '{print $1}' <<< "${_worst_line}")"
  _worst_path="$(awk '{print $2}' <<< "${_worst_line}")"

  printf 'VERDICT: %s of %s .base repos are missing at least one installed file' \
    "${_n_incomplete}" "${_n_consumers}"
  if [[ -n "${_worst_path}" ]]; then
    printf '; the worst gap is %s (%s of %s)' \
      "${_worst_path}" "${_worst_count}" "${_n_consumers}"
  fi
  printf '.\n'
  if (( _n_unreadable > 0 )); then
    printf '         %s repo(s) could not be read at all and are counted as neither.\n' \
      "${_n_unreadable}"
  fi
}

main "$@"
