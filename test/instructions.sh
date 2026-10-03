#!/usr/bin/env bash
# Does claude-go read your instructions? Runs the real Claude Code through
# bin/claude-go in fresh repositories and checks which instruction files reach
# the model (test/fake_proxy.py logs every request in full). Needs `claude` and
# python3; see test/claude_harness.sh. test/offline.sh checks that CLAUDE.md
# also survives LiteLLM's translation for Chat Completions and Responses models.
#
# Usage: test/instructions.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

# Index of the first request of the last turn that carried this text, or "none".
first_seen() { python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(next((i for i, r in enumerate(rows) if sys.argv[2] in json.dumps(r, ensure_ascii=False)), "none"))' "$log" "$1"; }
at_start() { [[ $(first_seen "$1") == 0 ]]; }

echo "== a new repository's instructions reach the model ($("$CLAUDE_BIN" --version 2>/dev/null))"
REPO_SETUP='echo "R-ROOT: rule from CLAUDE.md" >CLAUDE.md
  echo "@docs/rules.md" >>CLAUDE.md; mkdir -p docs .claude; echo "R-IMPORT: imported rule" >docs/rules.md
  echo "R-DOTCLAUDE: rule from .claude/CLAUDE.md" >.claude/CLAUDE.md
  echo "R-LOCAL: rule from CLAUDE.local.md" >CLAUDE.local.md' turn
check "CLAUDE.md" at_start R-ROOT
check "a file it @imports" at_start R-IMPORT
check ".claude/CLAUDE.md" at_start R-DOTCLAUDE
check "CLAUDE.local.md" at_start R-LOCAL

REPO_SETUP='rm -rf .git; echo "R-NOGIT: rule" >CLAUDE.md' turn
check "CLAUDE.md in a directory that is not a git repository yet" at_start R-NOGIT

REPO_SETUP='echo "R-AGENTS: rule from AGENTS.md" >AGENTS.md' turn
check "AGENTS.md when there is no CLAUDE.md" at_start R-AGENTS

FAKE_TOOL='{"name": "Read", "input": {"file_path": "sub/code.py"}}' \
REPO_SETUP='echo root >CLAUDE.md; mkdir sub; echo "R-NESTED: rule for sub/" >sub/CLAUDE.md; echo "x = 1" >sub/code.py' turn
check "sub/CLAUDE.md, once the model reads a file in sub/" eval '[[ $(first_seen R-NESTED) == 1 ]]'

echo "== user-level instructions"
HOME_SETUP='mkdir -p "$HOME/.claude-go"; echo "U-CLAUDE-GO: rule" >"$HOME/.claude-go/CLAUDE.md"' turn
check "~/.claude-go/CLAUDE.md (claude-go's own)" at_start U-CLAUDE-GO

HOME_SETUP='mkdir -p "$HOME/.claude" "$HOME/.claude-go"; echo "U-LINKED: rule" >"$HOME/.claude/CLAUDE.md"
  ln -s "$HOME/.claude/CLAUDE.md" "$HOME/.claude-go/CLAUDE.md"' turn
check "~/.claude/CLAUDE.md when linked into ~/.claude-go (install.sh offers this)" at_start U-LINKED

# claude-go keeps its own Claude Code config dir, so plain claude's user-level
# CLAUDE.md is invisible unless linked. Pinned here so a change is noticed.
HOME_SETUP='mkdir -p "$HOME/.claude"; echo "U-UNLINKED: rule" >"$HOME/.claude/CLAUDE.md"' turn
check "~/.claude/CLAUDE.md is NOT read unless linked (by design; see README)" eval '[[ $(first_seen U-UNLINKED) == none ]]'

finish instructions
