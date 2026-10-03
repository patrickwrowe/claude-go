#!/usr/bin/env bash
# PreToolUse hook for Bash: runs guard.py with whatever Python is available.
# python3 on PATH, else the interpreter of the uv-installed LiteLLM (which
# claude-go always has). With neither, fail closed: every Bash command goes to
# a person, because unchecked is not the same as safe.
here="$(cd "$(dirname "$0")" && pwd)"
py="$(command -v python3 || true)"
if [[ -z $py ]]; then
  tooldir="$(uv tool dir 2>/dev/null || true)"
  [[ -n $tooldir && -x $tooldir/litellm/bin/python ]] && py="$tooldir/litellm/bin/python"
fi
if [[ -z $py ]]; then
  cat >/dev/null
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"claude-go guard: no python3 to check this command, so a person must approve it (install python3 to restore automatic checks)."}}'
  exit 0
fi
exec "$py" "$here/guard.py"
