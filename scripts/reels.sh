#!/usr/bin/env bash
# Records heed's films with reel (docs/reels/*.reel): every one, or the ones named (hero, brand/intro). They run on a
# throwaway world (docs/reels/demo/), never on your own heed, and take the mouse and keyboard while they play.
#
#   mise run reels                 every reel except brand/
#   mise run reels hero            one
#   mise run reels brand/intro     the branded intro and outro are recorded once and kept (intro.mov, outro.mov)
#
# HEED_APP   the Heed.app to film (default build/Heed.app; needs the accessibility ids, `mise run bundle`)
# REEL       the reel to run (default: reel on PATH; a build of reel 0.7 or later, for tracks)
# HEED_MEDIA a checkout of heed-build/media: the web cut is copied to $HEED_MEDIA/landing/<name>.mp4
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
export HEED_APP="${HEED_APP:-$root/build/Heed.app}"
reel="${REEL:-reel}"
[ -d "$HEED_APP" ] || { echo "reels: no app at $HEED_APP (mise run bundle, or set HEED_APP)" >&2; exit 1; }

names=()
if [ $# -gt 0 ]; then
  for name in "$@"; do names+=("docs/reels/${name%.reel}.reel"); done
else
  while IFS= read -r file; do names+=("$file"); done < <(find docs/reels -name '*.reel' -not -path 'docs/reels/brand/*' | sort)
fi

for file in "${names[@]}"; do
  echo "reels: recording $file"
  (cd "$(dirname "$file")" && "$reel" "$(basename "$file")")
  base="$(basename "$file" .reel)"
  cut="$(dirname "$file")/out/$base-web.mp4"
  if [ -n "${HEED_MEDIA:-}" ] && [ -f "$cut" ]; then
    mkdir -p "$HEED_MEDIA/landing"
    cp "$cut" "$HEED_MEDIA/landing/$base.mp4"
    echo "reels: $HEED_MEDIA/landing/$base.mp4"
  fi
done
