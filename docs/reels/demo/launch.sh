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

# A tiling window manager would resize the window straight back while a film sets its size: let Heed float (yabai).
if command -v yabai >/dev/null 2>&1; then
  yabai -m rule --remove heed-demo >/dev/null 2>&1 || true
  yabai -m rule --add label=heed-demo app='^Heed$' manage=off >/dev/null 2>&1 || true
fi

copy="$root/Heed-demo.app"
rm -rf "$copy"
ditto "$app" "$copy"
codesign_copy() {
  codesign --force --sign - "$copy/Contents/Helpers/heed" >/dev/null 2>&1
  codesign --force --deep --sign - "$copy" >/dev/null 2>&1
}

# The helper on PATH for cues (cue, demo-agent).
ln -sf "$copy/Contents/Helpers/heed" "$root/bin/heed"

# The tutor's title bar reminder hidden, as `:tutor.hide all` does: it is kept in the app's preferences. Preferences go
# through cfprefsd, which ignores CFFIXED_USER_HOME, so they live in ~/Library/Preferences/net.nullean.heed.demo.plist:
# the copy's own domain (never Heed's), wiped on every launch so each take starts alike.
defaults delete net.nullean.heed.demo >/dev/null 2>&1 || true
progress="$(printf '%s' '{"done":[],"lastStep":0,"hidden":["all"]}' | xxd -p | tr -d '\n')"
defaults write net.nullean.heed.demo tutorProgress -data "$progress"

# A seeded history (the ledger and the acme Mindmap, dated from now), written by a first, short run under a bundle id
# of its own, so a reel that waits for the app to open does not attach to it.
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.nullean.heed.demo.seed" "$copy/Contents/Info.plist"
codesign_copy
env HOME="$home" CFFIXED_USER_HOME="$home" HEED_SEED_WORLD=1 "$copy/Contents/MacOS/Heed" >"$root/seed.log" 2>&1

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.nullean.heed.demo" "$copy/Contents/Info.plist"
codesign_copy

# Through LaunchServices, so it comes to the front as a launched app does (a film's real keys go to the front app; heed
# itself never takes focus). The environment is the world's.
open -n --stdout "$root/heed.log" --stderr "$root/heed.log" \
  --env HOME="$home" --env CFFIXED_USER_HOME="$home" --env XDG_CONFIG_HOME="$home/.config" --env DEMO_ROOT="$root" \
  --env PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" "$copy"
sleep 1
pgrep -f "$copy/Contents/MacOS/Heed" | head -1
