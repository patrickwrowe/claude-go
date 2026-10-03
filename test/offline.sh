#!/usr/bin/env bash
# Offline end-to-end test. No Go key or network access to opencode.ai needed.
#
# Starts test/mock_go.py (fake Go API) and a real LiteLLM proxy using the
# generated config, sends one request per protocol (streaming and not), then
# checks what arrived "upstream": path, auth, User-Agent, session headers.
# If `claude` is on PATH (or CLAUDE_BIN is set), also runs a real headless
# Claude Code turn through the proxy for each protocol.
#
# Usage: test/offline.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_PORT="${MOCK_PORT:-8765}"
PROXY_PORT="${PROXY_PORT:-4199}"
work="$(mktemp -d)"
export MOCK_LOG="$work/upstream.jsonl" MOCK_KEY="test-go-key"
export CLAUDE_GO_ANTHROPIC_BASE="http://127.0.0.1:$MOCK_PORT"
export CLAUDE_GO_OPENAI_BASE="http://127.0.0.1:$MOCK_PORT/v1"
export OPENCODE_GO_API_KEY="test-go-key"
export LITELLM_MASTER_KEY="sk-offline-test"
export LITELLM_LOCAL_MODEL_COST_MAP=True
LITELLM_BIN="${LITELLM_BIN:-$(command -v litellm || echo "$HOME/.local/bin/litellm")}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"

pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

python3 "$here/test/mock_go.py" "$MOCK_PORT" >"$work/mock.out" 2>&1 & pids+=($!)
"$LITELLM_BIN" --config "$here/config/litellm.yaml" --host 127.0.0.1 --port "$PROXY_PORT" \
  >"$work/litellm.log" 2>&1 & pids+=($!)

echo "waiting for proxy on :$PROXY_PORT ..."
for _ in $(seq 1 90); do
  curl -sf "http://127.0.0.1:$PROXY_PORT/health/liveliness" >/dev/null && break
  sleep 1
done
curl -sf "http://127.0.0.1:$PROXY_PORT/health/liveliness" >/dev/null || { tail -30 "$work/litellm.log"; echo "proxy did not start"; exit 1; }

echo "== raw /v1/messages requests (one model per protocol)"
for m in minimax-m3 kimi-k2.7-code gpt-5.6-luna; do
  for s in false true; do
    out="$(curl -s -m 60 "http://127.0.0.1:$PROXY_PORT/v1/messages" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "content-type: application/json" \
      -H "anthropic-version: 2023-06-01" \
      -H "x-opencode-session: sess-offline" -H "x-claude-code-session-id: cc-offline" \
      -d "{\"model\":\"$m\",\"max_tokens\":50,\"stream\":$s,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}")"
    if grep -q "pong from mock" <<<"$out"; then pass "$m stream=$s"; else bad "$m stream=$s: ${out:0:300}"; fi
  done
done

echo "== what reached upstream"
python3 - "$MOCK_LOG" <<'PY' || fail=1
import json, sys
want = {"minimax-m3": "/v1/messages", "kimi-k2.7-code": "/v1/chat/completions", "gpt-5.6-luna": "/v1/responses"}
rows = [json.loads(l) for l in open(sys.argv[1])]
ok = True
for model, path in want.items():
    hits = [r for r in rows if r["model"] == model]
    if not hits:
        print(f"  \033[31mFAIL\033[0m {model}: never reached upstream"); ok = False; continue
    for r in hits:
        h = r["headers"]
        checks = {
            f"path {path}": r["path"].split("?")[0] == path,
            "auth": h.get("x-api-key") == "test-go-key" or h.get("authorization") == "Bearer test-go-key",
            "user-agent claude-go/*": h.get("user-agent", "").startswith("claude-go/"),
            "x-opencode-session": h.get("x-opencode-session") == "sess-offline",
            "x-claude-code-session-id": h.get("x-claude-code-session-id") == "cc-offline",
            "no proxy key leaked": "sk-offline-test" not in json.dumps(h),
        }
        failed = [k for k, v in checks.items() if not v]
        tag = "\033[32mPASS\033[0m" if not failed else "\033[31mFAIL\033[0m"
        print(f"  {tag} {model} stream={r['stream']} -> {r['path']}" + (f"  missing: {failed}  UA={h.get('user-agent')}" if failed else ""))
        ok &= not failed
sys.exit(0 if ok else 1)
PY

echo "== one failing request, one upstream attempt (Claude Code does the retrying)"
for m in minimax-m3 kimi-k2.7-code gpt-5.6-luna; do
  for st in 429 500; do
    code="$(curl -s -o /dev/null -w '%{http_code}' -m 60 "http://127.0.0.1:$PROXY_PORT/v1/messages" \
      -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H "content-type: application/json" \
      -H "anthropic-version: 2023-06-01" -H "x-mock-status: $st" -H "x-retry-probe: $m-$st" \
      -d "{\"model\":\"$m\",\"max_tokens\":20,\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}]}")"
    n="$(grep -c "\"x-retry-probe\": \"$m-$st\"" "$MOCK_LOG")"
    if [[ $n == 1 && $code == "$st" ]]; then pass "$m upstream $st: 1 attempt, client gets $code"; else bad "$m upstream $st: $n upstream attempts, client got $code"; fi
  done
done

if [[ -n "$CLAUDE_BIN" ]]; then
  echo "== real Claude Code turns through the proxy ($("$CLAUDE_BIN" --version 2>/dev/null))"
  for m in minimax-m3 kimi-k2.7-code gpt-5.6-luna; do
    out="$(ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT" ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY" \
      ANTHROPIC_API_KEY="" CLAUDE_CONFIG_DIR="$work/claude-config" \
      ANTHROPIC_CUSTOM_HEADERS="x-opencode-session: sess-cc" \
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-flash \
      timeout "${CLAUDE_TURN_TIMEOUT:-90}" "$CLAUDE_BIN" -p "say ping" --model "$m" 2>&1)"
    if grep -q "pong from mock" <<<"$out"; then pass "claude -p --model $m (text)"; else bad "claude -p --model $m (text): ${out:0:400}"; fi

    # Tool round-trip: mock asks for Bash `echo TOOL_$((6*7))`, Claude Code runs
    # it locally and sends TOOL_42 back; the mock only answers "round-trip ok"
    # if the tool result survived translation in both directions.
    out="$(cd "$work" && ANTHROPIC_BASE_URL="http://127.0.0.1:$PROXY_PORT" ANTHROPIC_AUTH_TOKEN="$LITELLM_MASTER_KEY" \
      ANTHROPIC_API_KEY="" CLAUDE_CONFIG_DIR="$work/claude-config" \
      ANTHROPIC_CUSTOM_HEADERS="x-opencode-session: sess-cc" \
      CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1 CLAUDE_CODE_ATTRIBUTION_HEADER=0 \
      CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
      ANTHROPIC_DEFAULT_HAIKU_MODEL=qwen3.8-flash \
      timeout "${CLAUDE_TURN_TIMEOUT:-90}" "$CLAUDE_BIN" -p "USE_TOOL: run the command you are given" \
        --model "$m" --allowedTools "Bash" 2>&1)"
    if grep -q "round-trip ok TOOL_42" <<<"$out"; then pass "claude -p --model $m (tool call round-trip)"; else bad "claude -p --model $m (tool call): ${out:0:400}"; fi
  done
  python3 - "$MOCK_LOG" <<'PY'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if '"sess-cc"' in l]
tools = max((r["n_tools"] for r in rows), default=0)
print(f"  Claude Code sent {len(rows)} upstream requests; largest tool list forwarded: {tools} tools")
print("  upstream paths:", sorted({(r['model'], r['path'].split('?')[0]) for r in rows}))
PY
else
  echo "== skipping Claude Code turns (claude not found; set CLAUDE_BIN to enable)"
fi

echo
if [[ $fail -eq 0 ]]; then echo "ALL OFFLINE TESTS PASSED"; else echo "SOME TESTS FAILED (logs in $work)"; trap - EXIT; cleanup; fi
exit $fail
