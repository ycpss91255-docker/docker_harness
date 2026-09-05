#!/usr/bin/env bash
# log-allow:script -- emits data-product output (planned/applied edit summary + drift diff) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# release-bump.sh -- canonical primitive for the release BUMP, sibling to
# release-tag.sh's canonical primitive for the release TAG (refs #272).
#
# `release.md` step 2 used to be prose telling a human to make three mechanical
# edits: set `.version` to the tag, promote `## [Unreleased]` to
# `## [vX.Y.Z] - <today>`, re-insert a fresh `[Unreleased]`. It had been done
# by hand 106 times, and the evidence that a hand-run step decays is in the
# file it edits: base's Keep-a-Changelog compare-link block stopped dead at
# `[v0.6.8]` -- 16 link definitions for 106 version headings, so ~90 headings
# rendered as dangling references -- and the 16 that survived still pointed at
# `github.com/ycpss91255-docker/template`, the pre-rename URL. Nobody notices a
# missing link definition, so once the step lapsed it never came back.
#
# The link block is therefore DERIVED, never appended to: every run rebuilds
# the whole block from the heading list and the repo's own `origin` remote.
# That single property does three jobs -- it backfills a 90-heading gap in one
# command, it self-corrects a repo rename, and it makes the block impossible to
# leave behind again, because there is no incremental edit to forget.
#
# Usage:
#   release-bump.sh <vX.Y.Z> [options]     # bump + promote + relink
#   release-bump.sh --links-only [options] # relink only (backfill / repair)
#   release-bump.sh --check [options]      # report link drift, write nothing
#
# Options:
#   --repo-root <path>   Repo to edit (default: git toplevel of cwd).
#   --changelog <path>   Changelog file (default: the file under
#                        <root>/doc/changelog/ carrying `## [Unreleased]`).
#   --date <YYYY-MM-DD>  Release date for the promoted heading (default: today).
#   --slug <owner/repo>  Compare-link slug (default: derived from origin).
#   --links-only         Skip the .version / heading edits.
#   --check              Report whether the link block is up to date; write
#                        nothing. Exit 1 on drift. Implies --links-only.
#   --dry-run            Print what would change; write nothing.
#   -h, --help           Show this help.
#
# Exit:
#   0 = applied (or --check found no drift)
#   1 = refused (no [Unreleased], version already recorded, unresolvable slug)
#       or --check found drift
#   2 = arg / parse error
#
# Companion: release-tag.sh cuts the tag AFTER this bump lands; it verifies
# `.version` equals the tag, which is the half of this procedure that was
# already mechanised.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
readonly SCRIPT_DIR
# shellcheck source=lib/log.sh disable=SC1091
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/changelog-path.sh disable=SC1091
source "${SCRIPT_DIR}/lib/changelog-path.sh"

usage() {
  sed -n '/^# Usage:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  sed -n '/^# Options:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
  sed -n '/^# Exit:/,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

err() { printf '[release-bump] ERROR: %s\n' "$*" >&2; }

# derive_slug <root> -- print `owner/repo` from the origin remote. Deriving it
# rather than accepting a constant is what makes a repo rename self-correcting:
# the 16 stale links in base named the pre-rename repo precisely because they
# were written once, by hand, and never revisited.
derive_slug() {
  local root="$1" url
  url="$(git -C "${root}" remote get-url origin 2>/dev/null)" || return 1
  [[ -n "${url}" ]] || return 1
  url="${url%.git}"
  case "${url}" in
    git@*:*)   printf '%s\n' "${url#*:}" ;;
    ssh://*|https://*|http://*)
               url="${url#*://}"
               url="${url#*@}"
               printf '%s\n' "${url#*/}" ;;
    *) return 1 ;;
  esac
}

# headings <changelog> -- print every `## [<label>]` label in file order
# (newest first, which is the Keep-a-Changelog convention this repo follows).
headings() {
  sed -n 's/^## \[\([^]]*\)\].*/\1/p' "$1"
}

# oldest_version <changelog> -- the last (oldest) version label in the file.
# That is the one heading whose predecessor, if any, is not in this file.
oldest_version() {
  headings "$1" | grep -v '^Unreleased$' | tail -1
}

# predecessor_tag <live-changelog> <root> -- print the tag the live file's
# OLDEST heading should compare against: the newest version recorded in the
# next-older changelog file. Returns 1 when there is none.
#
# Why: `link_block` linked its oldest heading to `releases/tag/` because
# nothing preceded it -- true only while the whole changelog is ONE file.
# Once base#926 split it per `0.Y` series, every series file's oldest heading
# does have a predecessor, in the previous series file, and base's real
# v0.43.md already links it that way (`compare/v0.42.0...v0.43.0-rc1`).
# Rederiving from one file alone silently rewrites that correct cross-series
# compare into a tag link on the next release. Same class of bug as the
# hardcoded path this script just stopped naming: a derivation whose domain
# quietly stopped being the whole story, degrading a good link with no error.
#
# Candidates are each OTHER file's NEWEST heading, so every comparison is
# across series and never rc-vs-release inside one, where `sort -V` orders
# `v0.42.0` below `v0.42.0-rc4`.
#
# Returns 1 when the live file is not part of the changelog directory -- an
# explicit `--changelog` outside the layout keeps the single-file behaviour,
# because we cannot tell what precedes a file we do not know the shape of.
predecessor_tag() {
  local live="$1" root="$2"
  local mine
  mine="$(oldest_version "${live}")"
  [[ -n "${mine}" ]] || return 1

  local f newest in_layout=0
  local -a cands=()
  while IFS= read -r f; do
    if [[ "${f}" == "${live}" ]]; then
      in_layout=1
      continue
    fi
    newest="$(headings "${f}" | grep -v '^Unreleased$' | head -1)"
    [[ -n "${newest}" ]] && cands+=("${newest}")
  done < <(changelog_files "${root}")

  (( in_layout )) || return 1
  (( ${#cands[@]} )) || return 1

  local pred
  pred="$(printf '%s\n' "${cands[@]}" "${mine}" | sort -V -u | awk -v me="${mine}" '
    $0 == me { print prev; exit }
    { prev = $0 }')"
  [[ -n "${pred}" ]] || return 1
  printf '%s\n' "${pred}"
}

# link_block <changelog> <slug> [predecessor] -- print the complete, correct
# link-definition block for the file's current headings. Pure function of
# (headings, slug, predecessor):
#   [Unreleased]  -> compare <newest release>...HEAD
#   [vN]          -> compare <next older>...<vN>
#   [oldest]      -> compare <predecessor>...<oldest> when a previous series
#                    file records one, else releases/tag/<oldest>
link_block() {
  local cl="$1" slug="$2" pred="${3:-}"
  local -a labels=()
  mapfile -t labels < <(headings "${cl}")
  (( ${#labels[@]} )) || return 0

  local -a versions=()
  local l
  for l in "${labels[@]}"; do
    [[ "${l}" == "Unreleased" ]] && continue
    versions+=("${l}")
  done
  (( ${#versions[@]} )) || return 0

  local base_url="https://github.com/${slug}"
  local i last=$(( ${#versions[@]} - 1 ))

  for l in "${labels[@]}"; do
    if [[ "${l}" == "Unreleased" ]]; then
      printf '[Unreleased]: %s/compare/%s...HEAD\n' "${base_url}" "${versions[0]}"
      break
    fi
  done

  for (( i = 0; i < last; i++ )); do
    printf '[%s]: %s/compare/%s...%s\n' \
      "${versions[i]}" "${base_url}" "${versions[i+1]}" "${versions[i]}"
  done
  if [[ -n "${pred}" ]]; then
    printf '[%s]: %s/compare/%s...%s\n' \
      "${versions[last]}" "${base_url}" "${pred}" "${versions[last]}"
  else
    printf '[%s]: %s/releases/tag/%s\n' \
      "${versions[last]}" "${base_url}" "${versions[last]}"
  fi
}

# strip_link_block <changelog> -- print the file without its version link
# definitions. Only labels that are `Unreleased` or version-shaped are removed,
# so a prose reference definition elsewhere in the file survives.
strip_link_block() {
  awk '
    /^\[(Unreleased|v?[0-9][^]]*)\]: https?:\/\// { next }
    { print }
  ' "$1"
}

# relink <changelog> <slug> [predecessor] -- print the file with a freshly
# derived link block.
relink() {
  local cl="$1" slug="$2" pred="${3:-}" body
  body="$(strip_link_block "${cl}")"
  # Collapse any trailing blank lines the removal left, then re-attach the
  # block after exactly one, so repeated runs converge on one shape.
  printf '%s\n' "${body}" | awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] ~ /^[[:space:]]*$/) last--
      for (i = 1; i <= last; i++) print lines[i]
    }
  '
  printf '\n'
  link_block "${cl}" "${slug}" "${pred}"
}

# promote <changelog> <tag> <date> -- print the file with `## [Unreleased]`
# replaced by an empty `## [Unreleased]` followed by the new release heading.
# The section body stays put, so it belongs to the release it was written for.
promote() {
  local cl="$1" tag="$2" date="$3"
  awk -v tag="${tag}" -v date="${date}" '
    !done && /^## \[Unreleased\]/ {
      print "## [Unreleased]"
      print ""
      print "## [" tag "] - " date
      done = 1
      next
    }
    { print }
  ' "${cl}"
}

main() {
  local tag="" root="" changelog="" date="" slug=""
  local links_only=0 check=0 dry_run=0

  while (( $# > 0 )); do
    case "$1" in
      -h|--help) usage; return 0 ;;
      --repo-root) [[ $# -ge 2 ]] || { err "missing value for $1"; return 2; }
                   root="$2"; shift 2 ;;
      --changelog) [[ $# -ge 2 ]] || { err "missing value for $1"; return 2; }
                   changelog="$2"; shift 2 ;;
      --date)      [[ $# -ge 2 ]] || { err "missing value for $1"; return 2; }
                   date="$2"; shift 2 ;;
      --slug)      [[ $# -ge 2 ]] || { err "missing value for $1"; return 2; }
                   slug="$2"; shift 2 ;;
      --links-only) links_only=1; shift ;;
      --check)      check=1; links_only=1; shift ;;
      --dry-run)    dry_run=1; shift ;;
      -*) err "unknown flag: $1"; usage; return 2 ;;
      *)  [[ -z "${tag}" ]] || { err "unexpected arg: $1"; return 2; }
          tag="$1"; shift ;;
    esac
  done

  if (( ! links_only )); then
    if [[ -z "${tag}" ]]; then
      err "missing <vX.Y.Z> (or pass --links-only / --check)"
      usage
      return 2
    fi
    if ! [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]; then
      err "invalid tag shape: ${tag} (expected vX.Y.Z or vX.Y.Z-rcN)"
      return 2
    fi
  fi

  [[ -n "${root}" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [[ -z "${root}" || ! -d "${root}" ]]; then
    _log_fatal release-bump precondition_missing path="${root:-<cwd>}" reason=not-a-git-repo
    return 2
  fi
  # Which file is live is DERIVED, never named: `doc/changelog/CHANGELOG.md`
  # is the generated index once a repo has split its changelog per series
  # (base#926), and a default naming it stopped base's v0.43.0-rc2 release
  # with a message that said which path it read and not what it wanted from
  # it. The heading is the marker on both layouts, so this needs no per-repo
  # configuration and does not go stale when the series rolls.
  if [[ -z "${changelog}" ]]; then
    if ! changelog="$(changelog_live_file "${root}")"; then
      err "cannot tell which file is this repo's live changelog"
      local line
      while IFS= read -r line; do err "  ${line}"; done \
        < <(changelog_why_no_live_file "${root}")
      err "  pass --changelog <path> for a layout this rule cannot see"
      _log_fatal release-bump precondition_missing path="$(changelog_dir "${root}")" reason=no-changelog
      return 1
    fi
  fi
  if [[ ! -f "${changelog}" ]]; then
    _log_fatal release-bump precondition_missing path="${changelog}" reason=no-changelog
    return 1
  fi
  [[ -n "${date}" ]] || date="$(date +%F)"

  if [[ -z "${slug}" ]]; then
    slug="$(derive_slug "${root}")" || {
      err "cannot derive the compare-link slug from origin -- pass --slug <owner/repo>"
      return 1
    }
  fi

  # The oldest heading in a series file is not the start of history -- the
  # previous series file holds what it compares against. Derived once here so
  # the promote path can relink a temp copy and still know its predecessor.
  local pred=""
  pred="$(predecessor_tag "${changelog}" "${root}")" || pred=""

  # --check: is the derived block already what the file says?
  if (( check )); then
    local want got
    want="$(relink "${changelog}" "${slug}" "${pred}")"
    got="$(cat "${changelog}")"
    if [[ "${want}" == "${got}" ]]; then
      printf 'changelog links up to date (%s)\n' "${slug}"
      return 0
    fi
    _log_warn release-bump drift_detected path="${changelog}" slug="${slug}"
    diff -u <(printf '%s\n' "${got}") <(printf '%s\n' "${want}") \
      | sed '1,2d' >&2 || true
    return 1
  fi

  local new_changelog
  if (( links_only )); then
    new_changelog="$(relink "${changelog}" "${slug}" "${pred}")"
  else
    if ! grep -q '^## \[Unreleased\]' "${changelog}"; then
      err "no '## [Unreleased]' heading in ${changelog} -- nothing to promote"
      err "  (the heading must survive every release; that is what the next cycle writes into)"
      return 1
    fi
    if grep -q "^## \[${tag}\]" "${changelog}"; then
      err "${changelog} already records ${tag} -- refusing to promote twice"
      return 1
    fi
    local promoted
    promoted="$(promote "${changelog}" "${tag}" "${date}")"
    local tmp
    tmp="$(mktemp)" || { err "mktemp failed"; return 1; }
    printf '%s\n' "${promoted}" > "${tmp}"
    new_changelog="$(relink "${tmp}" "${slug}" "${pred}")"
    rm -f "${tmp}"
  fi

  if (( dry_run )); then
    printf '[dry-run] would rewrite %s\n' "${changelog}"
    diff -u "${changelog}" <(printf '%s\n' "${new_changelog}") || true
    (( links_only )) || printf '[dry-run] would set %s/.version to %s\n' "${root}" "${tag}"
    return 0
  fi

  printf '%s\n' "${new_changelog}" > "${changelog}" || {
    _log_err release-bump patch_failed path="${changelog}" reason=write-failed
    return 1
  }
  local mode=bump
  (( links_only )) && mode=links
  _log_info release-bump patch_applied path="${changelog}" slug="${slug}" mode="${mode}"

  if (( ! links_only )); then
    if [[ -f "${root}/.version" ]]; then
      printf '%s\n' "${tag}" > "${root}/.version" || {
        _log_err release-bump patch_failed path="${root}/.version" reason=write-failed
        return 1
      }
      _log_info release-bump patch_applied path="${root}/.version" version="${tag}"
    else
      _log_warn release-bump patch_skipped path="${root}/.version" reason=absent
    fi
    printf 'bumped to %s (%s). Next: commit the chore PR, then release-tag.sh %s\n' \
      "${tag}" "${date}" "${tag}"
  else
    printf 'changelog links regenerated from %s headings (%s)\n' \
      "$(headings "${changelog}" | wc -l | tr -d ' ')" "${slug}"
  fi
}

main "$@"
