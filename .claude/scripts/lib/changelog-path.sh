#!/usr/bin/env bash
# changelog-path.sh -- the single answer to "which file is this repo's live
# changelog" (refs #307, #308).
#
# Why a library rather than a literal per caller: `doc/changelog/CHANGELOG.md`
# was written out in seven places, and `ycpss91255-docker/base`#926 then split
# the changelog into one file per `0.Y` series behind a GENERATED index. All
# seven literals changed meaning at once, in different directions -- the
# release primitive refused to promote because the index carries no
# `[Unreleased]`, the drift hook started asking commits for the one file they
# must NOT hand-edit, and two scanners exempted the generated rows while
# scanning the prose. Four copies of a walk is how one wrong path became
# seven; this is the walk, once.
#
# The rule is base's own `changelog-layout` invariant: exactly ONE file under
# `doc/changelog/` carries `## [Unreleased]`, and that file is the live one.
# Deriving it rather than naming it is what makes the same code correct on
# both layouts -- on the pre-split layout the one such file IS `CHANGELOG.md`,
# so a repo that has not split needs no configuration, and on the split layout
# it keeps working when the series rolls to v0.44 with nobody editing a
# default, a flag, or a doc. A documented `--changelog doc/changelog/v0.43.md`
# would be a value that goes stale every minor series.
#
# It fails closed. Zero matches or several are a refusal, not a guess at a
# filename: a repo whose changelog lives somewhere else should get a message
# naming what was searched and what was found, and an override, rather than a
# write into the wrong file.
#
# Source, do not execute. Functions:
#   changelog_dir           <root>   the directory the rule searches
#   changelog_files         <root>   every *.md in it, absolute, sorted
#   changelog_live_files    <root>   those carrying `## [Unreleased]`
#   changelog_live_file     <root>   THE live one, absolute (1 unless exactly one)
#   changelog_live_rel      <root>   the same path, root-relative (git / messages)
#   changelog_why_no_live_file <root>  the refusal text, one fact per line
#
# Every reader is pure: no mutation, output on stdout, non-zero and silent
# when the thing being derived is not there. The caller decides whether
# absence is fatal (release-bump.sh refuses; the advisory drift hook goes
# quiet, because a hook that cannot tell has nothing useful to say).

if [[ -n "${_DOCKER_LIB_CHANGELOG_PATH_SOURCED:-}" ]]; then
  return 0
fi
_DOCKER_LIB_CHANGELOG_PATH_SOURCED=1

# changelog_dir <root> -- print the directory the rule searches. Named by a
# function so an error message and the search can never disagree about it.
changelog_dir() {
  printf '%s\n' "${1%/}/doc/changelog"
}

# changelog_files <root> -- print every `*.md` under the changelog directory,
# absolute and in glob (sorted) order. Returns 1 when the directory is absent
# or holds no markdown.
changelog_files() {
  local dir
  dir="$(changelog_dir "$1")"
  [[ -d "${dir}" ]] || return 1

  local f found=0
  for f in "${dir}"/*.md; do
    [[ -f "${f}" ]] || continue
    printf '%s\n' "${f}"
    found=1
  done
  (( found )) || return 1
}

# changelog_live_files <root> -- print every candidate carrying the
# `## [Unreleased]` heading. Returns 1 when none does.
#
# The heading, not the filename, is the marker: it is what the release
# primitive promotes, what an entry is written into, and what base's
# `changelog-layout` lint asserts is unique.
changelog_live_files() {
  local f found=0
  while IFS= read -r f; do
    grep -q '^## \[Unreleased\]' "${f}" 2> /dev/null || continue
    printf '%s\n' "${f}"
    found=1
  done < <(changelog_files "$1")
  (( found )) || return 1
}

# changelog_live_file <root> -- print THE live changelog, absolute. Returns 1
# without printing anything unless exactly one file carries the heading:
# several means the layout is ambiguous, and picking one would be the same
# guess that put a release section in a generated index.
changelog_live_file() {
  local -a hits=()
  mapfile -t hits < <(changelog_live_files "$1")
  (( ${#hits[@]} == 1 )) || return 1
  printf '%s\n' "${hits[0]}"
}

# changelog_live_rel <root> -- the live changelog as a root-relative path,
# which is the form `git diff --cached --name-only` speaks and the form a
# message should show a reader.
changelog_live_rel() {
  local root="${1%/}" abs
  abs="$(changelog_live_file "${root}")" || return 1
  printf '%s\n' "${abs#"${root}"/}"
}

# changelog_why_no_live_file <root> -- print why the derivation refused: what
# the rule wanted, where it looked, and what it found there. One fact per
# line, no prefix and no remedy, so each caller can prefix its own log format
# and name its own override (the hooks have none to name).
#
# Always exits 0 -- it explains a refusal, it is not one.
changelog_why_no_live_file() {
  local root="${1%/}" dir
  dir="$(changelog_dir "${root}")"

  printf "wanted exactly one file carrying '## [Unreleased]' -- that is the live changelog\n"

  if [[ ! -d "${dir}" ]]; then
    printf 'searched: %s (no such directory)\n' "${dir}"
    return 0
  fi

  local -a all=() live=()
  mapfile -t all < <(changelog_files "${root}")
  mapfile -t live < <(changelog_live_files "${root}")
  printf 'searched: %s\n' "${dir}"

  if (( ${#all[@]} == 0 )); then
    printf 'found: no *.md files there\n'
    return 0
  fi

  if (( ${#live[@]} == 0 )); then
    printf 'found %d file(s), none carrying the heading:\n' "${#all[@]}"
    printf '  %s\n' "${all[@]#"${root}"/}"
    return 0
  fi

  printf 'found %d files carrying it, so which one is live is ambiguous:\n' "${#live[@]}"
  printf '  %s\n' "${live[@]#"${root}"/}"
}
