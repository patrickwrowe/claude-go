# shellcheck shell=bash
# Shared helpers for bin/claude-go and bin/claude-go-ctl. Source, don't execute.

# ---------- paths ----------
CG_CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/claude-go"
CG_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/claude-go"
CG_ENV_FILE="${CLAUDE_GO_ENV_FILE:-$CG_CONFIG_HOME/env}"
CG_PID_FILE="$CG_STATE_HOME/proxy.pid"
CG_LOG_FILE="$CG_STATE_HOME/proxy.log"
CG_LOCK_DIR="$CG_STATE_HOME/start.lock"

cg_err()  { printf 'claude-go: %s\n' "$*" >&2; }
cg_info() { [[ -n ${CLAUDE_GO_QUIET:-} ]] || printf 'claude-go: %s\n' "$*" >&2; }

# ---------- configuration ----------
cg_load_env() {
  if [[ ! -f $CG_ENV_FILE ]]; then
    cg_err "no config at $CG_ENV_FILE. Run install.sh from the claude-go repo first."
    return 1
  fi
  local perms
  perms="$(ls -l "$CG_ENV_FILE" | cut -c5-10)"
  if [[ $perms != "------" ]]; then
    cg_err "warning: $CG_ENV_FILE is readable by other users (fix: chmod 600 '$CG_ENV_FILE')"
  fi
  set -a
  # shellcheck disable=SC1090
  . "$CG_ENV_FILE"
  set +a
  : "${OPENCODE_GO_API_KEY:?OPENCODE_GO_API_KEY missing from $CG_ENV_FILE}"
  : "${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY missing from $CG_ENV_FILE}"

  OPENCODE_GO_BASE="${OPENCODE_GO_BASE:-https://opencode.ai/zen/go}"
  OPENCODE_GO_BASE="${OPENCODE_GO_BASE%/}"
  # LiteLLM's anthropic provider appends /v1/messages itself; the OpenAI client wants the /v1 root.
  export CLAUDE_GO_ANTHROPIC_BASE="$OPENCODE_GO_BASE"
  export CLAUDE_GO_OPENAI_BASE="$OPENCODE_GO_BASE/v1"
  CLAUDE_GO_PORT="${CLAUDE_GO_PORT:-4141}"
  CG_URL="http://127.0.0.1:$CLAUDE_GO_PORT"
}

# ---------- Claude Code settings layer ----------
# config/claude-settings.json goes to every claude-go session as --settings.
# Flag settings outrank user (~/.claude-go/settings.json) and project
# (.claude/settings*.json) settings, so a cloned repository can't undo them.
# @CG_REPO@ in the file stands for this checkout's path.
cg_claude_settings() {
  local repo="$1" f="$1/config/claude-settings.json"
  [[ -f $f ]] || { cg_err "missing $f"; return 1; }
  case "$repo" in *[\"\\\|\&]*) cg_err "cannot use a claude-go checkout whose path contains \" \\ | or &: $repo"; return 1 ;; esac
  sed "s|@CG_REPO@|$repo|g" "$f"
}

cg_litellm_bin() {
  local b="${CLAUDE_GO_LITELLM_BIN:-}"
  [[ -z $b ]] && b="$(command -v litellm 2>/dev/null || true)"
  [[ -z $b && -x $HOME/.local/bin/litellm ]] && b="$HOME/.local/bin/litellm"
  [[ -n $b ]] || { cg_err "litellm not found; re-run install.sh"; return 1; }
  printf '%s\n' "$b"
}

cg_uuid() {
  if [[ -r /proc/sys/kernel/random/uuid ]]; then cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null; then uuidgen | tr 'A-Z' 'a-z'
  else od -An -tx1 -N16 /dev/urandom | tr -d ' \n'; echo
  fi
}

# ---------- proxy lifecycle ----------
# Healthy = our proxy answers on the port AND accepts our master key.
cg_proxy_healthy() {
  curl -sf -m 3 -o /dev/null "$CG_URL/health/liveliness" || return 1
  curl -sf -m 5 -o /dev/null -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$CG_URL/v1/models"
}

cg_proxy_pid() {
  [[ -f $CG_PID_FILE ]] || return 1
  local pid; pid="$(cat "$CG_PID_FILE")"
  kill -0 "$pid" 2>/dev/null || return 1
  # kill -0 succeeds for any PID the OS may have recycled since our last write,
  # so check the command line too. Match args rather than comm: comm is the
  # interpreter (python3) for env-shebang installs and a full path on macOS.
  local args; args="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  [[ $args == *litellm* && $args == *"--port ${CLAUDE_GO_PORT:-}"* ]] && printf '%s\n' "$pid"
}

# Sets CG_PROXY_STARTED=1 when this call launched the proxy (vs. reusing one).
cg_proxy_start() {
  local repo="$1" timeout="${CLAUDE_GO_START_TIMEOUT:-90}"
  CG_PROXY_STARTED=0
  cg_proxy_healthy && return 0
  mkdir -p "$CG_STATE_HOME"

  # Serialize concurrent starts (e.g. several claude-go sessions launched at once).
  local waited=0
  until mkdir "$CG_LOCK_DIR" 2>/dev/null; do
    if (( waited > timeout )); then cg_err "stale lock $CG_LOCK_DIR; removing"; rmdir "$CG_LOCK_DIR" 2>/dev/null; continue; fi
    sleep 1; waited=$((waited + 1))
    cg_proxy_healthy && return 0
  done
  local rc=0
  _cg_proxy_start_locked "$repo" "$timeout" || rc=$?
  rmdir "$CG_LOCK_DIR" 2>/dev/null
  return $rc
}

_cg_proxy_start_locked() {
  local repo="$1" timeout="$2"
  cg_proxy_healthy && return 0
  if curl -sf -m 2 -o /dev/null "$CG_URL/health/liveliness"; then
    cg_err "port $CLAUDE_GO_PORT is in use by something that rejects our key (another LiteLLM?)."
    cg_err "set CLAUDE_GO_PORT in $CG_ENV_FILE or stop the other process."
    return 1
  fi

  local litellm; litellm="$(cg_litellm_bin)" || return 1
  cg_info "starting LiteLLM proxy on 127.0.0.1:$CLAUDE_GO_PORT (log: $CG_LOG_FILE)"
  printf '\n=== %s start (claude-go %s)\n' "$(date '+%F %T')" "$(cat "$repo/VERSION")" >>"$CG_LOG_FILE"
  # Give the proxy its own process group so signals aimed at the terminal's
  # foreground group (Ctrl-C during `claude-go -p`) don't reach it: uvicorn
  # installs its own SIGINT handler, which overrides nohup/background SIG_IGN.
  # macOS has no setsid(1); job control (set -m) gives the same new group.
  # nohup on both paths ignores SIGHUP, as the proxy did before this change.
  local cmd=(nohup "$litellm" --config "$repo/config/litellm.yaml" --host 127.0.0.1 --port "$CLAUDE_GO_PORT")
  if command -v setsid >/dev/null 2>&1; then
    # A background job of a non-interactive shell isn't a group leader, so
    # setsid(1) execs in place without forking and $! is the proxy's PID.
    LITELLM_LOCAL_MODEL_COST_MAP=True setsid "${cmd[@]}" >>"$CG_LOG_FILE" 2>&1 </dev/null &
    echo $! >"$CG_PID_FILE"
  else
    ( set -m
      LITELLM_LOCAL_MODEL_COST_MAP=True "${cmd[@]}" >>"$CG_LOG_FILE" 2>&1 </dev/null &
      echo $! >"$CG_PID_FILE" )
  fi
  CG_PROXY_STARTED=1

  local i
  for ((i = 0; i < timeout; i++)); do
    if cg_proxy_healthy; then cg_info "proxy ready after ${i}s"; return 0; fi
    if ! cg_proxy_pid >/dev/null; then
      cg_err "proxy exited during startup; last log lines:"; tail -20 "$CG_LOG_FILE" >&2; return 1
    fi
    sleep 1
  done
  cg_err "proxy not healthy after ${timeout}s; see $CG_LOG_FILE"
  return 1
}

cg_proxy_stop() {
  local pid
  if pid="$(cg_proxy_pid)"; then
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 20); do kill -0 "$pid" 2>/dev/null || break; sleep 0.5; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    echo "stopped proxy (pid $pid)"
  else
    echo "proxy not running (no live pid in $CG_PID_FILE)"
  fi
  rm -f "$CG_PID_FILE"
}
