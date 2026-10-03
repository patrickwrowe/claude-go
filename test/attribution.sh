#!/usr/bin/env bash
# Commit / PR attribution against a real Claude Code: work done under claude-go
# must say it came from claude-go and which Go model, not from Claude.
# Needs `claude` and python3; see test/claude_harness.sh.
#
# Usage: test/attribution.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

# Did the first request of the last turn carry this text?
first_request_has() { python3 -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if rows and sys.argv[2] in json.dumps(rows[0], ensure_ascii=False) else 1)' "$log" "$1"; }
version="$(cat "$here/VERSION")"

echo "== attribution names claude-go and the Go model ($("$CLAUDE_BIN" --version 2>/dev/null))"
turn
check "commits are signed by claude-go and the default model" first_request_has "Generated-by: claude-go $version (Claude Code on OpenCode Go; session started on minimax-m3"
check "PRs say claude-go and the default model" first_request_has "Generated with claude-go $version: Claude Code on OpenCode Go, session started on minimax-m3"
check "nothing claims an Anthropic co-author" eval '! first_request_has "Co-Authored-By: Claude"'

turn --model glm-5.2
check "--model is reflected" first_request_has "session started on glm-5.2"

finish attribution
