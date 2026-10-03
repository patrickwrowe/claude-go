#!/usr/bin/env bash
# Guardrail test: bypassPermissions mode stays off under claude-go, and the
# dontAsk mode that the Gas Town preset uses instead behaves as documented.
# Needs `claude` on PATH (or CLAUDE_BIN) and python3; see test/claude_harness.sh.
#
# Usage: test/bypass.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"
# Claude Code also refuses bypass mode for root; IS_SANDBOX stops that from
# masking the check when the test runs as root (e.g. in a container).
export IS_SANDBOX=1

echo "== bypassPermissions stays off ($("$CLAUDE_BIN" --version 2>/dev/null))"
HOME_SETUP='mkdir -p "$HOME/.claude-go" && echo "{\"permissions\":{\"defaultMode\":\"bypassPermissions\"}}" >"$HOME/.claude-go/settings.json"' turn
check "user settings defaultMode=bypassPermissions is overridden (got: ${init:-none})" eval '[[ -n $init && $init != bypassPermissions ]]'

echo "== dontAsk (Gas Town preset): allowed commands run, the rest are denied without a prompt"
allow='mkdir -p "$HOME/.claude-go" && echo "{\"permissions\":{\"allow\":[\"Bash(echo:*)\"]}}" >"$HOME/.claude-go/settings.json"'
FAKE_TOOL='{"name": "Bash", "input": {"command": "echo allowed-ran", "description": "t"}}' HOME_SETUP="$allow" turn --permission-mode dontAsk
check "allowlisted command runs" eval '[[ $(tool_result) == *allowed-ran* ]]'
FAKE_TOOL='{"name": "Bash", "input": {"command": "touch not-allowed", "description": "t"}}' HOME_SETUP="$allow" turn --permission-mode dontAsk
check "other command is denied" eval '[[ ! -e $case_dir/repo/not-allowed && $(tool_result) == *"don'"'"'t ask mode"* ]]'

finish bypass
