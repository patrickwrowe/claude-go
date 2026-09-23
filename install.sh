#!/usr/bin/env bash
# Install (or repair) claude-go on this machine. Safe to re-run.
#
#   ./install.sh                  interactive
#   ./install.sh --yes            accept defaults (installs uv if missing)
#   OPENCODE_GO_API_KEY=... ./install.sh --yes      non-interactive key
#   ./install.sh --litellm-only   just (re)install the pinned LiteLLM
set -euo pipefail

REPO="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CLAUDE_GO_BIN_DIR:-$HOME/.local/bin}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/claude-go"
ENV_FILE="$CONFIG_HOME/env"
CLAUDE_GO_HOME="${CLAUDE_GO_CONFIG_DIR:-$HOME/.claude-go}"
YES=0; LITELLM_ONLY=0
for a in "$@"; do
  case "$a" in
    -y|--yes) YES=1 ;;
    --litellm-only) LITELLM_ONLY=1 ;;
    -h|--help) sed -n 2,8p "$0"; exit 0 ;;
    *) echo "unknown option $a"; exit 2 ;;
  esac
done

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
ask()  { # ask "question" default -> echoes answer
  local q="$1" d="${2:-}" a
  if [[ $YES -eq 1 || ! -t 0 ]]; then echo "$d"; return; fi
  read -r -p "    $q ${d:+[$d] }" a; echo "${a:-$d}"
}

# ---------- 1. prerequisites ----------
say "checking prerequisites"
for b in bash curl git; do command -v "$b" >/dev/null || die "$b is required"; done
case "$(uname -s)" in Linux|Darwin) ;; *) die "unsupported OS $(uname -s) (use WSL on Windows)";; esac

if ! command -v uv >/dev/null && [[ ! -x $HOME/.local/bin/uv ]]; then
  [[ "$(ask "uv (Python tool installer) is missing. Install it from astral.sh? (y/n)" y)" == y ]] \
    || die "uv is required: https://docs.astral.sh/uv/"
  curl -LsSf https://astral.sh/uv/install.sh | sh
fi
UV="$(command -v uv || echo "$HOME/.local/bin/uv")"

# ---------- 2. LiteLLM (pinned) ----------
PIN="$(cat "$REPO/config/LITELLM_VERSION")"
case "$PIN" in 1.82.7|1.82.8) die "config/LITELLM_VERSION pins a compromised LiteLLM release ($PIN)";; esac
current="$("$UV" tool list 2>/dev/null | awk '/^litellm /{print $2}' | tr -d v || true)"
case "$current" in 1.82.7|1.82.8)
  echo "!!! Installed LiteLLM $current is a known-compromised release (March 2026 supply-chain attack)."
  echo "!!! It is being replaced; rotate any credentials that were on this machine."
  current="" ;;
esac
if [[ $current == "$PIN" ]]; then
  say "LiteLLM $PIN already installed"
else
  say "installing LiteLLM $PIN (proxy extra) with uv"
  "$UV" tool install --force --python 3.12 "litellm[proxy]==$PIN"
fi
[[ $LITELLM_ONLY -eq 1 ]] && exit 0

command -v claude >/dev/null || note "Claude Code (claude) is not on PATH yet. Install it: https://code.claude.com/docs"

# ---------- 3. secrets / config ----------
say "configuring $ENV_FILE"
mkdir -p "$CONFIG_HOME"; chmod 700 "$CONFIG_HOME"
if [[ -f $ENV_FILE ]] && grep -q '^OPENCODE_GO_API_KEY=.\+' "$ENV_FILE"; then
  note "existing config kept (edit it directly to change keys or tiers)"
else
  key="${OPENCODE_GO_API_KEY:-}"
  if [[ -z $key ]]; then
    [[ -t 0 ]] || die "no TTY: pass the key as OPENCODE_GO_API_KEY=... ./install.sh --yes"
    read -r -s -p "    OpenCode Go API key (from https://opencode.ai/auth): " key; echo
  fi
  [[ -n $key ]] || die "an OpenCode Go API key is required"
  master="sk-cgo-$(od -An -tx1 -N24 /dev/urandom | tr -d ' \n')"
  (umask 077; sed -e "s|^OPENCODE_GO_API_KEY=.*|OPENCODE_GO_API_KEY=$key|" \
                  -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$master|" \
                  "$REPO/config/env.example" >"$ENV_FILE")
  note "wrote $ENV_FILE (mode 600); the proxy master key was generated locally"
fi
chmod 600 "$ENV_FILE"

# ---------- 4. proxy config ----------
say "generating config/litellm.yaml"
bash "$REPO/scripts/gen-config.sh" | sed 's/^/    /'

# ---------- 5. commands on PATH ----------
say "linking commands into $BIN_DIR"
mkdir -p "$BIN_DIR"
for c in claude-go claude-go-ctl; do
  chmod +x "$REPO/bin/$c"
  ln -sfn "$REPO/bin/$c" "$BIN_DIR/$c"
  note "$BIN_DIR/$c -> $REPO/bin/$c"
done
case ":$PATH:" in *":$BIN_DIR:"*) ;; *) note "add $BIN_DIR to your PATH (e.g. in ~/.bashrc or ~/.zshrc)";; esac

# ---------- 6. isolated Claude Code config dir ----------
say "preparing Claude Code config dir $CLAUDE_GO_HOME"
note "claude-go keeps its own sessions/settings so /model picks never leak into plain claude."
mkdir -p "$CLAUDE_GO_HOME"
if [[ -d $HOME/.claude ]]; then
  for item in CLAUDE.md skills agents commands; do
    src="$HOME/.claude/$item"; dst="$CLAUDE_GO_HOME/$item"
    [[ -e $src && ! -e $dst && ! -L $dst ]] || continue
    if [[ "$(ask "share ~/.claude/$item with claude-go via symlink? (y/n)" y)" == y ]]; then
      ln -s "$src" "$dst"; note "linked $item"
    fi
  done
fi

# ---------- 7. verify ----------
say "running doctor"
PATH="$BIN_DIR:$PATH" "$REPO/bin/claude-go-ctl" doctor || true
cat <<EOF

Done. Next:
  claude-go-ctl test            # live round-trip, one model per protocol (a few tokens)
  claude-go                     # Claude Code on Go models (default: minimax-m3)
  claude-go --model kimi-k2.7-code
  claude-go-ctl models          # everything available + tier mapping
EOF
