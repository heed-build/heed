#!/usr/bin/env bash
# Run `swift` from Xcode when it is usable, else from the pinned swift.org toolchain (mise). The Command Line Tools'
# own swift-package is broken on some installs (missing BuildServerProtocol symbols), so it is never used.
set -euo pipefail
xcode="/Applications/Xcode.app/Contents/Developer"
if [ -d "$xcode" ] && DEVELOPER_DIR="$xcode" xcrun --find swift >/dev/null 2>&1; then
  export DEVELOPER_DIR="$xcode"
  exec xcrun swift "$@"
fi
# The newest CLT SDK can be ahead of this compiler; pick one whose Swift interface it can read.
SDKROOT="$("$(dirname "$0")/sdkroot.sh")" exec mise exec swift@6.3.3 -- swift "$@"
