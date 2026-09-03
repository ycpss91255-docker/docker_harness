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
#   4. On conflict: classify every hunk, then PROVE the classification.
#      Shape first -- every hunk in every conflicted file REGENERATED (the
#      two sides identical once digit runs are masked), every conflicted
#      file in the generator's own `--list-outputs` set. Then the proof:
#      resolve the tree twice in scratch copies, once keeping each side,
#      run the generator over both, and require the two results to be
#      byte-identical. Only then is the landed figure recomputed from the
#      merged tree rather than chosen (refs #287). Anything else: print
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
  --dry-run             Print planned actions; no fetch/merge/push. If a
                        merge is already in progress, classify its
                        conflicts instead and print the verdict, writing
                        nothing.
  -h, --help            Show this help.

Mechanism:
  Merges origin/<base> into the PR branch and pushes NORMALLY. git rebase
  and force-push are disallowed org-wide (refs #221).

  Conflicts are auto-resolved for exactly one class and nothing else: a
  hunk whose two sides are identical once every digit run is masked, in a
  file the repo's own doc generator names via --list-outputs, AND where
  running that generator over both resolutions produces the same tree --
  which is what makes the landed value a recomputation and not a choice.
  Those are resolved, regenerated and committed; every other conflict
  still exits 2 with the merge untouched (refs #287).

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
#   REGENERATED  the two sides are identical once every digit run is masked,
#                AND the generator lands the same tree whichever side is
#                kept. The mask is a filter, not the answer: it says the two
#                sides differ in nothing but numbers, which is equally true
#                of a hand-written line reading `refs #265` against `refs
#                #287`, or `covers 3 of the supported hosts` against 7. The
#                generator's stated contract is that a row whose test still
#                exists KEEPS ITS DESCRIPTION VERBATIM -- preserving prose is
#                the whole reason it is worth generating the catalogues -- so
#                on those lines nothing is about to be overwritten and
#                keeping a side means dropping the other side's committed
#                edit. Whether the generator writes a given line is not
#                something this script can read off the text, so it does not
#                try: it resolves the tree twice in scratch copies, once per
#                side, runs the generator over both, and requires the results
#                to be byte-identical (_rp_verify). Equal means the choice
#                could not reach the landed tree, which is exactly the claim
#                the `[recomputed by ...]` annotation makes.
#
# Everything else -- prose, a hunk that only LOOKS numeric in a file the
# generator does not write, a mask-equal hunk the generator turns out not to
# rewrite, markers that do not parse -- is a real conflict and still exits 2
# with the untouched merge in place. The rule is all-or-nothing across every
# conflicted file: a tree with one real conflict gets nothing auto-resolved,
# so a reviewer never has to work out which hunks a tool touched and which it
# left.

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
# With <resolved-out>, writes the marker-free content there, keeping <side>
# ('ours' by default, 'theirs' for the mirror run _rp_verify needs). Which
# side lands is not a free choice until _rp_verify has shown the generator
# erases the difference; ours is the default only because it keeps the merge
# commit's diff smallest.
_rp_scan_file() {
  local _file="$1" _out="${2:-}" _side="${3:-ours}"
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
          if [[ "${_side}" == theirs ]]; then _buf+="${_theirs}"; else _buf+="${_ours}"; fi
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

# _rp_classify <worktree> -- the SHAPE half of the decision: classify every
# conflicted file, printing one line each. 0 when EVERY conflicted file is
# owned by the generator AND every one of its hunks masks equal; 1
# otherwise, with _RP_REASON set to the first thing that disqualified the
# tree. Shape is necessary and not sufficient -- a hand-written line
# differing only in a digit passes it -- so a 0 here still has to survive
# _rp_verify. Writes nothing, so --dry-run and the live path share it.
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

# _rp_copy_tree <src> <dst> -- copy everything but `.git` into <dst>, which
# must exist. The scratch tree only has to be something the generator can be
# rooted at; excluding the object store keeps the copy to the working set.
_rp_copy_tree() {
  local _src="$1" _dst="$2" _e
  for _e in "${_src}"/* "${_src}"/.[!.]*; do
    [[ -e "${_e}" ]] || continue
    [[ "${_e##*/}" == '.git' ]] && continue
    cp -a -- "${_e}" "${_dst}/" || return 1
  done
  return 0
}

# _rp_tree_digest <root> -- `cksum` over every regular file, sorted. Compared
# whole it answers "are these two trees the same"; diffed, each differing
# line names a file that differs.
_rp_tree_digest() {
  local _root="$1"
  ( cd -- "${_root}" && find . -type f -exec cksum {} + | LC_ALL=C sort )
}

# _rp_verify <worktree> -- the proof behind the `[recomputed by ...]` label.
#
# Mask-equality says the two sides differ in nothing but numbers. It does
# NOT say the generator writes that line, and for a hand-written line it
# does not: the generator preserves prose verbatim on purpose. Keeping a
# side there discards the other side's committed edit under an annotation
# claiming the value was recomputed.
#
# There is no reading of the text that settles which lines the generator
# owns -- so this asks the generator instead. It resolves the planned files
# twice in two scratch copies of the merged tree, once keeping each side,
# runs the generator over both, and compares the results byte for byte.
# Identical means the kept side could not have reached the landed tree, and
# only then is the auto-resolution a recomputation. Different names the file
# where the choice would have survived, and the whole tree is refused.
#
# Nothing under <worktree> is touched, so --dry-run runs the same proof as
# the live path and the two verdicts cannot disagree.
#
# 0 when proven; 1 otherwise, with _RP_REASON set.
_rp_verify() {
  local _wt="$1" _gen _rc=0 _side _dir _f _i
  local _dirs=() _digests=() _first
  _gen="$(_rp_regenerator "${_wt}")"
  if [[ -z "${_gen}" ]]; then
    _RP_REASON='no generator to prove the resolution with'
    return 1
  fi

  for _side in ours theirs; do
    if ! _dir="$(mktemp -d)"; then
      _RP_REASON='could not create a scratch tree to prove the resolution in'
      _rc=1
      break
    fi
    _dirs+=("${_dir}")
    if ! _rp_copy_tree "${_wt}" "${_dir}"; then
      _RP_REASON='could not copy the merged tree into a scratch tree'
      _rc=1
      break
    fi
    for (( _i = 0; _i < ${#_RP_PLAN[@]}; _i++ )); do
      _f="${_RP_PLAN[_i]}"
      if ! _rp_scan_file "${_wt}/${_f}" "${_dir}/${_f}" "${_side}"; then
        _RP_REASON="re-reading ${_f} did not reproduce the classification"
        _rc=1
        break
      fi
    done
    (( _rc )) && break
    if ! "${_gen}" "${_dir}" > /dev/null 2>&1; then
      _RP_REASON="the generator failed on the ${_side}-resolved merge tree; nothing can be proven recomputed"
      _rc=1
      break
    fi
    _digests+=("$(_rp_tree_digest "${_dir}")")
  done

  if (( _rc == 0 )) && [[ "${_digests[0]}" != "${_digests[1]}" ]]; then
    _first="$(diff <(printf '%s\n' "${_digests[0]}") <(printf '%s\n' "${_digests[1]}") \
      | sed -n 's/^[<>] [0-9]* [0-9]* \.\///p' | head -n 1)"
    _RP_REASON="the generator's output depends on which side is kept (${_first:-a generated file}), so that hunk is a hand-written line the mask cannot tell from a figure -- keeping either side would drop the other side's edit"
    _rc=1
  fi

  (( ${#_dirs[@]} )) && rm -rf -- "${_dirs[@]}"
  return "${_rc}"
}

# _rp_decide <worktree> -- classify, then prove. The single answer both
# --dry-run and the live path ask for, so the flag can never advertise a
# tree the live path will refuse.
_rp_decide() {
  local _wt="$1"
  _rp_classify "${_wt}" || return 1
  if ! _rp_verify "${_wt}"; then
    printf '  proof: %s\n' "${_RP_REASON}"
    return 1
  fi
  printf '  proof: the generator lands the same tree from either side; the figures below are recomputed, not chosen\n'
  return 0
}

# _rp_resolve <worktree> -- drop the markers in every planned file, re-run
# the generator over the merged tree, stage the result, and commit the
# merge. Prints file / hunk count / before / after per hunk, so a reader can
# see the landed number is one the generator computed and not one of the two
# on offer -- a claim _rp_verify has already proven by the time this runs,
# which is why keeping OURS below is safe. Returns 1 without committing if
# anything goes wrong.
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
    if [[ -n "$(git -C "${worktree}" diff --name-only --diff-filter=U 2>/dev/null)" ]]; then
      printf '[dry-run] a merge is already in progress; classifying its conflicts:\n'
      if _rp_decide "${worktree}"; then
        printf '[dry-run] verdict: auto-resolvable -- %d regenerated hunk(s) in %d file(s)\n' \
          "${_RP_TOTAL_HUNKS}" "${#_RP_PLAN[@]}"
      else
        printf '[dry-run] verdict: manual -- %s\n' "${_RP_REASON}"
      fi
      printf '[dry-run] nothing written.\n'
      return 0
    fi
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
      if _rp_decide "${worktree}"; then
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
