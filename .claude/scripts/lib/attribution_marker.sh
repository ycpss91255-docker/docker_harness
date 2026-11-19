#!/usr/bin/env bash
# attribution_marker.sh -- the one AI-attribution marker matcher shared by the
# commit-msg hook and the PreToolUse commit guard (refs base#1988).
#
# Source, do not execute. Functions:
#   attribution_marker_find   reads ALL of stdin, prints the first marker
#                             found; exits 0 on a match, 1 when there is none.
#                             It never stops reading early, so a writer piping
#                             into it under pipefail cannot die of SIGPIPE.

ATTRIBUTION_MARKER_ERE='Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude|[[:alnum:]-]+:[^<]*<?noreply@anthropic\.com>?'

attribution_marker_find() {
  local hits
  hits="$(grep -oiE "${ATTRIBUTION_MARKER_ERE}")" || return 1
  printf '%s\n' "${hits%%$'\n'*}"
}
