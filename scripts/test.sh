#!/usr/bin/env bash
# The Swift Testing suite, built without the app. HeedCore has no dependencies and the tests only read the app's
# sources as text, so the test product needs neither HeedApp, MLX (Cmlx and its Metal shaders), Sparkle nor GhosttyKit:
# building only HeedPackageTests keeps all of them out of the compile. `mise run check` compiles the app.
#
#   scripts/test.sh [--skip-build] [swift test arguments, e.g. --filter AttentionTests]
set -euo pipefail
cd "$(dirname "$0")/.."

build=1
args=()
for arg in "$@"; do
  if [ "$arg" = "--skip-build" ]; then build=0; else args+=("$arg"); fi
done

if [ "$build" = 1 ]; then
  scripts/slot.sh swift build --product HeedPackageTests
fi
# ${args[@]+...}: an empty array is an unbound variable under `set -u` on macOS's bash 3.2.
exec swift test --skip-build --quiet ${args[@]+"${args[@]}"}
