#!/usr/bin/env bash
# Keys must not appear in process arguments (any local user can read those
# with ps), and install.sh must store any key exactly. Needs bash, curl and
# python3; no LiteLLM, uv, key or network (fakes stand in for all of them).
#
# Usage: test/secrets.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${SECRETS_TEST_PORT:-4192}"
work="$(mktemp -d)"
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$work"' EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else bad "$name"; fi; }

go_key="sk-go-ARGV-CANARY-$$"; master="sk-master-ARGV-CANARY-$$"
mkdir -p "$work/config/claude-go"
printf 'OPENCODE_GO_API_KEY=%s\nLITELLM_MASTER_KEY=%s\nOPENCODE_GO_BASE=http://127.0.0.1:%s\nCLAUDE_GO_PORT=%s\n' \
  "$go_key" "$master" "$PORT" "$PORT" >"$work/config/claude-go/env"
chmod 600 "$work/config/claude-go/env"

# One slow server plays both the proxy and the upstream, so each request is
# in flight long enough for ps to catch its arguments.
python3 - "$PORT" >/dev/null 2>&1 <<'PY' & pids+=($!)
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def reply(self):
        if not self.path.startswith("/health"): time.sleep(1.5)
        body = b'{"type": "message", "data": []}'
        self.send_response(200); self.send_header("content-length", str(len(body))); self.end_headers(); self.wfile.write(body)
    do_GET = do_POST = reply
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
for _ in $(seq 1 50); do curl -sf -o /dev/null "http://127.0.0.1:$PORT/health/x" && break; sleep 0.1; done

# watch <command...>: run it while sampling every process's arguments.
watch() {
  : >"$work/ps.log"
  env XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" "$@" >/dev/null 2>&1 & local c=$!
  while kill -0 "$c" 2>/dev/null; do ps -eo args >>"$work/ps.log" 2>/dev/null; sleep 0.05; done
  wait "$c" 2>/dev/null
}
not_in_ps() { ! grep -q -e "$go_key" -e "$master" "$work/ps.log"; }
seen_curl() { grep -q "curl .*127.0.0.1:$PORT" "$work/ps.log"; }

echo "== keys stay out of process arguments"
for cmd in status sync-models "test minimax-m3"; do
  # shellcheck disable=SC2086
  watch "$here/bin/claude-go-ctl" $cmd
  check "claude-go-ctl $cmd (curl was caught in flight: $(seen_curl && echo yes || echo no))" not_in_ps
done

echo "== install.sh stores the key exactly"
mkdir -p "$work/fakebin" "$work/home"
printf '#!/bin/sh\nexit 0\n' >"$work/fakebin/uv"; chmod +x "$work/fakebin/uv"
key="a'b&c|d\\e\$f g;h\`x\`"
env -i HOME="$work/home" PATH="$work/fakebin:/usr/bin:/bin" CLAUDE_GO_BIN_DIR="$work/home/bin" \
  OPENCODE_GO_API_KEY="$key" bash "$here/install.sh" --yes >/dev/null 2>&1
got="$(set -a; . "$work/home/.config/claude-go/env"; printf '%s' "$OPENCODE_GO_API_KEY")"
check "a key with ' & | \\ \$ space ; \` round-trips through the env file" eval '[[ $got == "$key" ]]'

echo
if [[ $fail == 0 ]]; then echo "all secrets checks passed"; else echo "SOME SECRETS CHECKS FAILED"; fi
exit $fail
