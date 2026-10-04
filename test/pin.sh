#!/usr/bin/env bash
# install.sh resolves LiteLLM's dependencies as of config/LITELLM_EXCLUDE_NEWER
# and refuses a malformed date. Runs in a throwaway HOME with a fake `uv` that
# records its arguments and environment; nothing is installed. Needs bash only.
#
# Usage: test/pin.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

mkdir -p "$work/bin" "$work/home"
printf '#!/usr/bin/env bash\necho "uv $* UV_EXCLUDE_NEWER=${UV_EXCLUDE_NEWER:-unset}" >>"$HOME/uv.log"\n' >"$work/bin/uv"
chmod +x "$work/bin/uv"

echo "== LiteLLM's dependencies are pinned by date"
date="$(cat "$here/config/LITELLM_EXCLUDE_NEWER")"
env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" bash "$here/install.sh" --litellm-only --yes >/dev/null 2>&1
if grep -q "^uv tool install .*litellm\[proxy\]==$(cat "$here/config/LITELLM_VERSION") UV_EXCLUDE_NEWER=$date\$" "$work/home/uv.log"; then
  pass "uv tool install runs with UV_EXCLUDE_NEWER=$date"
else
  bad "uv tool install does not get the date: $(grep 'tool install' "$work/home/uv.log")"
fi

cp -r "$here" "$work/repo" 2>/dev/null; echo "last tuesday" >"$work/repo/config/LITELLM_EXCLUDE_NEWER"
: >"$work/home/uv.log"
if ! env -i HOME="$work/home" PATH="$work/bin:/usr/bin:/bin" bash "$work/repo/install.sh" --litellm-only --yes >/dev/null 2>&1 \
   && ! grep -q "tool install" "$work/home/uv.log"; then
  pass "a malformed date stops the install"
else
  bad "a malformed date did not stop the install"
fi

echo
if [[ $fail == 0 ]]; then echo "all pin checks passed"; else echo "SOME PIN CHECKS FAILED"; fi
exit $fail
