#!/usr/bin/env bash
# log-allow:script -- emits data-product output (markdown table / next-step hint / Monitor protocol / pass-fail summary) alongside _log_*; per-callsite split deferred until tooling can distinguish.

# check-claude-md-tree.sh
#
# Audit the `.claude/` tree listing in a markdown file against the
# actual filesystem under `.claude/`. Designed for CI lint — exits
# non-zero on drift so the build fails.
#
# Default file: CLAUDE.md. Post-#127 the tree-check target
# (`just -f .claude/test/justfile tree-check`) passes CONTEXT.md
# instead, because the tree listing moved there in the CLAUDE.md slim.
#
# Compares direct children of:
#   - .claude/commands/
#   - .claude/scripts/
#   - .claude/hooks/
#
# Subdirectories intentionally folded in the tree (e.g. `└── test/`
# under hooks/) are honoured — they're matched as `<name>/` entries on
# both sides, so we don't false-positive on them.
#
# Why bash + python heredoc rather than pure bash: parsing markdown tree
# structure (mixed indentation, embedded comments, multiple sub-blocks)
# is fragile in awk/sed. Python's `re` + filesystem APIs are stable and
# the heredoc keeps the script as a single self-contained .sh file that
# matches the rest of `.claude/scripts/`.

set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 [path/to/markdown-file]

Audit the \`.claude/\` tree listing in a markdown file against the
actual filesystem. If no path is given, defaults to
\`\${CLAUDE_PROJECT_DIR:-cwd}/CLAUDE.md\`. Post-#127 the tree-check
target \`just -f .claude/test/justfile tree-check\` passes CONTEXT.md
(where the tree listing now lives after the CLAUDE.md slim).

Exit codes:
  0  Tree aligned with filesystem
  1  Drift detected (entries missing from or extra in the markdown tree)
  2  Usage / parse error
EOF
}

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
  esac

  local claude_md="${1:-${CLAUDE_PROJECT_DIR:-$(pwd)}/CLAUDE.md}"

  if [[ ! -f "${claude_md}" ]]; then
    echo "error: CLAUDE.md not found at: ${claude_md}" >&2
    exit 2
  fi

  python3 - "${claude_md}" <<'PY'
import re
import sys
from pathlib import Path

claude_md = Path(sys.argv[1])
project_dir = claude_md.parent
claude_dir = project_dir / ".claude"

if not claude_dir.is_dir():
    print(f"error: .claude/ not found at {claude_dir}", file=sys.stderr)
    sys.exit(2)

AUDITED = ("commands", "scripts", "hooks")

# Markdown tree regexes:
#   `    ├── commands/         # ...`     → top-level dir under .claude/
#   `    │   ├── audit.md      # ...`     → file under that dir
#   `    │   └── test/         # ...`     → folded subdir under that dir
dir_entry_re = re.compile(r"^    [|│][^├└]*[├└]── (\S+?)(/?)\s*(?:#.*)?$")
nested_entry_re = re.compile(r"^    [|│]   [├└]── (\S+?)(/?)\s*(?:#.*)?$")
top_dir_re = re.compile(r"^    [├└]── (\S+?)(/?)\s*(?:#.*)?$")

text = claude_md.read_text()
lines = text.splitlines()

listed = {d: set() for d in AUDITED}

in_block = False
current_dir = None
for line in lines:
    if not in_block:
        # Anchor: `└── .claude/` (last child) or `├── .claude/` (any position)
        if line.startswith("└── .claude/") or line.startswith("├── .claude/"):
            in_block = True
        continue

    # Blank lines stay inside the block
    if not line.strip():
        continue
    # Anything not indented by at least 4 spaces ends the block
    if not line.startswith("    "):
        in_block = False
        current_dir = None
        continue

    m_top = top_dir_re.match(line)
    if m_top:
        entry = m_top.group(1)
        current_dir = entry if entry in AUDITED else None
        continue

    m_nested = nested_entry_re.match(line)
    if m_nested and current_dir:
        name = m_nested.group(1)
        is_dir = bool(m_nested.group(2))
        listed[current_dir].add(name + ("/" if is_dir else ""))

# Filesystem
fs = {}
for d in AUDITED:
    p = claude_dir / d
    fs[d] = set()
    if p.is_dir():
        for child in p.iterdir():
            if child.name.startswith("."):
                continue
            # Skip Python bytecode caches; created on-demand by
            # `instinct-query.sh` / similar consumers of helper .py
            # modules and not part of the tracked tree.
            if child.name == "__pycache__":
                continue
            fs[d].add(child.name + ("/" if child.is_dir() else ""))

drift = False
for d in AUDITED:
    missing = fs[d] - listed[d]   # in fs, not in CLAUDE.md
    extra = listed[d] - fs[d]     # in CLAUDE.md, not in fs
    if missing or extra:
        drift = True
        print(f".claude/{d}/:", file=sys.stderr)
        for m in sorted(missing):
            print(f"  + {m}  (in filesystem, missing from CLAUDE.md tree)", file=sys.stderr)
        for e in sorted(extra):
            print(f"  - {e}  (in CLAUDE.md tree, missing from filesystem)", file=sys.stderr)

if drift:
    print("", file=sys.stderr)
    print("CLAUDE.md `.claude/` tree out of sync with filesystem.", file=sys.stderr)
    rel = claude_md.relative_to(project_dir) if project_dir != Path(".") else claude_md
    print(f"Update {rel} to match.", file=sys.stderr)
    sys.exit(1)

print("CLAUDE.md `.claude/` tree aligned with filesystem.")
sys.exit(0)
PY
}

main "$@"
