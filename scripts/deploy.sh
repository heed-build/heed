#!/usr/bin/env bash
# Copy the built app to $HEED_DEPLOY_DIR (e.g. a mounted network share). Never fails the build.
set -uo pipefail
app="${1:-$BUILD_DIR/Heed.app}"
dest="${HEED_DEPLOY_DIR:-}"
if [ -z "$dest" ]; then
  exit 0
fi
if [ ! -d "$dest" ]; then
  echo "deploy: skipped, '$dest' is not mounted (connect to it in Finder: Go > Connect to Server)"
  exit 0
fi
if rsync -a --delete "$app" "$dest/"; then
  echo "deploy: copied $(basename "$app") to $dest"
else
  echo "deploy: copy to $dest failed (continuing)"
fi
