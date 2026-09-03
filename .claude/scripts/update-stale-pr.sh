#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# update-stale-pr.sh -- one-shot merge-update + NORMAL push for a PR whose
# base branch has moved (mergeStateStatus: BEHIND / CONFLICTING). git
# rebase is disallowed org-wide (refs #221): the branch is refreshed by
# merging the base branch into it and pushing normally -- never rebase,
# never force.
#
# Usage:
#   update-stale-pr.sh <pr> [--repo OWNER/REPO] [--worktree PATH] [--dry-run]
#
# Flow:
#   1. Resolve PR head + base via `gh pr view <pr> --json
#      headRefName,baseRefName`.
#   2. Locate worktree (--worktree wins; else scan
#      ${WORKSPACE_DIR:-pwd}/worktree/* for a checkout on head branch).
#   3. `git -C <wt> fetch origin <base>` then
#      `git -C <wt> merge origin/<base>` into the PR branch.
#   4. On conflict: classify every hunk. If EVERY hunk in EVERY conflicted
#      file is REGENERATED (the two sides identical once digit runs are
#      masked) and every conflicted file is in the generator's own
#      `--list-outputs` set, drop the markers, re-run the generator, stage
#      and commit -- the landed figure is recomputed from the merged tree,
#      not chosen from either side (refs #287). Anything else: print
#      conflicted files + suggested next steps, exit 2, tree untouched.
#   5. `git -C <wt> push` -- a NORMAL push (no --force, no rebase).
#   6. Print fresh `wait-pr-ci.sh` command to re-arm Monitor.
#
# Exit:
#   0  merged + pushed (or --dry-run preview)
#   1  fetch / merge failed for a non-conflict reason, or push failed
#   2  merge conflict, manual resolution needed
#   3  pre-condition failure (PR not found, worktree not found)
#
# Refs: issue ycpss91255-docker/docker_harness#221 (supersedes the
#       rebase+force-push flow of #87).

set -uo pipefail

_RP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
# shellcheck source=lib/log.sh disable=SC1091
source "${_RP_SCRIPT_DIR}/lib/log.sh"

usage() {
  cat >&2 <<'EOF'
Usage: update-stale-pr.sh <pr> [options]

Positional:
  <pr>                  PR number to update.

Options:
  --repo OWNER/REPO     Override gh repo (default: gh resolve from cwd).
  --worktree PATH       Override worktree path (default: scan
                        ${WORKSPACE_DIR:-pwd}/worktree/* for the head
                        branch).
  --dry-run             Print planned actions; no fetch/merge/push.
  -h, --help            Show this help.

Mechanism:
  Merges origin/<base> into the PR branch and pushes NORMALLY. git rebase
  and force-push are disallowed org-wide (refs #221).

  Conflicts are auto-resolved for exactly one class and nothing else: a
  hunk whose two sides are identical once every digit run is masked, in a
  file the repo's own doc generator names via --list-outputs. Those are
  resolved, regenerated and committed; every other conflict still exits 2
  with the merge untouched (refs #287).

Environment:
  STALE_PR_REGENERATOR  Worktree-relative path of the doc generator
                        (default .claude/scripts/sync-doc-test-counts.sh).

Exit codes:
  0  success / dry-run preview
  1  fetch or merge failure (non-conflict), or push failure
  2  merge hit conflicts, manual fix required
  3  pre-condition failure (PR / worktree not found)

Refs: issue #221.
EOF
}

err() { printf '%s\n' "$*" >&2; }

# locate_worktree <head_branch>
# Echoes the absolute path of a worktree whose current branch matches
# <head_branch>. Searches ${WORKSPACE_DIR:-${PWD}}/worktree/*. Empty
# echo if none / ambiguous (caller treats both as failure).
locate_worktree() {
  local head="$1"
  local workspace="${WORKSPACE_DIR:-${PWD}}"
  local root="${workspace}/worktree"
  [[ -d "${root}" ]] || return 0

  local matches=()
  local dir branch
  for dir in "${root}"/*; do
    [[ -d "${dir}/.git" || -f "${dir}/.git" ]] || continue
    branch="$(git -C "${dir}" branch --show-current 2>/dev/null || true)"
    [[ "${branch}" == "${head}" ]] && matches+=("${dir}")
  done

  if (( ${#matches[@]} == 1 )); then
    printf '%s\n' "${matches[0]}"
  fi
}

# ── Regenerated-conflict auto-resolution (refs #287) ────────────────
#
# Landing N branches against `strict` branch protection means every branch
# merges the base into itself first, and one conflict shape recurs on every
# single one of them: the DERIVED figures in the doc/test catalogs. Both
# sides added tests, so both rewrote the same total, and NEITHER number is
# right after the merge -- the right one is what the generator computes from
# the merged tree. Hand-resolving that is not judgement, it is typing, and
# the two times it was done with `--ours` / `--theirs` on the whole file it
# swallowed hand-written prose from an adjacent hunk.
#
# So exactly one class is automated and nothing else:
#
#   REGENERATED  the two sides are identical once every digit run is masked.
#                Either side may be kept, because the value is about to be
#                overwritten by the generator.
#
# Everything else -- prose, a hunk that only LOOKS numeric in a file the
# generator does not write, markers that do not parse -- is a real conflict
# and still exits 2 with the untouched merge in place. The rule is
# all-or-nothing across every conflicted file: a tree with one real conflict
# gets nothing auto-resolved, so a reviewer never has to work out which
# hunks a tool touched and which it left.

# Where the generator lives, relative to the worktree root. Override with
# STALE_PR_REGENERATOR for a repo that keeps its generator elsewhere.
readonly _RP_DEFAULT_REGENERATOR='.claude/scripts/sync-doc-test-counts.sh'

# _rp_regenerator <worktree> -- absolute path of the generator, or nothing.
_rp_regenerator() {
  local _wt="$1" _rel="${STALE_PR_REGENERATOR:-${_RP_DEFAULT_REGENERATOR}}"
  [[ -x "${_wt}/${_rel}" ]] && printf '%s\n' "${_wt}/${_rel}"
  return 0
}

# _rp_owned_paths <worktree> -- root-relative paths the generator writes,
# ASKED OF THE GENERATOR (`--list-outputs`), never a list kept here. A
# second copy of that answer is the failure this guard exists to prevent:
# the moment it disagrees, the script auto-resolves a file whose contents
# nobody is going to recompute, and takes one side of a real edit.
# Non-zero when there is no generator, or when it is too old to answer.
_rp_owned_paths() {
  local _gen
  _gen="$(_rp_regenerator "$1")"
  [[ -n "${_gen}" ]] || return 1
  "${_gen}" --list-outputs "$1" 2>/dev/null
}

# _rp_mask <text> -- collapse every digit RUN to a single '#'. Two sides
# equal after this differ in nothing but numbers. Runs collapse rather than
# digits mapping one-to-one so that 999 -> 1000 still masks equal; a count
# crossing a power of ten is the same drift as any other.
_rp_mask() {
  local _s="$1" _out='' _ch _i _run=0
  for (( _i = 0; _i < ${#_s}; _i++ )); do
    _ch="${_s:_i:1}"
    if [[ "${_ch}" == [0-9] ]]; then
      (( _run )) || _out+='#'
      _run=1
    else
      _out+="${_ch}"
      _run=0
    fi
  done
  printf '%s' "${_out}"
}

# _rp_figure <side> -- the line a reader should be shown for one hunk side:
# the first line carrying a digit (the figure that drifted), else the first
# line. Both sides mask-equal, so the two figures line up.
_rp_figure() {
  local _line _first='' _seen=0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if (( ! _seen )); then _first="${_line}"; _seen=1; fi
    if [[ "${_line}" == *[0-9]* ]]; then
      printf '%s' "${_line}"
      return 0
    fi
  done <<< "$1"
  printf '%s' "${_first}"
}

# _rp_after <file> <ours-figure> -- the line the generator left where that
# figure was: the first line of <file> with the same mask. Looked up by the
# same masking the classifier used, so the "after" shown is provably the
# same slot and not a similar-looking line elsewhere.
_rp_after() {
  local _file="$1" _want _line
  _want="$(_rp_mask "$2")"
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    if [[ "$(_rp_mask "${_line}")" == "${_want}" ]]; then
      printf '%s' "${_line}"
      return 0
    fi
  done < "${_file}"
  return 1
}

# Set by _rp_scan_file, read by its caller before the next call.
_RP_HUNKS=0
_RP_REGEN=0
_RP_REAL=0
_RP_FIG_OURS=()
_RP_FIG_THEIRS=()

# _rp_close_hunk <ours> <theirs> -- classify one finished hunk.
_rp_close_hunk() {
  _RP_HUNKS=$(( _RP_HUNKS + 1 ))
  if [[ "$(_rp_mask "$1")" == "$(_rp_mask "$2")" ]]; then
    _RP_REGEN=$(( _RP_REGEN + 1 ))
    _RP_FIG_OURS+=("$(_rp_figure "$1")")
    _RP_FIG_THEIRS+=("$(_rp_figure "$2")")
  else
    _RP_REAL=$(( _RP_REAL + 1 ))
  fi
}

# _rp_scan_file <file> [resolved-out] -- walk one conflicted file's hunks.
#
# Both marker styles are handled: plain (ours / `=======` / theirs) and
# diff3 (`|||||||` base section as well). The base side is READ AND
# DISCARDED -- unlike the throwaway prototype this grew out of, which used
# it to also accept a "both added" hunk. That is a second class with a
# second correct answer (keep both sides, in order), and #287 asks for one
# class; conflict-style is a per-machine git setting, so requiring diff3
# would have made the script's behaviour depend on the operator's config.
#
# Returns 1 -- REAL, refuse -- if the markers do not parse: an unterminated
# or nested hunk, or a conflicted path with no markers at all (add/add on a
# binary, delete/modify). Refusing is always safe: the caller still holds
# the untouched conflict.
#
# With <resolved-out>, writes the marker-free content there, keeping OURS.
# Either side is correct for this class; ours keeps the merge commit's diff
# smallest.
_rp_scan_file() {
  local _file="$1" _out="${2:-}"
  local _state=0 _line _ours='' _theirs='' _buf=''
  _RP_HUNKS=0; _RP_REGEN=0; _RP_REAL=0
  _RP_FIG_OURS=(); _RP_FIG_THEIRS=()
  [[ -f "${_file}" ]] || return 1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    case "${_state}" in
      0)
        if [[ "${_line}" =~ ^\<{7}([[:space:]]|$) ]]; then
          _state=1; _ours=''; _theirs=''
          continue
        fi
        _buf+="${_line}"$'\n'
        ;;
      1)
        if [[ "${_line}" =~ ^\|{7}([[:space:]]|$) ]]; then _state=2; continue; fi
        if [[ "${_line}" =~ ^={7}$ ]]; then _state=3; continue; fi
        [[ "${_line}" =~ ^(\<{7}|\>{7})([[:space:]]|$) ]] && return 1
        _ours+="${_line}"$'\n'
        ;;
      2)
        if [[ "${_line}" =~ ^={7}$ ]]; then _state=3; continue; fi
        [[ "${_line}" =~ ^(\<{7}|\>{7})([[:space:]]|$) ]] && return 1
        ;;
      3)
        if [[ "${_line}" =~ ^\>{7}([[:space:]]|$) ]]; then
          _rp_close_hunk "${_ours}" "${_theirs}"
          _buf+="${_ours}"
          _state=0
          continue
        fi
        [[ "${_line}" =~ ^\<{7}([[:space:]]|$) || "${_line}" =~ ^={7}$ ]] && return 1
        _theirs+="${_line}"$'\n'
        ;;
    esac
  done < "${_file}"
  (( _state == 0 )) || return 1
  (( _RP_HUNKS > 0 )) || return 1
  if [[ -n "${_out}" ]]; then
    printf '%s' "${_buf}" > "${_out}" || return 1
  fi
  return 0
}

# Set by _rp_classify, read by _rp_resolve and by main's report.
_RP_PLAN=()
_RP_PLAN_HUNKS=()
_RP_OWNED=()
_RP_TOTAL_HUNKS=0
_RP_REASON=''

# _rp_classify <worktree> -- classify every conflicted file, printing one
# line each. 0 when EVERY conflicted file is owned by the generator AND
# every one of its hunks is regenerated; 1 otherwise, with _RP_REASON set to
# the first thing that disqualified the tree. Writes nothing, so --dry-run
# and the live path can share it verbatim.
_rp_classify() {
  local _wt="$1" _f _o _owned_raw _rc=0 _is_owned
  _RP_PLAN=(); _RP_PLAN_HUNKS=(); _RP_OWNED=(); _RP_TOTAL_HUNKS=0; _RP_REASON=''

  local _files=()
  mapfile -t _files < <(git -C "${_wt}" diff --name-only --diff-filter=U 2>/dev/null)
  if (( ${#_files[@]} == 0 )); then
    _RP_REASON='no conflicted files'
    return 1
  fi

  if ! _owned_raw="$(_rp_owned_paths "${_wt}")"; then
    _RP_REASON="no generator answering --list-outputs at ${_wt}/${STALE_PR_REGENERATOR:-${_RP_DEFAULT_REGENERATOR}}; nothing here can be recomputed"
    return 1
  fi
  [[ -n "${_owned_raw}" ]] && mapfile -t _RP_OWNED <<< "${_owned_raw}"

  for _f in "${_files[@]}"; do
    _is_owned=no
    for _o in "${_RP_OWNED[@]}"; do
      [[ "${_f}" == "${_o}" ]] && { _is_owned=yes; break; }
    done
    if [[ "${_is_owned}" == no ]]; then
      printf '  %s: owned=no -- not in the generator output set\n' "${_f}"
      [[ -n "${_RP_REASON}" ]] \
        || _RP_REASON="${_f} is not in the generator's output set, so its numbers are nobody's to recompute"
      _rc=1
      continue
    fi
    if ! _rp_scan_file "${_wt}/${_f}"; then
      printf '  %s: owned=yes -- conflict markers do not parse\n' "${_f}"
      [[ -n "${_RP_REASON}" ]] \
        || _RP_REASON="${_f}: conflict markers do not parse"
      _rc=1
      continue
    fi
    printf '  %s: owned=yes hunks=%d regenerated=%d real=%d\n' \
      "${_f}" "${_RP_HUNKS}" "${_RP_REGEN}" "${_RP_REAL}"
    if (( _RP_REAL > 0 )); then
      [[ -n "${_RP_REASON}" ]] \
        || _RP_REASON="${_f} has ${_RP_REAL} conflict hunk(s) that are not count drift"
      _rc=1
      continue
    fi
    _RP_PLAN+=("${_f}")
    _RP_PLAN_HUNKS+=("${_RP_HUNKS}")
    _RP_TOTAL_HUNKS=$(( _RP_TOTAL_HUNKS + _RP_HUNKS ))
  done
  return "${_rc}"
}

# _rp_resolve <worktree> -- drop the markers in every planned file, re-run
# the generator over the merged tree, stage the result, and commit the
# merge. Prints file / hunk count / before / after per hunk, so a reader can
# see the landed number is one the generator computed and not one of the two
# on offer. Returns 1 without committing if anything goes wrong.
_rp_resolve() {
  local _wt="$1" _f _gen _i _j _ri _o _t _after _tmp
  local _records=()

  for (( _i = 0; _i < ${#_RP_PLAN[@]}; _i++ )); do
    _f="${_RP_PLAN[_i]}"
    _tmp="${_wt}/${_f}.stale-pr-resolved"
    if ! _rp_scan_file "${_wt}/${_f}" "${_tmp}"; then
      rm -f "${_tmp}"
      err "re-reading ${_f} did not reproduce the classification; refusing."
      return 1
    fi
    mv -- "${_tmp}" "${_wt}/${_f}" || return 1
    for (( _j = 0; _j < ${#_RP_FIG_OURS[@]}; _j++ )); do
      _records+=("${_f}"$'\t'"${_RP_FIG_OURS[_j]}"$'\t'"${_RP_FIG_THEIRS[_j]}")
    done
  done

  _gen="$(_rp_regenerator "${_wt}")"
  if ! "${_gen}" "${_wt}"; then
    err "the generator failed on the merged tree; refusing to commit."
    return 1
  fi

  printf 'auto-resolved %d regenerated conflict hunk(s) in %d file(s):\n' \
    "${_RP_TOTAL_HUNKS}" "${#_RP_PLAN[@]}"
  _ri=0
  for (( _i = 0; _i < ${#_RP_PLAN[@]}; _i++ )); do
    printf '  %s (%d hunk(s))\n' "${_RP_PLAN[_i]}" "${_RP_PLAN_HUNKS[_i]}"
    for (( _j = 0; _j < _RP_PLAN_HUNKS[_i]; _j++ )); do
      IFS=$'\t' read -r _ _o _t <<< "${_records[_ri]}"
      _after="$(_rp_after "${_wt}/${_RP_PLAN[_i]}" "${_o}")" || _after='(not found)'
      printf '    ours  : %s\n' "${_o}"
      printf '    theirs: %s\n' "${_t}"
      printf '    after : %s   [recomputed by %s]\n' \
        "${_after}" "${STALE_PR_REGENERATOR:-${_RP_DEFAULT_REGENERATOR}}"
      _ri=$(( _ri + 1 ))
    done
  done

  # Every path still unmerged must be one this run just resolved. `git add`
  # on an unmerged path MARKS IT RESOLVED at whatever the file happens to
  # contain -- markers and all -- so staging first and checking afterwards
  # is a check that can never fire. Ask before staging, not after.
  local _u _known
  while IFS= read -r _u; do
    [[ -n "${_u}" ]] || continue
    _known=0
    for _f in "${_RP_PLAN[@]}"; do
      [[ "${_u}" == "${_f}" ]] && { _known=1; break; }
    done
    if (( ! _known )); then
      err "${_u} is still unmerged and was not auto-resolved; refusing to commit."
      return 1
    fi
  done < <(git -C "${_wt}" diff --name-only --diff-filter=U 2>/dev/null)

  # Stage the resolved conflicts AND every other file the generator owns:
  # a merge can leave an owned doc unconflicted but stale, and committing a
  # tree the generator would immediately change again is the drift this is
  # meant to end.
  local _stage=("${_RP_PLAN[@]}")
  for _o in "${_RP_OWNED[@]}"; do
    [[ -f "${_wt}/${_o}" ]] && _stage+=("${_o}")
  done
  if ! git -C "${_wt}" add -- "${_stage[@]}"; then
    err "git add failed after auto-resolution."
    return 1
  fi
  if [[ -n "$(git -C "${_wt}" diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
    err "conflicts remain after auto-resolution; refusing to commit."
    return 1
  fi
  if ! git -C "${_wt}" commit --no-edit; then
    err "committing the auto-resolved merge failed."
    return 1
  fi
  return 0
}

main() {
  local pr="" repo="" worktree="" dry_run=0
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --repo)
        [[ $# -ge 2 ]] || { err "missing value for --repo"; return 3; }
        repo="$2"; shift 2 ;;
      --repo=*) repo="${1#--repo=}"; shift ;;
      --worktree)
        [[ $# -ge 2 ]] || { err "missing value for --worktree"; return 3; }
        worktree="$2"; shift 2 ;;
      --worktree=*) worktree="${1#--worktree=}"; shift ;;
      --dry-run) dry_run=1; shift ;;
      -*) err "unknown flag: $1"; return 3 ;;
      *)
        if [[ -z "${pr}" ]]; then pr="$1"; shift
        else err "unexpected arg: $1"; return 3; fi ;;
    esac
  done

  if [[ -z "${pr}" ]]; then
    err "missing <pr>"
    usage
    return 3
  fi
  if ! [[ "${pr}" =~ ^[0-9]+$ ]]; then
    err "invalid <pr>: '${pr}' (expected positive integer)"
    return 3
  fi

  local gh_args=(pr view "${pr}" --json "headRefName,baseRefName,state")
  [[ -n "${repo}" ]] && gh_args+=(--repo "${repo}")

  local pr_json
  pr_json="$(gh "${gh_args[@]}" 2>/dev/null || true)"
  if [[ -z "${pr_json}" ]]; then
    err "PR #${pr}${repo:+ in ${repo}} not found (or gh failed)."
    return 3
  fi

  local head base state
  head="$(printf '%s' "${pr_json}" | jq -r '.headRefName // empty')"
  base="$(printf '%s' "${pr_json}" | jq -r '.baseRefName // empty')"
  state="$(printf '%s' "${pr_json}" | jq -r '.state // empty')"
  if [[ -z "${head}" || -z "${base}" ]]; then
    err "could not parse head/base from PR #${pr}: ${pr_json}"
    return 3
  fi
  if [[ "${state}" != "OPEN" ]]; then
    err "PR #${pr} is ${state}, not OPEN -- nothing to update."
    return 3
  fi

  if [[ -z "${worktree}" ]]; then
    worktree="$(locate_worktree "${head}")"
  fi
  if [[ -z "${worktree}" ]]; then
    err "no worktree found for branch '${head}'."
    err "  Searched: \${WORKSPACE_DIR:-\${PWD}}/worktree/* with branch == '${head}'."
    err "  Pass --worktree <path> to point at it explicitly."
    return 3
  fi
  if [[ ! -d "${worktree}" ]]; then
    err "worktree path does not exist: ${worktree}"
    return 3
  fi

  printf 'updating PR #%s (%s) by merging origin/%s in %s\n' \
    "${pr}" "${head}" "${base}" "${worktree}"

  if (( dry_run )); then
    printf '[dry-run] would: git -C %s fetch origin %s\n' "${worktree}" "${base}"
    printf '[dry-run] would: git -C %s merge origin/%s\n' "${worktree}" "${base}"
    printf '[dry-run] would: git -C %s push\n' "${worktree}"
    return 0
  fi

  if ! git -C "${worktree}" fetch origin "${base}" 2>&1; then
    err "git fetch origin ${base} failed."
    return 1
  fi

  if ! git -C "${worktree}" merge "origin/${base}" 2>&1; then
    if [[ -n "$(git -C "${worktree}" diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
      printf '\nmerge hit conflicts; classifying each hunk:\n'
      if _rp_classify "${worktree}"; then
        if ! _rp_resolve "${worktree}"; then
          err ""
          err "auto-resolution failed part-way; the merge is still in progress."
          err "  Inspect: git -C ${worktree} status"
          err "  Or abort: git -C ${worktree} merge --abort"
          return 2
        fi
      else
        err ""
        err "not auto-resolvable: ${_RP_REASON}"
        err ""
        err "merge hit conflicts. Conflicted files:"
        git -C "${worktree}" diff --name-only --diff-filter=U >&2
        err ""
        err "Suggested next steps (manual):"
        err "  1. cd ${worktree}"
        err "  2. Fix each conflict (typical patterns: TEST.md totals, CHANGELOG ordering)."
        err "  3. git add <fixed files>"
        err "  4. git merge --continue   # or: git commit"
        err "  5. git -C ${worktree} push   # NORMAL push, no force"
        err "  6. Re-arm Monitor:"
        err "       .claude/scripts/wait-pr-ci.sh --repo ${repo:-<OWNER/REPO>} --prs ${pr}"
        err ""
        err "Or abort: git -C ${worktree} merge --abort"
        return 2
      fi
    else
      err "git merge origin/${base} failed for a non-conflict reason."
      return 1
    fi
  fi

  if ! git -C "${worktree}" push 2>&1; then
    err "git push failed."
    err "  The remote may have moved. Run git -C ${worktree} fetch origin && re-run this script."
    return 1
  fi

  printf '\nPR #%s merge-updated + pushed. Re-arm Monitor:\n' "${pr}"
  printf '  .claude/scripts/wait-pr-ci.sh --repo %s --prs %s\n' \
    "${repo:-<OWNER/REPO>}" "${pr}"
}

main "$@"
