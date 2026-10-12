#!/usr/bin/env bash
# Build Vendor/GhosttyKit.xcframework (libghostty) from upstream Ghostty at $GHOSTTY_COMMIT.
# Needs Xcode with its licence accepted and the Metal toolchain (see `mise run doctor`), and Zig from mise.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/.cache/ghostty"
commit="${GHOSTTY_COMMIT:?set in mise.toml}"

if ! xcrun --find metal >/dev/null 2>&1; then
  echo "ghostty: no Metal compiler. Run: sudo xcodebuild -license accept && xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

if [ ! -d "$src/.git" ]; then
  git clone --filter=blob:none --no-checkout https://github.com/ghostty-org/ghostty "$src"
fi
git -C "$src" fetch --quiet --filter=blob:none origin "$commit"
git -C "$src" checkout --quiet --force "$commit"

cd "$src"
# Native arch only (this is a personal build); the macOS app itself is not needed.
zig build -Doptimize=ReleaseFast -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native

mkdir -p "$root/Vendor"
rm -rf "$root/Vendor/GhosttyKit.xcframework"
cp -R "$src/macos/GhosttyKit.xcframework" "$root/Vendor/"
echo "$commit" >"$root/Vendor/GhosttyKit.commit"
echo "ghostty: Vendor/GhosttyKit.xcframework built from $commit"
