#!/usr/bin/env bash
# Remove claude-go from this machine.
#   ./uninstall.sh           stop proxy, remove command links, uninstall LiteLLM
#   ./uninstall.sh --purge   also delete ~/.config/claude-go (keys) and ~/.claude-go (sessions)
set -euo pipefail
REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CLAUDE_GO_BIN_DIR:-$HOME/.local/bin}"
"$REPO/bin/claude-go-ctl" stop 2>/dev/null || true
for c in claude-go claude-go-ctl; do
  if [[ -L $BIN_DIR/$c ]]; then rm "$BIN_DIR/$c"; echo "removed $BIN_DIR/$c"; fi
done
if command -v uv >/dev/null && uv tool list 2>/dev/null | grep -q '^litellm '; then
  uv tool uninstall litellm && echo "uninstalled LiteLLM"
fi
if [[ ${1:-} == --purge ]]; then
  rm -rf "${XDG_CONFIG_HOME:-$HOME/.config}/claude-go" "${XDG_STATE_HOME:-$HOME/.local/state}/claude-go"
  rm -rf "${CLAUDE_GO_CONFIG_DIR:-$HOME/.claude-go}"
  echo "purged config, state and ~/.claude-go"
else
  echo "kept ~/.config/claude-go (keys) and ~/.claude-go (sessions); use --purge to delete"
fi
