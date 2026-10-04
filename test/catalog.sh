#!/usr/bin/env bash
# config/models.tsv -> config/litellm.yaml: the committed YAML must match the
# catalog, and a malformed catalog row must stop generation instead of being
# skipped or turned into a second deployment. Needs bash and awk only.
#
# Usage: test/catalog.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "== the committed config matches the catalog"
bash "$here/scripts/gen-config.sh" "$here/config/models.tsv" "$work/litellm.yaml" >/dev/null 2>&1
if cmp -s "$work/litellm.yaml" "$here/config/litellm.yaml"; then pass "config/litellm.yaml is up to date (else: claude-go-ctl regen)"
else bad "config/litellm.yaml differs from what config/models.tsv generates (run: claude-go-ctl regen)"; fi

echo "== malformed rows stop generation"
# reject <description> <row> <expected message>
reject() {
  { cat "$here/config/models.tsv"; printf '%s\n' "$2"; } >"$work/cat.tsv"
  rm -f "$work/out.yaml"
  if ! out="$(bash "$here/scripts/gen-config.sh" "$work/cat.tsv" "$work/out.yaml" 2>&1)" \
     && [[ ! -e $work/out.yaml ]] && grep -q "$3" <<<"$out"; then
    pass "$1"
  else
    bad "$1 (got: ${out:0:200})"
  fi
}
reject "spaces instead of tabs"        'new-model messages yes note'                  'spaces instead of tabs'
reject "enabled other than yes/no"     $'new-model\tmessages\tYes\tnote'             'enabled must be yes or no'
reject "duplicate id"                  $'minimax-m3\tchat\tyes\tagain'               'duplicate model id'
reject "duplicate id, even disabled"   $'kimi-k3\tchat\tno\tagain'                   'duplicate model id'
reject "unknown protocol"              $'new-model\tmesages\tyes\tnote'              'unknown protocol'
reject "unknown protocol, disabled row" $'new-model\tresponse\tno\tnote'             'unknown protocol'
reject "id that would break the YAML"  $'bad: id\tmessages\tyes\tnote'               'may only use letters'

echo
if [[ $fail == 0 ]]; then echo "all catalog checks passed"; else echo "SOME CATALOG CHECKS FAILED"; fi
exit $fail
