#!/usr/bin/env bash
# log-allow:script -- emits a data product (the regenerated-vs-committed
# unified diff, plus a one-line verdict), not _log_* records; same call as
# check-claude-md-tree.sh / check-log-helper-usage.sh.
#
# sync-doc-test-counts.sh -- regenerate every derived figure in
# `doc/test/*.md` from the spec tree, so the catalogs stop being
# hand-maintained.
#
# WHY A GENERATOR AND NOT A BIGGER CHECKER (refs #265, base#859)
#
# This repo already had two hand-rolled drift CHECKERS -- the
# `check_test_md_drift.sh` PostToolUse hook and `verify.sh`'s `test-md`
# phase -- and the per-spec rows still rotted: two stale counts, one spec
# listed after its file was deleted, four specs never listed at all. A
# catalogue that looks authoritative but is typed by hand rots no matter how
# many advisory checkers watch it; the fix is to derive it. Everything below
# is derived from the tree, and `--check` is the SAME code path (regenerate
# into a scratch copy, diff), so the gate and the generator can never
# disagree -- which is precisely how the two older checkers rotted into
# matching nothing at all after the specs moved to `.claude/test/bats/`.
#
# WHAT IS DERIVED
#   1. per-spec `### <relpath> (N)` heading counts;
#   2. the per-spec catalogue ROWS -- one row per `@test`, in spec order;
#   3. sections for spec files the doc never mentions (appended), and the
#      removal of sections whose spec file has left the tree;
#   4. the per-level `**N tests**` totals (`unit.md` also `across N specs`);
#   5. TEST.md's grand total, its per-level index table, and the
#      `(N hooks + N helper scripts)` figure in its Static analysis section.
#
# SEMANTICS THAT HAD TO BE SETTLED (each one is a defined outcome, not an
# accident of the implementation):
#
#   Row identity   The bats test name, exactly as bats reports it: read from
#                  the `@test "..." {` line with bash double-quote unescaping
#                  applied (`\"` `\\` `\$` `` \` `` lose the backslash), so a
#                  row can be pasted straight into `bats --filter`. `|`,
#                  `<` and `` ` `` are escaped on the way into the table and
#                  unescaped on the way back out (see _render_row), so no
#                  test name can break the table or vanish into inline HTML.
#   Preservation   A row whose test still exists KEEPS ITS DESCRIPTION
#                  VERBATIM. The match is on the name, so hand-written prose
#                  survives regeneration -- that is the whole point: the
#                  count was derived and the prose was not, and that
#                  asymmetry is what rotted.
#   Deletion       A row naming no existing test is dropped. A `###` section
#                  whose spec FILE no longer exists is dropped whole (git
#                  history keeps it; a catalogue of the tree has no place for
#                  a file that left the tree).
#   Rename         Delete plus add, for both rows and sections: the old one
#                  goes, the new name arrives with the `-` placeholder.
#                  Prose does NOT follow a rename -- nothing can tell a
#                  rename from a delete-plus-add. To carry prose across one,
#                  rename the row / heading in the doc in the same commit,
#                  then regenerate.
#   Ordering       Rows follow SPEC FILE ORDER, not alphabetical, so the
#                  table reads as the spec reads and reordering a spec
#                  produces the matching doc diff instead of an unrelated
#                  scatter. New sections are appended at the end of the doc;
#                  move one into its thematic group freely, the generator
#                  keys on the heading, never on the position.
#   Placeholder    A test with no description gets `-`. Enriching it is
#                  optional; omitting the row is not possible.
#   Opt-in tables  A section only gets generated rows if it already carries a
#                  `| Test | Scenario |` (or `| Test | Description |`) header
#                  row. A section that summarises differently, or carries
#                  only prose, is left alone -- presentation is an editorial
#                  call, and the heading count still gates it.
#
# ONE-LINE FIGURES: the `**N tests**` / `(N hooks + N helper scripts)`
# rewrites are line-anchored, so those phrases must not be split by a line
# wrap. Reflow the sentence rather than un-deriving the figure.
#
# Usage:
#   sync-doc-test-counts.sh [--check] [<repo-root>]
#
# Options:
#   --check     Read-only. Regenerate into a scratch copy and diff it
#               against the committed docs; exit 1 (printing the diff) if
#               they differ. This is the CI / gate mode.
#   -h, --help  Show this help.
#
# Exit codes:
#   0  docs regenerated (default mode), or already in sync (--check)
#   1  drift detected (--check only)
#   2  usage / repo-root error
#
# Style: Google Shell Style Guide.

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Style:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

readonly DEFAULT_RULE='|------|----------|'

# _levels -- ISTQB level docs that own a spec directory (ADR-00000013).
# smoke.md is N/A in this repo (no product image) and TEST.md is the index;
# neither owns specs, so neither gets a section sweep or a level total.
_levels() {
  printf '%s\n' unit integration system acceptance
}

# _spec_dir <root> <doc-basename> -- root-relative spec directory the named
# doc catalogues, or nothing. Candidates are probed in order so the script
# works both against this repo (`.claude/test/bats/<level>/`) and against the
# plain `test/<level>/` layouts the drift hook also supports.
_spec_dir() {
  local _root="$1" _base="$2" _level _cand
  case "${_base}" in
    unit.md|integration.md|system.md|acceptance.md) _level="${_base%.md}" ;;
    *) return 0 ;;
  esac
  for _cand in ".claude/test/bats/${_level}" "test/bats/${_level}" \
    "test/${_level}"; do
    if [[ -d "${_root}/${_cand}" ]]; then
      printf '%s\n' "${_cand}"
      return 0
    fi
  done
  return 0
}

# _spec_files <root> <reldir> -- the spec files under <reldir>, in glob
# (sorted) order, as root-relative paths.
_spec_files() {
  local _root="$1" _dir="$2" _f
  for _f in "${_root}/${_dir}"/*.bats; do
    [[ -f "${_f}" ]] || continue
    printf '%s\n' "${_f#"${_root}"/}"
  done
}

# _test_count <file> -- `^@test` stanza count, the single source of truth for
# every figure here (the same expression the drift hook counts with).
_test_count() {
  local _file="$1" _n
  [[ -f "${_file}" ]] || { printf '0\n'; return 0; }
  _n="$(grep -c '^@test' "${_file}" 2>/dev/null || true)"
  printf '%s\n' "${_n:-0}"
}

# _dir_test_count <root> <reldir> -- total `^@test` across a spec directory.
_dir_test_count() {
  local _root="$1" _dir="$2" _rel _sum=0
  while IFS= read -r _rel; do
    _sum=$(( _sum + $(_test_count "${_root}/${_rel}") ))
  done < <(_spec_files "${_root}" "${_dir}")
  printf '%s\n' "${_sum}"
}

# _dir_spec_count <root> <reldir> -- number of spec files in a directory.
_dir_spec_count() {
  local _root="$1" _dir="$2" _n
  _n="$(_spec_files "${_root}" "${_dir}" | wc -l)"
  printf '%s\n' "${_n//[[:space:]]/}"
}

# _unescape_into <outvar> <raw> -- bash double-quote unescaping: `\X`
# collapses to `X` for the four characters bash treats specially inside
# "...", every other backslash stays literal. This is what bats does to a
# `@test "..."` name before printing it, so a row's identity equals the name
# in the TAP output.
_unescape_into() {
  local -n _unescape_out="$1"
  local _raw="$2" _res='' _i _ch _next _bs=$'\\'
  local _len="${#_raw}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_raw:_i:1}"
    if [[ "${_ch}" == "${_bs}" && $(( _i + 1 )) -lt "${_len}" ]]; then
      _next="${_raw:_i+1:1}"
      if [[ "${_next}" == '"' || "${_next}" == "${_bs}" \
        || "${_next}" == '$' || "${_next}" == '`' ]]; then
        _res+="${_next}"
        _i=$(( _i + 1 ))
        continue
      fi
    fi
    _res+="${_ch}"
  done
  _unescape_out="${_res}"
}

# _test_names <file> -- bats test names in file order, one per line.
#
# The trailing `{` is NOT anchored to end-of-line, so the one-line stanza
# form (`@test "x" { :; }`) is catalogued as well as the canonical
# body-on-the-next-line form. It has to be: the heading count is
# `grep -c '^@test'`, which counts both, and a row set that silently skipped
# one shape would disagree with the count it sits under -- the exact
# asymmetry this generator exists to remove. Greedy `(.*)` plus backtracking
# picks the last `"` that is actually followed by `{`, so a quoted string in
# an inline body does not steal the name.
_test_names() {
  local _file="$1" _line _name
  [[ -f "${_file}" ]] || return 0
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    [[ "${_line}" =~ ^@test[[:space:]]+\"(.*)\"[[:space:]]*\{ ]] \
      || continue
    _unescape_into _name "${BASH_REMATCH[1]}"
    printf '%s\n' "${_name}"
  done < "${_file}"
}

# _render_row <name> <desc> -- one catalogue row. Rows are plain text (no
# code span) to match the catalogs' existing style, so three characters are
# escaped on the way in:
#   `|`  would end the cell early;
#   `<`  opens inline HTML in every markdown renderer and swallows what
#        follows (which is why the hand-written rows already said `\<tag\>`).
#        A bare `>` is harmless mid-line, so it is emitted raw -- but still
#        un-escaped on READ, so the older `\>` rows keep their prose;
#   `` ` `` would open a code span that closes somewhere unintended.
# _split_row undoes exactly these, so the round trip is stable. A LITERAL
# backslash in a test name is the one thing not round-tripped; none exist,
# and the names are read post-unescaping anyway.
_render_row() {
  local _name="$1"
  _name="${_name//|/\\|}"
  _name="${_name//\`/\\\`}"
  _name="${_name//</\\<}"
  printf '| %s | %s |\n' "${_name}" "$2"
}

# _split_row <line> -- split a catalogue row into _ROW_NAME / _ROW_DESC.
# Returns 1 for a line that is not a row. The split is on the first
# UNESCAPED `|` so a `\|` inside a test name does not end the cell; the
# description keeps any `|` it contains.
_ROW_NAME=''
_ROW_DESC=''
_split_row() {
  local _line="$1"
  [[ "${_line}" == '|'* ]] || return 1
  local _body="${_line#|}" _cell='' _rest='' _i _ch _bs=$'\\'
  local _len="${#_body}"
  for (( _i = 0; _i < _len; _i++ )); do
    _ch="${_body:_i:1}"
    if [[ "${_ch}" == "${_bs}" && $(( _i + 1 )) -lt "${_len}" ]]; then
      _cell+="${_body:_i:2}"
      _i=$(( _i + 1 ))
      continue
    fi
    if [[ "${_ch}" == '|' ]]; then
      _rest="${_body:_i+1}"
      break
    fi
    _cell+="${_ch}"
  done
  _cell="${_cell#"${_cell%%[![:space:]]*}"}"
  _cell="${_cell%"${_cell##*[![:space:]]}"}"
  _cell="${_cell//\\|/|}"
  _cell="${_cell//\\\`/\`}"
  _cell="${_cell//\\</<}"
  _cell="${_cell//\\>/>}"
  _rest="${_rest%|}"
  _rest="${_rest#"${_rest%%[![:space:]]*}"}"
  _rest="${_rest%"${_rest##*[![:space:]]}"}"
  _ROW_NAME="${_cell}"
  _ROW_DESC="${_rest}"
}

# _flush_table <spec-file> <rule> -- emit the alignment rule then one row per
# `@test`, each carrying the description recorded for that name (`-` when
# there is none). Descriptions come from the caller's _DESC map.
_flush_table() {
  local _spec="$1" _rule="${2:-}" _name
  [[ -n "${_rule}" ]] || _rule="${DEFAULT_RULE}"
  printf '%s\n' "${_rule}"
  while IFS= read -r _name; do
    # shellcheck disable=SC2154  # _DESC is the caller's (dynamic) scope.
    _render_row "${_name}" "${_DESC[${_name}]:--}"
  done < <(_test_names "${_spec}")
}

# _sync_doc <root> <doc> -- one pass over <doc>: regenerate every spec
# heading's count, drop sections whose spec file is gone, and regenerate the
# rows of every opted-in catalogue table.
_sync_doc() {
  local _root="$1" _doc="$2"
  [[ -f "${_doc}" ]] || return 0
  local _tmp
  _tmp="$(mktemp "${_doc}.XXXXXX")" || return 1

  local _spec='' _drop=0 _in_table=0 _rule='' _line _hashes _path
  local -A _DESC=()

  {
    while IFS= read -r _line || [[ -n "${_line}" ]]; do
      if (( _in_table )); then
        if [[ "${_line}" == '|'* ]]; then
          if [[ "${_line}" =~ ^\|[-:[:space:]|]+\|[[:space:]]*$ ]]; then
            [[ -n "${_rule}" ]] || _rule="${_line}"
            continue
          fi
          if _split_row "${_line}" && [[ -n "${_ROW_NAME}" ]]; then
            _DESC["${_ROW_NAME}"]="${_ROW_DESC}"
          fi
          continue
        fi
        _flush_table "${_root}/${_spec}" "${_rule}"
        _in_table=0
        _rule=''
        _DESC=()
      fi

      if [[ "${_line}" =~ ^#{1,6}[[:space:]] ]]; then
        _spec=''
        _drop=0
        if [[ "${_line}" =~ ^(#{3,6})[[:space:]]+([^[:space:]]+\.bats)[[:space:]]+\([0-9]+\)[[:space:]]*$ ]]; then
          _hashes="${BASH_REMATCH[1]}"
          _path="${BASH_REMATCH[2]}"
          if [[ -f "${_root}/${_path}" ]]; then
            _spec="${_path}"
            printf '%s %s (%s)\n' "${_hashes}" "${_path}" \
              "$(_test_count "${_root}/${_path}")"
          else
            _drop=1
          fi
          continue
        fi
        printf '%s\n' "${_line}"
        continue
      fi

      if (( _drop )); then
        continue
      fi

      if [[ -n "${_spec}" ]] \
        && [[ "${_line}" =~ ^\|[[:space:]]*Test[[:space:]]*\|[[:space:]]*(Scenario|Description)[[:space:]]*\|[[:space:]]*$ ]]; then
        printf '%s\n' "${_line}"
        _in_table=1
        _rule=''
        continue
      fi

      printf '%s\n' "${_line}"
    done < "${_doc}"
    if (( _in_table )); then
      _flush_table "${_root}/${_spec}" "${_rule}"
    fi
  } > "${_tmp}"

  mv "${_tmp}" "${_doc}"
}

# _append_missing_sections <root> <doc> -- append a stub section for every
# spec file the doc's level owns but never mentions. Generating the ROWS
# makes a table complete; it cannot help a spec that never got a heading in
# the first place, which is the same rot one level up and just as invisible
# to a check that only re-derives what the doc already names. The stub is
# heading + table header only; _sync_doc fills in the rule and the rows on
# the pass that follows.
_append_missing_sections() {
  local _root="$1" _doc="$2" _dir _rel _pat
  _dir="$(_spec_dir "${_root}" "$(basename -- "${_doc}")")"
  [[ -n "${_dir}" ]] || return 0

  # An appended heading must start its own line even if the doc did not end
  # with a newline.
  if [[ -s "${_doc}" && -n "$(tail -c1 "${_doc}")" ]]; then
    printf '\n' >> "${_doc}"
  fi

  while IFS= read -r _rel; do
    _pat="^#{3,6}[[:space:]]+${_rel//./\\.}[[:space:]]+\([0-9]+\)[[:space:]]*$"
    if grep -qE "${_pat}" "${_doc}"; then
      continue
    fi
    {
      printf '\n### %s (%s)\n\n' "${_rel}" "$(_test_count "${_root}/${_rel}")"
      printf '| Test | Scenario |\n%s\n' "${DEFAULT_RULE}"
    } >> "${_doc}"
  done < <(_spec_files "${_root}" "${_dir}")
}

# _sync_level_total <root> <doc> <reldir> -- rewrite the doc's `**N tests**`
# headline (and unit.md's `across N specs`).
_sync_level_total() {
  local _root="$1" _doc="$2" _dir="$3" _tests _specs
  _tests="$(_dir_test_count "${_root}" "${_dir}")"
  _specs="$(_dir_spec_count "${_root}" "${_dir}")"
  sed -i -E \
    "s/\*\*[0-9]+ tests\*\* across [0-9]+ specs/**${_tests} tests** across ${_specs} specs/" \
    "${_doc}"
  sed -i -E "s/\*\*[0-9]+ tests\*\*/**${_tests} tests**/" "${_doc}"
}

# _sync_index <root> <docdir> -- rewrite <docdir>/TEST.md's derived figures
# (grand total, per-level index table, Static analysis script tallies) from
# the spec / hook / script tree under <root>.
_sync_index() {
  local _root="$1" _t="$2/TEST.md"
  [[ -f "${_t}" ]] || return 0
  local _level _dir _n _total=0
  while IFS= read -r _level; do
    _dir="$(_spec_dir "${_root}" "${_level}.md")"
    _n=0
    [[ -n "${_dir}" ]] && _n="$(_dir_test_count "${_root}" "${_dir}")"
    _total=$(( _total + _n ))
    sed -i -E "s#(\[${_level}\.md\]\(${_level}\.md\).*\| )[0-9]+ #\1${_n} #" "${_t}"
  done < <(_levels)
  sed -i -E \
    "s/(Grand total \(all levels\): )\*\*[0-9]+ tests\*\*/\1**${_total} tests**/" \
    "${_t}"

  # The hook / helper tallies only exist where this framework does; a repo
  # (or a fixture) without a .claude/ tree simply keeps whatever it wrote.
  local _hooks _scripts
  if [[ -d "${_root}/.claude/hooks" && -d "${_root}/.claude/scripts" ]]; then
    _hooks="$(find "${_root}/.claude/hooks" -maxdepth 1 -name '*.sh' | wc -l)"
    _scripts="$(find "${_root}/.claude/scripts" -maxdepth 1 -name '*.sh' | wc -l)"
    sed -i -E \
      "s/\([0-9]+ hooks \+ [0-9]+ helper scripts\)/(${_hooks//[[:space:]]/} hooks + ${_scripts//[[:space:]]/} helper scripts)/" \
      "${_t}"
  fi
}

# _sync_all <root> [docdir] -- regenerate every doc under <docdir> (default
# <root>/doc/test). The docdir seam is what lets --check share this exact
# code path instead of re-implementing the comparison.
_sync_all() {
  local _root="$1" _docdir="${2:-$1/doc/test}" _doc _dir
  for _doc in "${_docdir}"/*.md; do
    [[ -f "${_doc}" ]] || continue
    _append_missing_sections "${_root}" "${_doc}"
    _sync_doc "${_root}" "${_doc}"
    _dir="$(_spec_dir "${_root}" "$(basename -- "${_doc}")")"
    [[ -n "${_dir}" ]] || continue
    _sync_level_total "${_root}" "${_doc}" "${_dir}"
  done
  _sync_index "${_root}" "${_docdir}"
}

# _check <root> -- regenerate into a scratch copy and diff. Same code path as
# the writer, so the gate cannot disagree with the generator.
_check() {
  local _root="$1" _scratch _rc=0
  _scratch="$(mktemp -d)"
  cp "${_root}"/doc/test/*.md "${_scratch}/" 2>/dev/null || true
  _sync_all "${_root}" "${_scratch}"
  diff -ru "${_root}/doc/test" "${_scratch}" || _rc=1
  rm -rf "${_scratch}"
  if (( _rc )); then
    printf 'doc/test drift -- regenerate with .claude/scripts/sync-doc-test-counts.sh\n' >&2
    return 1
  fi
  printf 'doc/test counts in sync\n'
}

main() {
  local _mode=sync _root=''
  while (( $# )); do
    case "$1" in
      --check) _mode=check ;;
      -h|--help) usage; exit 0 ;;
      -*) printf 'unknown option: %s\n' "$1" >&2; usage; exit 2 ;;
      *) _root="$1" ;;
    esac
    shift
  done
  if [[ -z "${_root}" ]]; then
    _root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  fi
  if [[ ! -d "${_root}/doc/test" ]]; then
    printf 'error: no doc/test under %s\n' "${_root}" >&2
    exit 2
  fi
  _root="$(cd -- "${_root}" && pwd)"

  if [[ "${_mode}" == check ]]; then
    if ! _check "${_root}"; then
      exit 1
    fi
    return 0
  fi
  _sync_all "${_root}"
  printf 'synced %s/doc/test\n' "${_root}"
}

main "$@"
