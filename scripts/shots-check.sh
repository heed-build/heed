#!/bin/bash
# Renders every shot and the generated reference pages from the fake world into a scratch directory, and fails if any
# committed one differs from the fresh render, is missing, or is no longer rendered. CI runs it after the release
# build; locally `mise run shots` brings the committed ones up to date. Needs build/Heed.app (`mise run bundle`).
set -euo pipefail

out="${1:-$(mktemp -d)}"
mkdir -p "$out/shots" "$out/docs/keyboard" "$out/docs/configuration"

log="$out/render.log"
HEED_SHOTS="$out/shots" HEED_DOCS="$out/docs" build/Heed.app/Contents/MacOS/Heed | tee "$log"
if grep -q ' FAILED: ' "$log"; then
  echo "::error::Some shots failed to render (see above)." >&2
  exit 1
fi

stale=()
while IFS= read -r line; do stale+=("$line"); done < <(
  diff -rq docs/images/shots "$out/shots" | sed -e "s#$out/shots#fresh#" || true
  for page in keyboard/reference.md configuration/reference.md; do
    cmp -s "docs/$page" "$out/docs/$page" || echo "docs/$page differs"
  done
)

if [ "${#stale[@]}" -gt 0 ]; then
  echo "::error::${#stale[@]} committed shot(s) or reference page(s) differ from a fresh render." >&2
  printf '  %s\n' "${stale[@]}" >&2
  echo "Re-render them with \`mise run shots\` and commit the result; delete a shot that is only in docs/images/shots" >&2
  echo "(nothing renders it any more)." >&2
  exit 1
fi
echo "shots: every committed shot matches a fresh render"
