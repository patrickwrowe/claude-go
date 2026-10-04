#!/usr/bin/env bash
# Deny rules in config/claude-settings.json against a real Claude Code: the
# model's file tools cannot read the key file or change claude-go's guardrails
# or plain claude's configuration, even when an allow rule (standing in for a
# person approving a plausible-sounding request) grants exactly that.
# Needs `claude` and python3; see test/claude_harness.sh.
#
# Usage: test/deny.sh
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/claude_harness.sh"

keyfile="$work/config/claude-go/env"
canary="$here/config/deny-test-canary"   # a file the test must never create in this checkout
trap 'rm -f "$canary"' EXIT

# write <path as the model gives it> <allow rule>: the model asks Write for it.
write() {
  FAKE_TOOL="{\"name\": \"Write\", \"input\": {\"file_path\": \"$1\", \"content\": \"PLANTED\"}}" \
  HOME_SETUP='mkdir -p "$HOME/.claude/skills" "$HOME/.claude-go" && ln -s "$HOME/.claude/skills" "$HOME/.claude-go/skills"' \
  turn --permission-mode acceptEdits --allowedTools "$2"
}

echo "== file tools cannot touch secrets or guardrails, even when allowed ($("$CLAUDE_BIN" --version 2>/dev/null))"
FAKE_TOOL="{\"name\": \"Read\", \"input\": {\"file_path\": \"$keyfile\"}}" turn --allowedTools "Read(/$keyfile)"
check "Read of the key file is denied" eval '[[ -n $(tool_result) && $(tool_result) != *LITELLM_MASTER_KEY* ]]'

write '~/.claude/CLAUDE.md' 'Edit(~/.claude/**)'
check "plain claude's ~/.claude/CLAUDE.md cannot be written" test ! -e "$case_dir/home/.claude/CLAUDE.md"

write '~/.claude-go/skills/planted/SKILL.md' 'Edit(~/.claude-go/skills/**)'
check "a skill cannot be planted (through the ~/.claude-go/skills symlink)" test ! -e "$case_dir/home/.claude/skills/planted/SKILL.md"

write '~/.claude-go/settings.json' 'Edit(~/.claude-go/settings.json)'
check "claude-go's Claude Code settings cannot be written" test ! -e "$case_dir/home/.claude-go/settings.json"

write "$canary" "Edit(/$canary)"
check "the claude-go checkout's config cannot be written" test ! -e "$canary"

write 'notes.txt' 'Edit(notes.txt)'
check "ordinary writes in the repo still work" test -e "$case_dir/repo/notes.txt"

finish deny
