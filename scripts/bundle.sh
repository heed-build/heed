#!/usr/bin/env bash
# Assemble build/Heed.app from the SwiftPM products: the app binary, the `heed` helper (Contents/Helpers, put on every
# pane's PATH by the app, so nothing needs installing), Sparkle (Contents/Frameworks, the updater), Info.plist, then an
# ad-hoc signature.
#
#   scripts/bundle.sh debug|release
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-debug}"
products="$(cd "$root" && swift build -c "$config" --show-bin-path)"
app="${BUILD_DIR:-$root/build}/Heed.app"
# HEED_VERSION is set by the release workflow from the release's tag; local builds say dev. The build number is the
# commit count, which only grows on main (pull requests are squash-merged): the updater compares it to tell a newer
# release. HeedCommit names the commit, so any build can be traced back.
version="${HEED_VERSION:-0.1.0-dev}"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)"
commit="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo dev)"

mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$products/HeedApp" "$app/Contents/MacOS/Heed"
cp "$products/heed" "$app/Contents/Helpers/heed"
# Sparkle, symlinks kept. Its XPC services are for sandboxed apps; Heed is not sandboxed, so they go.
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$products/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
if ! otool -l "$app/Contents/MacOS/Heed" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$app/Contents/MacOS/Heed"
fi
sed -e "s/__VERSION__/$version/g" -e "s/__BUILD__/$build/g" -e "s/__COMMIT__/$commit/g" \
  "$root/Resources/Info.plist" >"$app/Contents/Info.plist"
# The app icon and the menu bar image (design/brand/ holds the full brand pack they come from).
cp "$root/Resources/heed.icns" "$root/Resources/menubar.svg" "$app/Contents/Resources/"
codesign --force --sign - "$app/Contents/Helpers/heed"
codesign --force --deep --sign - "$app/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$app"
# The helper must be the small CLI, never the app: hooks run it on every agent event.
if ! "$app/Contents/Helpers/heed" --help 2>/dev/null | grep -q '^usage: heed'; then
  echo "bundle: Contents/Helpers/heed is not the heed CLI" >&2
  exit 1
fi
echo "bundle: $app ($version, build $build, $commit)"
