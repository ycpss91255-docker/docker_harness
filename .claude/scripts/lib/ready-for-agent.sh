#!/usr/bin/env bash
# log-allow:script -- pure predicate library, emits nothing of its own.
#
# ready-for-agent.sh -- the ONE readiness check behind BOTH gates of #294.
#
# ADR-00000015 defines `ready-for-agent` as an assertion that four things
# are present in the issue, not a feeling:
#
#   1. Seams       -- which files change, what the interface is
#   2. First slice -- the first failing test to write
#   3. Gate        -- the command that decides done
#   4. Bound       -- how many red-green cycles before stopping
#
# and it records TWO gates over them, deliberately not one check twice:
#
#   Gate A -- applying the label   ("is this label honest")
#             .claude/hooks/enforce_ready_for_agent.sh
#   Gate B -- starting the pipeline ("is this safe to start", regardless
#             of the label). .claude/scripts/check-ready-for-agent.sh,
#             consumed by #296.
#
# Two questions, one implementation. Two copies of the parts list or the
# heading shape would drift, which is the failure this repo keeps
# repairing.

# The label whose meaning this file enforces.
READY_FOR_AGENT_LABEL='ready-for-agent'

# The four parts, spelled as the fixed heading each must appear under.
# Reported in this order. Headings fixed, prose free: the implementer is
# an LLM and reads prose fine, so the headings exist only so that "are
# all four present" is machine-answerable. Documented for authors in
# .claude/skills/gh-artifact-format/SKILL.md.
READY_FOR_AGENT_PARTS=('Seams' 'First slice' 'Gate' 'Bound')

# rfa_heading_re <part> -- ERE matching the markdown heading for <part>.
# Any heading level from ## down, an optional leading "The " (the ADR
# spells them "The first slice" / "A bound" in prose), and any trailing
# prose on the heading line -- `## Bound -- 10 cycles` counts. The word
# boundary stops `## Seamstress` and `## Bounds` from counting.
rfa_heading_re() {
  printf '^#{2,6}[[:space:]]+(the[[:space:]]+|a[[:space:]]+)?%s\\b' "$1"
}

# rfa_missing_parts <text> -- print, one per line and in canonical
# order, the parts NOT found in <text>. Empty output means ready.
rfa_missing_parts() {
  local text="$1" part re
  for part in "${READY_FOR_AGENT_PARTS[@]}"; do
    re="$(rfa_heading_re "${part}")"
    if ! printf '%s\n' "${text}" | grep -qiE "${re}"; then
      printf '%s\n' "${part}"
    fi
  done
}

# rfa_label_defined [repo] -- 0 when the repo defines the label, 1 when
# it demonstrably does not, 2 when gh could not answer.
#
# Both gates stay SILENT on 1 and on 2. A repo that has not adopted the
# vocabulary gets no gate at all -- a gate firing where the vocabulary is
# not adopted is pure friction, which is #278's own reasoning -- and a
# transient gh failure must never block a label edit.
rfa_label_defined() {
  local repo="${1:-}" names args
  args=(label list --limit 200 --json name --jq '.[].name')
  [[ -n "${repo}" ]] && args+=(-R "${repo}")
  names="$(gh "${args[@]}" 2>/dev/null)" || return 2
  printf '%s\n' "${names}" | grep -qxF "${READY_FOR_AGENT_LABEL}"
}

# rfa_issue_text <number> [repo] -- the issue's body AND every comment,
# concatenated. Returns gh's exit status.
#
# WHY THE COMMENTS: the issue body is the original spec and does not get
# rewritten -- evolution goes in comments (this repo's standing rule), so
# a grill's conclusions are written back as a COMMENT. A body-only check
# would fail every grilled issue against its own gate.
rfa_issue_text() {
  local num="$1" repo="${2:-}" args
  args=(issue view "${num}" --json 'body,comments'
        --jq '([.body] + [.comments[].body]) | .[]')
  [[ -n "${repo}" ]] && args+=(-R "${repo}")
  gh "${args[@]}" 2>/dev/null
}

# rfa_check <number> [repo] -- the whole readiness question for one
# issue. Prints the missing parts (one per line) and returns:
#   0  ready -- all four parts present
#   1  not ready -- missing parts on stdout
#   2  undecidable -- gh could not be asked; callers stay silent
rfa_check() {
  local num="$1" repo="${2:-}" text missing
  text="$(rfa_issue_text "${num}" "${repo}")" || return 2
  [[ -z "${text}" ]] && return 2
  missing="$(rfa_missing_parts "${text}")"
  [[ -z "${missing}" ]] && return 0
  printf '%s\n' "${missing}"
  return 1
}

# rfa_headings_hint -- the fixed heading shape, for messages.
rfa_headings_hint() {
  local part out=""
  for part in "${READY_FOR_AGENT_PARTS[@]}"; do
    out+="\`## ${part}\` "
  done
  printf '%s' "${out% }"
}
