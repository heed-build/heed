#!/usr/bin/env bash
# Assemble build/Heed.app from the SwiftPM products: the app binary, the `heed` helper (Contents/Helpers, put on every
# pane's PATH by the app, so nothing needs installing), Info.plist, then an ad-hoc signature.
#
#   scripts/bundle.sh debug|release
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-debug}"
products="$(cd "$root" && swift build -c "$config" --show-bin-path)"
app="${BUILD_DIR:-$root/build}/Heed.app"
version="0.1.0+$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$products/HeedApp" "$app/Contents/MacOS/Heed"
cp "$products/heed" "$app/Contents/Helpers/heed"
sed "s/__VERSION__/$version/g" "$root/Resources/Info.plist" >"$app/Contents/Info.plist"
codesign --force --sign - "$app/Contents/Helpers/heed"
codesign --force --sign - "$app"
# The helper must be the small CLI, never the app: hooks run it on every agent event.
if ! "$app/Contents/Helpers/heed" --help 2>/dev/null | grep -q '^usage: heed'; then
  echo "bundle: Contents/Helpers/heed is not the heed CLI" >&2
  exit 1
fi
echo "bundle: $app ($version)"
