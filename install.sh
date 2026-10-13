#!/bin/sh
# Install or update Heed: curl -fsSL https://heed.build/install.sh | sh
#
# Downloads the latest release (or HEED_VERSION=0.1.0), checks its sha256, and puts Heed.app in /Applications, or
# ~/Applications when /Applications is not writable (HEED_APP_DIR overrides both; HEED_DOWNLOAD_BASE downloads from
# elsewhere). Downloaded with curl, the app
# carries no quarantine flag, so it opens without a Gatekeeper prompt.
set -eu

repo="heed-build/heed"
asset="Heed-arm64.zip"

fail() {
  echo "heed: $*" >&2
  exit 1
}

[ "$(uname -s)" = "Darwin" ] || fail "Heed is a macOS app."
[ "$(uname -m)" = "arm64" ] || fail "Heed builds for Apple Silicon only, for now."

if [ -n "${HEED_DOWNLOAD_BASE:-}" ]; then
  # A mirror, or a local server when testing this script.
  base="$HEED_DOWNLOAD_BASE"
elif [ -n "${HEED_VERSION:-}" ]; then
  base="https://github.com/$repo/releases/download/v${HEED_VERSION#v}"
else
  base="https://github.com/$repo/releases/latest/download"
fi

if [ -n "${HEED_APP_DIR:-}" ]; then
  dir="$HEED_APP_DIR"
elif [ -w /Applications ]; then
  dir="/Applications"
else
  dir="$HOME/Applications"
fi
mkdir -p "$dir"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "heed: downloading $base/$asset"
curl -fsSL -o "$tmp/$asset" "$base/$asset" || fail "download failed (is there a release yet?)"
curl -fsSL -o "$tmp/$asset.sha256" "$base/$asset.sha256" || fail "checksum download failed"
(cd "$tmp" && shasum -a 256 -c "$asset.sha256" >/dev/null) || fail "checksum does not match; nothing installed"

ditto -x -k "$tmp/$asset" "$tmp/app"
[ -x "$tmp/app/Heed.app/Contents/MacOS/Heed" ] || fail "the download holds no Heed.app; nothing installed"

if pgrep -xq Heed; then
  echo "heed: Heed is running; quit it to finish, or it keeps the old version until it restarts."
fi
rm -rf "$dir/Heed.app"
mv "$tmp/app/Heed.app" "$dir/Heed.app"

version="$(plutil -extract CFBundleShortVersionString raw "$dir/Heed.app/Contents/Info.plist" 2>/dev/null || echo "?")"
echo "heed: Heed $version is in $dir. Open it with: open -a Heed"
