#!/usr/bin/env bash
# Remove claude-go from this machine.
#   ./uninstall.sh           stop proxy, remove command links, uninstall LiteLLM if claude-go installed it
#   ./uninstall.sh --purge   also delete claude-go's config (keys), state and Claude Code dir (sessions)
set -euo pipefail
REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CLAUDE_GO_BIN_DIR:-$HOME/.local/bin}"
# shellcheck source=lib/common.sh
. "$REPO/lib/common.sh"
# claude-go's Claude Code config dir, as bin/claude-go sees it: the env file may set it.
CLAUDE_GO_HOME="$( set +eu; [[ -f $CG_ENV_FILE ]] && . "$CG_ENV_FILE" >/dev/null 2>&1
                   printf '%s' "${CLAUDE_GO_CONFIG_DIR:-$HOME/.claude-go}" )"
LITELLM_OWNER="$CG_STATE_HOME/litellm-installed-by-claude-go"

"$REPO/bin/claude-go-ctl" stop 2>/dev/null || true
for c in claude-go claude-go-ctl; do
  if [[ -L $BIN_DIR/$c ]]; then rm "$BIN_DIR/$c"; echo "removed $BIN_DIR/$c"; fi
done
if command -v uv >/dev/null && uv tool list 2>/dev/null | grep -q '^litellm '; then
  if [[ -f $LITELLM_OWNER ]]; then
    uv tool uninstall litellm && echo "uninstalled LiteLLM"
  else
    echo "kept LiteLLM: claude-go did not install it (uv tool uninstall litellm removes it)"
  fi
fi

# rm -rf one of claude-go's directories, unless it is (or contains) a home
# directory or plain claude's ~/.claude, e.g. CLAUDE_GO_CONFIG_DIR=~/.claude.
purge() {
  local dir="$1" real home
  if [[ -L $dir ]]; then rm "$dir"; echo "removed link $dir"; return; fi
  [[ -e $dir ]] || return 0
  real="$(cd -P "$dir" && pwd)"; home="$(cd -P "$HOME" && pwd)"
  if [[ $real == / || $real == "$home" || $real == "$home/.claude" || $home == "$real"/* ]]; then
    echo "REFUSED to delete $dir: it is (or contains) your home directory or plain claude's ~/.claude" >&2
    return 1
  fi
  rm -rf "$dir"; echo "deleted $dir"
}

if [[ ${1:-} == --purge ]]; then
  rc=0
  for d in "$CG_CONFIG_HOME" "$CG_STATE_HOME" "$CLAUDE_GO_HOME"; do purge "$d" || rc=1; done
  exit $rc
else
  echo "kept $CG_CONFIG_HOME (keys) and $CLAUDE_GO_HOME (sessions); use --purge to delete"
fi
