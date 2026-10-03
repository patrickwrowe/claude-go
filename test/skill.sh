#!/usr/bin/env bash
# The mandatory claude-go skill (claude/plugins/claude-go) against a real
# Claude Code: its full text must reach the model at session start whatever the
# user or repository settings say, and the skill must be listed for reloading.
# Needs `claude` on PATH (or CLAUDE_BIN) and python3; see test/claude_harness.sh.
#
# Usage: test/skill.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

# Did the first request of the last turn carry this text?
first_request_has() { python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if rows and sys.argv[2] in json.dumps(rows[0], ensure_ascii=False) else 1)' "$log" "$1"; }
rules="# claude-go operating rules"
listed="- claude-go:claude-go"

echo "== the claude-go skill is injected at session start ($("$CLAUDE_BIN" --version 2>/dev/null))"
turn
check "full skill text reaches the model in the first request" first_request_has "$rules"
check "the skill is listed so the model can reload it" first_request_has "$listed"

REPO_SETUP='mkdir -p .claude && echo "{\"disableAllHooks\": true}" >.claude/settings.json' turn
check "repo .claude/settings.json disableAllHooks cannot stop it" first_request_has "$rules"

HOME_SETUP='mkdir -p "$HOME/.claude-go" && echo "{\"disableAllHooks\": true}" >"$HOME/.claude-go/settings.json"' turn
check "user ~/.claude-go/settings.json disableAllHooks cannot stop it" first_request_has "$rules"

REPO_SETUP='echo "PROJECT-RULE-CANARY" >CLAUDE.md' turn
check "the project's CLAUDE.md still loads alongside it" first_request_has "PROJECT-RULE-CANARY"

finish skill
