#!/usr/bin/env bash
# Print the developer directory this project builds with: Xcode if it is usable, else the Command Line Tools.
xcode="/Applications/Xcode.app/Contents/Developer"
if [ -d "$xcode" ] && DEVELOPER_DIR="$xcode" xcrun --find swiftc >/dev/null 2>&1; then
  echo "$xcode"
else
  echo "/Library/Developer/CommandLineTools"
fi
