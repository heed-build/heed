#!/bin/bash
# Plays every tutor lesson with the real keys on its fake world in build/Heed.app (build it first: `mise run bundle`)
# and reports the steps that do not tick off. The summary line is the proof it ran: an app that exits early (another
# Heed running, a crash) prints none, so no summary fails as surely as a problem does. `mise run tutor-check` and CI
# both run this.
set -uo pipefail
cd "$(dirname "$0")/.."
status=0
out="$(HEED_TUTOR_CHECK=1 build/Heed.app/Contents/MacOS/Heed)" || status=$?
printf '%s\n' "$out"
[ "$status" = 0 ] || exit "$status"
printf '%s\n' "$out" | grep -q '^tutor-check: [0-9][0-9]* problems*$' \
    || { echo "tutor-check did not run: no summary line" >&2; exit 1; }
