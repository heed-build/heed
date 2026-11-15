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
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier net.nullean.heed.demo" "$copy/Contents/Info.plist"
codesign --force --sign - "$copy/Contents/Helpers/heed" >/dev/null 2>&1
codesign --force --deep --sign - "$copy" >/dev/null 2>&1

# The helper on PATH for cues (cue, demo-agent) and a seeded history: the ledger and the acme Mindmap, dated from now.
ln -sf "$copy/Contents/Helpers/heed" "$root/bin/heed"
# The tutor's title bar reminder hidden, as `:tutor.hide all` does: it is kept in the app's preferences. Preferences go
# through cfprefsd, which ignores CFFIXED_USER_HOME, so they live in ~/Library/Preferences/net.nullean.heed.demo.plist:
# the copy's own domain (never Heed's), wiped on every launch so each take starts alike.
defaults delete net.nullean.heed.demo >/dev/null 2>&1 || true
progress="$(printf '%s' '{"done":[],"lastStep":0,"hidden":["all"]}' | xxd -p | tr -d '\n')"
defaults write net.nullean.heed.demo tutorProgress -data "$progress"

env HOME="$home" CFFIXED_USER_HOME="$home" HEED_SEED_WORLD=1 "$copy/Contents/MacOS/Heed" >"$root/seed.log" 2>&1

env HOME="$home" CFFIXED_USER_HOME="$home" XDG_CONFIG_HOME="$home/.config" DEMO_ROOT="$root" \
  PATH="$root/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" \
  nohup "$copy/Contents/MacOS/Heed" >"$root/heed.log" 2>&1 &
echo $!
