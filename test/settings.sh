#!/usr/bin/env bash
# Guardrail test: config/claude-settings.json against a real Claude Code.
# Needs `claude` on PATH (or CLAUDE_BIN) and python3. No LiteLLM, Go key or
# network: test/fake_proxy.py stands in for the proxy and logs every request
# Claude Code sends, in full, so the checks see what would have reached Go.
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

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${SETTINGS_TEST_PORT:-4197}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n $CLAUDE_BIN ]] || { echo "skipping: claude (Claude Code) not found; set CLAUDE_BIN"; exit 0; }
work="$(mktemp -d)"

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else bad "$name"; fi; }

mkdir -p "$work/bin" "$work/config/claude-go"
{ echo "#!$(command -v python3)"; tail -n +2 "$here/test/fake_proxy.py"; } >"$work/bin/litellm"
chmod +x "$work/bin/litellm"
printf 'OPENCODE_GO_API_KEY=test\nLITELLM_MASTER_KEY=sk-test\nCLAUDE_GO_PORT=%s\n' "$PORT" >"$work/config/claude-go/env"
chmod 600 "$work/config/claude-go/env"

# One headless turn in a fresh git repo and a fresh HOME, with a clean
# environment so nothing from the calling shell (or a parent Claude Code)
# leaks in. Sets $log (requests the proxy saw) and $init (the session's
# permission mode, from Claude Code's stream-json init message).
case_n=0
turn() {
  case_n=$((case_n + 1))
  local d="$work/case$case_n"
  mkdir -p "$d/home" "$d/repo"; git -C "$d/repo" init -q
  [[ -n ${REPO_SETUP:-} ]] && (cd "$d/repo" && eval "$REPO_SETUP")
  [[ -n ${HOME_SETUP:-} ]] && (HOME="$d/home" && eval "$HOME_SETUP")
  log="$d/requests.jsonl"
  (cd "$d/repo" && env -i PATH="$PATH" TERM=dumb HOME="$d/home" \
    XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
    CLAUDE_GO_LITELLM_BIN="$work/bin/litellm" CLAUDE_GO_CLAUDE_BIN="$CLAUDE_BIN" \
    CLAUDE_GO_START_TIMEOUT=20 CLAUDE_GO_QUIET=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    FAKE_LOG="$log" FAKE_TOOL="${FAKE_TOOL:-}" \
    timeout "${CLAUDE_TURN_TIMEOUT:-60}" "$here/bin/claude-go" --once -p "go" \
      --output-format stream-json --verbose "$@" </dev/null >"$d/out.jsonl" 2>"$d/err.txt")
  init="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: continue
    if o.get("type") == "system" and o.get("subtype") == "init": print(o.get("permissionMode")); break
' "$d/out.jsonl")"
}
classifier_calls() { python3 -c '
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1])] if os.path.exists(sys.argv[1]) else []
print(sum("security monitor" in r["system"] for r in rows))' "$log"; }

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
check "user SessionStart hook still runs despite repo disableAllHooks" test -f "$work/case$case_n/home/hook-ran"

echo
if [[ $fail == 0 ]]; then echo "all settings checks passed"; rm -rf "$work"; else echo "SOME SETTINGS CHECKS FAILED (logs in $work)"; fi
exit $fail
