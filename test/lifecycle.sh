#!/usr/bin/env bash
# Proxy lifecycle test for bin/claude-go and lib/common.sh. No LiteLLM, Go key,
# network or Claude Code needed: a fake `litellm` (tiny HTTP server that, like
# uvicorn, installs its own SIGINT handler) and a fake `claude` stand in.
#
# Covers: start on demand and reuse, argument pass-through, --once teardown,
# own process group (terminal Ctrl-C doesn't kill the proxy), PID-file checks
# (recycled PIDs, env-shebang installs), and the no-setsid (macOS) path.
#
# Usage: test/lifecycle.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${LIFECYCLE_PORT:-4198}"
work="$(mktemp -d)"
state="$work/state/claude-go"

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else bad "$name"; fi; }

# ---------- fakes ----------
mkdir -p "$work/bin" "$work/config/claude-go"
py="$(command -v python3)"
# Direct interpreter shebang, like a pip/uv-installed console script.
cat >"$work/bin/litellm" <<EOF
#!$py
import http.server, signal, sys
signal.signal(signal.SIGINT, lambda *a: sys.exit(130))
port = int(sys.argv[sys.argv.index('--port') + 1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"data": []}')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
EOF
# Same server behind '#!/usr/bin/env python3': the process runs as python3.
{ echo '#!/usr/bin/env python3'; tail -n +2 "$work/bin/litellm"; } >"$work/bin/litellm-env"
cat >"$work/bin/claude" <<'EOF'
#!/usr/bin/env bash
out=""; for a in "$@"; do out+="[$a]"; done
echo "claude args: $out"
[[ -n ${FAKE_CLAUDE_SLEEP:-} ]] && sleep "$FAKE_CLAUDE_SLEEP"
exit "${FAKE_CLAUDE_RC:-0}"
EOF
chmod +x "$work/bin/"*
printf 'OPENCODE_GO_API_KEY=test\nLITELLM_MASTER_KEY=sk-test\nCLAUDE_GO_PORT=%s\n' "$PORT" >"$work/config/claude-go/env"
chmod 600 "$work/config/claude-go/env"

run() {
  env HOME="$work/home" XDG_CONFIG_HOME="$work/config" XDG_STATE_HOME="$work/state" \
    CLAUDE_GO_LITELLM_BIN="${LITELLM:-$work/bin/litellm}" CLAUDE_GO_CLAUDE_BIN="$work/bin/claude" \
    CLAUDE_GO_START_TIMEOUT=20 "$@"
}
up()       { curl -sf -m 2 -o /dev/null "http://127.0.0.1:$PORT/health/liveliness"; }
down()     { local i; for i in $(seq 1 20); do up || return 0; sleep 0.25; done; return 1; }
pidfile()  { cat "$state/proxy.pid" 2>/dev/null; }
# Also kill strays so one failed check can't leave a proxy that later cases reuse.
stop()     { run "$here/bin/claude-go-ctl" stop >/dev/null 2>&1; pkill -f "$work/bin/litellm" 2>/dev/null; down; }
# Run claude-go in its own process group (like a terminal's foreground job) with
# a long-running claude, wait until claude is up, then Ctrl-C the whole group.
ctrl_c() {
  ( set -m; FAKE_CLAUDE_SLEEP=30 run "$here/bin/claude-go" "$@" >"$work/ctrl_c.out" 2>&1 & echo $! >"$work/grp" )
  local i; for i in $(seq 1 80); do grep -q "claude args" "$work/ctrl_c.out" && break; sleep 0.25; done
  kill -INT -- "-$(cat "$work/grp")" 2>/dev/null
}

cleanup() { stop; rm -rf "$work"; }
trap cleanup EXIT

up && { echo "port $PORT already in use; set LIFECYCLE_PORT"; exit 1; }

echo "== start on demand, reuse, pass-through"
out="$(run "$here/bin/claude-go" -p hi 2>&1)"
check "starts proxy on demand" up
check "claude gets args unchanged" grep -qF 'claude args: [-p][hi]' <<<"$out"
out="$(run "$here/bin/claude-go" --help 2>&1)"
check "second run reuses proxy" eval '! grep -q "starting LiteLLM" <<<"$out"'
check "--help goes to claude" grep -qF 'claude args: [--help]' <<<"$out"
out="$(run "$here/bin/claude-go" -p --once 2>&1)"
check "non-leading --once goes to claude" grep -qF 'claude args: [-p][--once]' <<<"$out"
check "no --once: proxy keeps running" up

echo "== process group"
pid="$(pidfile)"
check "pid file names the proxy" eval '[[ -n $pid ]] && ps -o args= -p "$pid" | grep -q litellm'
check "proxy leads its own process group" eval '[[ $(ps -o pgid= -p "$pid" | tr -d " ") == "$pid" ]]'
# Ctrl-C in a terminal signals the whole foreground group: claude-go, claude,
# and (without its own group) a proxy that this claude-go started.
stop; ctrl_c -p hi; sleep 1
check "SIGINT to claude-go's group leaves proxy up" up

echo "== --once"
out="$(run "$here/bin/claude-go" --once -p hi 2>&1)"
check "--once leaves an already-running proxy alone" up
check "--once is not passed to claude" grep -qF 'claude args: [-p][hi]' <<<"$out"
stop
FAKE_CLAUDE_RC=3 run "$here/bin/claude-go" --once -p hi >/dev/null 2>&1; rc=$?
check "--once propagates claude's exit code" eval '[[ $rc == 3 ]]'
check "--once stops the proxy it started" down
CLAUDE_GO_STOP_ON_EXIT=1 run "$here/bin/claude-go" -p hi >/dev/null 2>&1
check "CLAUDE_GO_STOP_ON_EXIT=1 stops the proxy" down
CLAUDE_GO_STOP_ON_EXIT=1 run "$here/bin/claude-go" --no-once -p hi >/dev/null 2>&1
check "--no-once overrides CLAUDE_GO_STOP_ON_EXIT" up
stop
ctrl_c --once -p hi
check "--once stops the proxy when interrupted" down

echo "== pid file checks"
sleep 300 & other=$!
echo "$other" >"$state/proxy.pid"
out="$(run "$here/bin/claude-go-ctl" stop 2>&1)"
check "unrelated process in pid file is not ours" grep -q "not running" <<<"$out"
check "...and is not killed" kill -0 "$other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
LITELLM="$work/bin/litellm-env" run "$here/bin/claude-go" -p hi >/dev/null 2>&1; rc=$?
check "env-shebang litellm starts" eval '[[ $rc == 0 ]] && up'
out="$(run "$here/bin/claude-go-ctl" stop 2>&1)"
check "env-shebang litellm is stopped by claude-go-ctl" eval 'grep -q "stopped proxy" <<<"$out" && down'

echo "== without setsid (macOS)"
nosetsid="$work/nosetsid"; mkdir -p "$nosetsid"
for t in bash env python3 curl cat ps mkdir rmdir date sleep tail seq rm ls cut tr od dirname readlink nohup pwd head grep; do
  p="$(command -v "$t")" && ln -s "$p" "$nosetsid/$t"
done
PATH="$nosetsid" run "$here/bin/claude-go" -p hi >/dev/null 2>&1; rc=$?
pid="$(pidfile)"
check "starts without setsid" eval '[[ $rc == 0 ]] && up'
check "proxy still leads its own process group" eval '[[ -n $pid && $(ps -o pgid= -p "$pid" | tr -d " ") == "$pid" ]]'
stop

echo
if [[ $fail == 0 ]]; then echo "all lifecycle checks passed"; else echo "SOME LIFECYCLE CHECKS FAILED"; fi
exit $fail
