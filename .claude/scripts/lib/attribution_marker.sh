#!/usr/bin/env bash
# attribution_marker.sh -- the one AI-attribution marker matcher shared by the
# commit-msg hook and the PreToolUse commit guard (refs base#1988).
#
# Source, do not execute. Functions:
#   attribution_marker_find   reads stdin, prints the first marker found;
#                             exits 0 on a match, 1 when there is none.

ATTRIBUTION_MARKER_ERE='Generated with (\[)?Claude Code|Co-Authored-By:[[:space:]]*Claude|[[:alnum:]-]+:[^<]*<noreply@anthropic\.com>'

attribution_marker_find() {
  grep -oiE -m1 "${ATTRIBUTION_MARKER_ERE}" | head -n 1 | grep .
}
