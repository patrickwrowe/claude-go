#!/usr/bin/env bash
# Guardrail test: config/claude-settings.json against a real Claude Code.
# Needs `claude` on PATH (or CLAUDE_BIN) and python3; see test/claude_harness.sh.
#
# Covers, through bin/claude-go:
#   - auto mode is off: the session doesn't start in it, and its safety
#     classifier (which Claude Code runs on the sonnet-tier model, i.e. a Go
#     model under claude-go) never receives a request;
#   - user settings, a repository's .claude/settings.json and --permission-mode
#     cannot turn it back on;
#   - a repository's .claude/settings.json cannot switch off the user's hooks.
#
# Usage: test/settings.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

# The model asks to read the environment: auto mode sends that to its classifier.
export FAKE_TOOL='{"name": "Bash", "input": {"command": "env | grep -c HOME", "description": "read env"}}'

echo "== auto mode stays off ($("$CLAUDE_BIN" --version 2>/dev/null))"
turn
check "session does not start in auto mode (got: ${init:-none})" eval '[[ -n $init && $init != auto ]]'
check "no request reaches the auto-mode classifier" eval '[[ $(classifier_calls) == 0 ]]'

turn --permission-mode auto
check "--permission-mode auto is refused (got: ${init:-none})" eval '[[ $init != auto && $(classifier_calls) == 0 ]]'

HOME_SETUP='mkdir -p "$HOME/.claude-go" && echo "{\"permissions\":{\"defaultMode\":\"auto\"}}" >"$HOME/.claude-go/settings.json"' turn
check "user settings defaultMode=auto is overridden (got: ${init:-none})" eval '[[ $init != auto && $(classifier_calls) == 0 ]]'

REPO_SETUP='mkdir -p .claude && echo "{\"permissions\":{\"defaultMode\":\"auto\"}}" >.claude/settings.json' turn
check "repo .claude/settings.json defaultMode=auto is overridden (got: ${init:-none})" eval '[[ $init != auto && $(classifier_calls) == 0 ]]'

echo "== a repository cannot switch off hooks"
unset FAKE_TOOL
hook='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch \"$HOME/hook-ran\""}]}]}}'
HOME_SETUP="mkdir -p \"\$HOME/.claude-go\" && printf '%s' '$hook' >\"\$HOME/.claude-go/settings.json\"" \
REPO_SETUP='mkdir -p .claude && echo "{\"disableAllHooks\": true}" >.claude/settings.json' turn
check "user SessionStart hook still runs despite repo disableAllHooks" test -f "$case_dir/home/hook-ran"

finish settings
