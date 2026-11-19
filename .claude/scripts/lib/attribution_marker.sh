#!/usr/bin/env bash
# attribution_marker.sh -- the one AI-attribution marker matcher shared by the
# commit-msg hook and the PreToolUse commit guard (refs base#1988).
#
# Source, do not execute. Functions:
#   attribution_marker_find   reads ALL of stdin, prints the first marker
#                             found; exits 0 on a match, 1 when there is none.
#                             It never stops reading early, so a writer piping
#                             into it under pipefail cannot die of SIGPIPE.
#
# Two kinds of marker: a fixed phrase (ATTRIBUTION_MARKER_ERE), and a
# `Key: ... <address>` trailer whose address IS the noreply anthropic one,
# compared as a whole address (a longer address that only starts with it is
# not a match). Trailers are read as the raw lines and as git's own parse
# (`git interpret-trailers --parse`), which joins an indented continuation
# line onto its trailer.

ATTRIBUTION_MARKER_ERE='Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude'

# Prints "<Key>: ... <address>" for the first line holding the whole noreply
# address with a `Key:` before it.
# shellcheck disable=SC2016  # an awk program: $0 is awk's, not the shell's
_ATTRIBUTION_ADDRESS_AWK='
BEGIN { a = "noreply@anthropic.com" }
found { next }
{
  low = tolower($0); off = 0
  while ((p = index(substr(low, off + 1), a)) > 0) {
    s = off + p; e = s + length(a); off = e - 1
    if (substr(low, s - 1, 1) ~ /[a-z0-9._%+-]/) continue
    if (substr(low, e, 1) ~ /[a-z0-9_%+@-]/ || substr(low, e, 2) ~ /^\.[a-z0-9]/) continue
    if (!match(substr($0, 1, s - 1), /[A-Za-z0-9-]+:[^:]*$/)) continue
    print substr($0, RSTART, e - RSTART) (substr($0, e, 1) == ">" ? ">" : ""); found = 1; break
  }
}'

attribution_marker_find() {
  local text hit
  text="$(cat)"
  hit="$(grep -m1 -oiE "${ATTRIBUTION_MARKER_ERE}" <<< "${text}")"
  [[ -n "${hit}" ]] || hit="$({ printf '%s\n' "${text}"
    git interpret-trailers --parse <<< "${text}" 2>/dev/null; } | awk "${_ATTRIBUTION_ADDRESS_AWK}")"
  [[ -n "${hit}" ]] || return 1
  printf '%s\n' "${hit%%$'\n'*}"
}
