#!/usr/bin/env bash
# SessionStart hook (startup, resume, /clear and compaction): put the claude-go
# skill in front of the model every time its context starts over. A skill is
# otherwise loaded only when the model decides to load it, which a model that
# is drifting from its instructions is least likely to do. Plain stdout from a
# SessionStart hook is added to the model's context.
cat >/dev/null # the hook's JSON input isn't needed
skill="$(dirname "$0")/../skills/claude-go/SKILL.md"
[[ -r $skill ]] || { echo "claude-go: cannot read $skill; the session is running without its rules" >&2; exit 1; }
echo "The claude-go skill is mandatory for this whole session and is already loaded; its full text follows."
echo "Re-read it (Skill tool: claude-go:claude-go) before any destructive, irreversible or outward-facing action."
echo
awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$skill"
