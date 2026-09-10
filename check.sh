#!/bin/bash
# Everything that must still be true. Run before and after any change.
#
#   ./check.sh            fixtures + hook rules
#   ./check.sh --survey   also replay every real transcript on this machine
set -uo pipefail
cd "$(dirname "$0")"

fail=0
echo "== transcript derivation =="
"/Applications/ClaudeDeck.app/Contents/MacOS/ClaudeDeck" --validate ${1:-} || fail=1
echo
echo "== hook rules =="
node tests/validate-hook.js || fail=1
echo
[ $fail -eq 0 ] && echo "ALL PASS" || echo "FAILURES — do not ship"
exit $fail
