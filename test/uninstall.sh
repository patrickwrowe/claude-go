#!/usr/bin/env bash
# install.sh / uninstall.sh must not delete or replace what claude-go doesn't
# own. Runs both in a throwaway HOME with a fake `uv` that records what it is
# asked to do, so nothing real is installed or removed. Needs bash only.
#
# Usage: test/uninstall.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else bad "$name"; fi; }

mkdir -p "$work/bin"
cat >"$work/bin/uv" <<'EOF'
#!/usr/bin/env bash
echo "uv $*" >>"$HOME/uv.log"
if [[ "$1 $2" == "tool list" && -n ${FAKE_LITELLM:-} ]]; then echo "litellm v$FAKE_LITELLM"; echo "- litellm"; fi
exit 0
EOF
chmod +x "$work/bin/uv"

# fresh_home: a HOME with plain claude's ~/.claude and a claude-go install.
fresh_home() {
  H="$work/home$((++n))"
  mkdir -p "$H/.claude/projects" "$H/.claude-go" "$H/.config/claude-go" "$H/.local/state/claude-go"
  echo "subscription history" >"$H/.claude/projects/s.jsonl"
  printf 'OPENCODE_GO_API_KEY=x\nLITELLM_MASTER_KEY=y\n' >"$H/.config/claude-go/env"
}
n=0
in_home() { env -i HOME="$H" PATH="$work/bin:/usr/bin:/bin" CLAUDE_GO_BIN_DIR="$H/.local/bin" "$@"; }

echo "== uninstall --purge"
fresh_home
in_home CLAUDE_GO_CONFIG_DIR="$H/.claude" bash "$here/uninstall.sh" --purge >"$work/out" 2>&1; rc=$?
check "CLAUDE_GO_CONFIG_DIR=~/.claude: plain claude's ~/.claude survives" test -f "$H/.claude/projects/s.jsonl"
check "...the refusal is reported and the exit code says so" eval '[[ $rc != 0 ]] && grep -q REFUSED "$work/out"'
check "...claude-go's own config is still purged" test ! -e "$H/.config/claude-go"

fresh_home
echo 'CLAUDE_GO_CONFIG_DIR=$HOME/.cg-sessions' >>"$H/.config/claude-go/env"; mkdir -p "$H/.cg-sessions"
in_home bash "$here/uninstall.sh" --purge >/dev/null 2>&1
check "a CLAUDE_GO_CONFIG_DIR set in the env file is the one purged" test ! -e "$H/.cg-sessions"

fresh_home
rmdir "$H/.claude-go"; ln -s "$H/.claude" "$H/.claude-go"
in_home bash "$here/uninstall.sh" --purge >/dev/null 2>&1
check "~/.claude-go as a link to ~/.claude: only the link goes" eval '[[ ! -L $H/.claude-go && -f $H/.claude/projects/s.jsonl ]]'

fresh_home
in_home CLAUDE_GO_CONFIG_DIR="$H" bash "$here/uninstall.sh" --purge >/dev/null 2>&1
check "CLAUDE_GO_CONFIG_DIR=\$HOME: home survives" test -f "$H/.claude/projects/s.jsonl"

echo "== LiteLLM claude-go did not install"
fresh_home
in_home FAKE_LITELLM=1.80.0 bash "$here/uninstall.sh" >/dev/null 2>&1
check "uninstall leaves someone else's LiteLLM alone" eval '! grep -q "tool uninstall" "$H/uv.log"'
fresh_home
in_home FAKE_LITELLM=1.80.0 bash "$here/install.sh" --litellm-only --yes >/dev/null 2>&1; rc=$?
check "install --yes does not replace it (and fails, saying why)" eval '[[ $rc != 0 ]] && ! grep -q "tool install" "$H/uv.log"'

echo "== LiteLLM claude-go installed"
fresh_home
in_home bash "$here/install.sh" --litellm-only --yes >/dev/null 2>&1
check "install records that it installed LiteLLM" test -f "$H/.local/state/claude-go/litellm-installed-by-claude-go"
in_home FAKE_LITELLM=1.80.0 bash "$here/install.sh" --litellm-only --yes >/dev/null 2>&1; rc=$?
check "a later pin change replaces its own LiteLLM" eval '[[ $rc == 0 ]] && [[ $(grep -c "tool install" "$H/uv.log") == 2 ]]'
in_home FAKE_LITELLM="$(cat "$here/config/LITELLM_VERSION")" bash "$here/uninstall.sh" >/dev/null 2>&1
check "uninstall removes the LiteLLM it installed" grep -q "tool uninstall litellm" "$H/uv.log"

echo
if [[ $fail == 0 ]]; then echo "all install/uninstall checks passed"; else echo "SOME INSTALL/UNINSTALL CHECKS FAILED"; fi
exit $fail
