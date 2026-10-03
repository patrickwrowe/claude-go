# shellcheck shell=bash
# Shared harness for tests that drive a real Claude Code through bin/claude-go.
# Source it from a test script; it needs `claude` on PATH (or CLAUDE_BIN) and
# python3, but no LiteLLM, Go key or network: test/fake_proxy.py stands in for
# the proxy and logs every request Claude Code sends, in full.
#
# Provides: $here $work, pass/bad/check, turn [claude args...], classifier_calls,
# tool_result, finish.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${HARNESS_PORT:-4197}"
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

# One headless turn (`claude-go -p go`) in a fresh git repo and a fresh HOME,
# with a clean environment so nothing from the calling shell (or a parent
# Claude Code) leaks in. $REPO_SETUP / $HOME_SETUP run first, in the repo / with
# HOME set; $FAKE_TOOL makes the model ask for that tool call (see fake_proxy.py).
# Sets $case_dir, $log (requests the proxy saw) and $init (the session's
# permission mode, from Claude Code's stream-json init message).
case_n=0
turn() {
  case_n=$((case_n + 1))
  case_dir="$work/case$case_n"
  mkdir -p "$case_dir/home" "$case_dir/repo"; git -C "$case_dir/repo" init -q
  [[ -n ${REPO_SETUP:-} ]] && (cd "$case_dir/repo" && eval "$REPO_SETUP")
  [[ -n ${HOME_SETUP:-} ]] && (HOME="$case_dir/home" && eval "$HOME_SETUP")
  log="$case_dir/requests.jsonl"
  (cd "$case_dir/repo" && env -i PATH="$PATH" TERM=dumb HOME="$case_dir/home" IS_SANDBOX="${IS_SANDBOX:-}" \
    XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
    CLAUDE_GO_LITELLM_BIN="$work/bin/litellm" CLAUDE_GO_CLAUDE_BIN="$CLAUDE_BIN" \
    CLAUDE_GO_START_TIMEOUT=20 CLAUDE_GO_QUIET=1 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    FAKE_LOG="$log" FAKE_TOOL="${FAKE_TOOL:-}" \
    timeout "${CLAUDE_TURN_TIMEOUT:-60}" "$here/bin/claude-go" --once -p "go" \
      --output-format stream-json --verbose "$@" </dev/null >"$case_dir/out.jsonl" 2>"$case_dir/err.txt")
  init="$(python3 -c '
import json, sys
for line in open(sys.argv[1]):
    try: o = json.loads(line)
    except ValueError: continue
    if o.get("type") == "system" and o.get("subtype") == "init": print(o.get("permissionMode")); break
' "$case_dir/out.jsonl")"
}

# Requests the auto-mode safety classifier received in the last turn.
classifier_calls() { python3 -c '
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1])] if os.path.exists(sys.argv[1]) else []
print(sum("security monitor" in r["system"] for r in rows))' "$log"; }

# What the last turn's tool call returned to the model (output or refusal).
tool_result() { python3 -c '
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1])] if os.path.exists(sys.argv[1]) else []
for r in rows:
    for m in r["messages"]:
        if "TOOL_RESULT:" in m["text"]:
            print(m["text"][m["text"].find("TOOL_RESULT:") + 12:]); sys.exit()' "$log"; }

finish() {
  echo
  if [[ $fail == 0 ]]; then echo "all $1 checks passed"; rm -rf "$work"; else echo "SOME $1 CHECKS FAILED (logs in $work)"; fi
  exit $fail
}
