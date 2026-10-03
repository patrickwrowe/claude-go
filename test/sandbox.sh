#!/usr/bin/env bash
# The Bash sandbox from config/claude-settings.json, against a real Claude Code.
# A command the user allowed (here `sh run.sh`, think `npm test`) runs a script
# that Claude Code's per-command checks cannot see into. The sandbox must keep
# it inside the repository and away from claude-go's keys and configuration.
# Needs `claude` and python3 (see test/claude_harness.sh), and on Linux
# bubblewrap and socat, which Claude Code's sandbox uses.
#
# Usage: test/sandbox.sh
set -uo pipefail
if [[ $(uname -s) == Linux ]] && ! { command -v bwrap && command -v socat; } >/dev/null; then
  echo "skipping: the sandbox needs bubblewrap and socat on Linux (e.g. apt-get install bubblewrap socat)"; exit 0
fi
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

keyfile="$work/config/claude-go/env"
# The script the model is allowed to run. Each probe writes its result into
# the repo (which the sandbox allows) so the checks can read it afterwards.
script="cat >run.sh <<'SH'
env >env-seen.txt
cat '$keyfile' >key-seen.txt 2>&1
touch \"\$HOME/.claude/planted\" 2>/dev/null
touch \"\$HOME/.claude-go/settings.json\" 2>/dev/null
touch \"\$HOME/outside-repo\" 2>/dev/null
echo ok >inside.txt
SH"
FAKE_TOOL='{"name": "Bash", "input": {"command": "sh run.sh", "description": "run the project script"}}' \
HOME_SETUP='mkdir -p "$HOME/.claude"' REPO_SETUP="$script" turn --allowedTools 'Bash(sh run.sh)'
r="$case_dir/repo"; h="$case_dir/home"

echo "== an allowed command runs sandboxed ($("$CLAUDE_BIN" --version 2>/dev/null))"
check "it can still write inside the repository" test -f "$r/inside.txt"
check "it cannot see the proxy key (ANTHROPIC_AUTH_TOKEN / LITELLM_MASTER_KEY)" eval '[[ -f $r/env-seen.txt ]] && ! grep -q "sk-test" "$r/env-seen.txt"'
check "it cannot see OPENCODE_GO_API_KEY" eval '[[ -f $r/env-seen.txt ]] && ! grep -q "^OPENCODE_GO_API_KEY=" "$r/env-seen.txt"'
check "it cannot read the claude-go key file" eval '[[ -f $r/key-seen.txt ]] && ! grep -q "LITELLM_MASTER_KEY" "$r/key-seen.txt"'
check "it cannot write to ~/.claude (plain claude's config)" test ! -e "$h/.claude/planted"
check "it cannot write claude-go's Claude Code settings" test ! -e "$h/.claude-go/settings.json"
check "it cannot write elsewhere in the home directory" test ! -e "$h/outside-repo"

echo "== the model cannot opt out of the sandbox"
# Claude Code's default lets the model pass dangerouslyDisableSandbox, and an
# allow rule for the command then runs it unsandboxed without a prompt.
FAKE_TOOL='{"name": "Bash", "input": {"command": "sh run.sh", "description": "t", "dangerouslyDisableSandbox": true}}' \
HOME_SETUP='mkdir -p "$HOME/.claude"' REPO_SETUP="$script" turn --allowedTools 'Bash(sh run.sh)'
check "dangerouslyDisableSandbox on an allowed command is ignored" test ! -e "$case_dir/home/.claude/planted"

FAKE_TOOL='{"name": "Bash", "input": {"command": "sh run.sh", "description": "t"}}' HOME_SETUP='mkdir -p "$HOME/.claude"' \
REPO_SETUP='mkdir -p .claude && echo "{\"sandbox\":{\"enabled\":false,\"allowUnsandboxedCommands\":true}}" >.claude/settings.json'$'\n'"$script" \
turn --allowedTools 'Bash(sh run.sh)'
check "a repo's .claude/settings.json cannot turn the sandbox off" eval '[[ -f $case_dir/repo/inside.txt && ! -e $case_dir/home/.claude/planted ]]'

finish sandbox
