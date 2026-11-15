#!/bin/bash
# Starts heed on the throwaway world from world.sh, as a copy of the app with a bundle id of its own, so it never
# collides with (or reads the preferences of) a Heed you use. Prints the pid; logs to <root>/heed.log.
#
#   docs/reels/demo/launch.sh <path to Heed.app> [root]
set -eu
app="${1:?usage: launch.sh <Heed.app> [root]}"
root="${2:-${DEMO_ROOT:-/tmp/heed-demo}}"
home="$root/home"
[ -d "$home" ] || { echo "no world at $root: run world.sh first" >&2; exit 1; }

copy="$root/Heed-demo.app"
rm -rf "$copy"
ditto "$app" "$copy"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.nullean.heed.demo" "$copy/Contents/Info.plist"
codesign --force --sign - "$copy/Contents/Helpers/heed" >/dev/null 2>&1
codesign --force --deep --sign - "$copy" >/dev/null 2>&1

env HOME="$home" CFFIXED_USER_HOME="$home" XDG_CONFIG_HOME="$home/.config" DEMO_ROOT="$root" \
  PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  nohup "$copy/Contents/MacOS/Heed" >"$root/heed.log" 2>&1 &
echo $!
