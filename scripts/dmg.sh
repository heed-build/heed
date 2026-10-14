#!/bin/bash
# Builds the drag-to-Applications disk image: scripts/dmg.sh <Heed.app> <out.dmg> [identity [keychain]]
# heed.app and a link to /Applications over packaging/dmg/background.tiff, laid out by dmgbuild (which writes the
# Finder layout itself, so it works without a GUI, on CI too). With an identity the image is signed as well; the
# release notarizes and staples it after.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:?usage: scripts/dmg.sh <Heed.app> <out.dmg> [identity [keychain]]}"
out="${2:?usage: scripts/dmg.sh <Heed.app> <out.dmg> [identity [keychain]]}"
identity="${3:-}"
keychain="${4:-}"
[ -d "$app" ] || { echo "no app at $app" >&2; exit 1; }

# dmgbuild in a venv of its own, pinned, made once per machine.
venv="${HEED_DMG_VENV:-${TMPDIR:-/tmp}/heed-dmgbuild-1.6.7}"
if [ ! -x "$venv/bin/dmgbuild" ]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet dmgbuild==1.6.7
fi

mkdir -p "$(dirname "$out")"
rm -f "$out"
"$venv/bin/dmgbuild" -s packaging/dmg/settings.py -D app="$(cd "$(dirname "$app")" && pwd)/$(basename "$app")" \
  -D background="$PWD/packaging/dmg/background.tiff" \
  "Heed" "$out"

if [ -n "$identity" ]; then
  codesign --force --timestamp --sign "$identity" ${keychain:+--keychain "$keychain"} "$out"
  codesign --verify --verbose=2 "$out"
fi
echo "built $out ($(du -h "$out" | cut -f1))"
