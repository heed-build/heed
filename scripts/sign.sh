#!/usr/bin/env bash
# Sign build/Heed.app for distribution: Developer ID, the hardened runtime (notarization requires it) and a secure
# timestamp, inside out (Sparkle's helpers, then its framework, the heed helper, then the app). Replaces bundle.sh's ad-hoc signature.
#
#   scripts/sign.sh "Developer ID Application: Name (TEAMID)" [keychain]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
identity="${1:?usage: scripts/sign.sh <identity> [keychain]}"
app="${BUILD_DIR:-$root/build}/Heed.app"
keychain=()
[ -n "${2:-}" ] && keychain=(--keychain "$2")

sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
for target in "$sparkle/Autoupdate" "$sparkle/Updater.app" "$app/Contents/Frameworks/Sparkle.framework" \
  "$app/Contents/Helpers/heed" "$app"; do
  codesign --force --options runtime --timestamp --sign "$identity" ${keychain[@]+"${keychain[@]}"} "$target"
done
codesign --verify --strict --deep --verbose=2 "$app"
echo "sign: $app signed by $identity"
