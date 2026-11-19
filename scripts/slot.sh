#!/usr/bin/env bash
# Run a command in one of a few machine-wide build slots, so that agents working in several worktrees at once queue for
# the CPU instead of all compiling together. Every `swift build` believes it owns the machine and spawns a compiler per
# core; a handful of them at once left an 8-core, 16 GB machine at a load of 20 to 60 and swapping, and each build took
# several times longer than it would alone.
#
#   scripts/slot.sh swift build --product HeedPackageTests
#
# HEED_BUILD_SLOTS is how many run at once (default 2); 0 runs the command at once, as CI does (a runner has one job).
# HEED_SLOT_DIR is where the slots live (default ~/.cache/heed/build-slots); every worktree must agree on it.
# A slot is a directory holding its owner's pid: a crashed or killed owner is noticed and its slot taken over.
# Runs on macOS's bash 3.2, so no flock.
set -uo pipefail

slots="${HEED_BUILD_SLOTS:-2}"
dir="${HEED_SLOT_DIR:-$HOME/.cache/heed/build-slots}"

if [ "$slots" -le 0 ] || [ "$#" -eq 0 ]; then
  exec "$@"
fi
mkdir -p "$dir"

held=""
release() { [ -n "$held" ] && rm -rf "$held"; }
trap release EXIT
trap 'exit 130' INT TERM HUP

waited=0
while [ -z "$held" ]; do
  i=0
  while [ "$i" -lt "$slots" ]; do
    slot="$dir/$i"
    if mkdir "$slot" 2>/dev/null; then
      held="$slot"
    else
      owner="$(cat "$slot/pid" 2>/dev/null || true)"
      # An owner that is gone (or one that never wrote its pid and has been gone a while): take the slot over.
      if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
        rm -rf "$slot"
        continue
      fi
      # Made but never given a pid (its owner died in between): free after a minute.
      if [ -z "$owner" ] && [ -n "$(find "$slot" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rm -rf "$slot"
        continue
      fi
    fi
    if [ -n "$held" ]; then
      echo "$$" >"$held/pid"
      echo "$*" >"$held/command"
      pwd >"$held/cwd"
      break
    fi
    i=$((i + 1))
  done
  if [ -z "$held" ]; then
    if [ $((waited % 30)) -eq 0 ]; then
      echo "slot: waiting for one of $slots build slots (busy: $(cat "$dir"/*/cwd 2>/dev/null | tr '\n' ' '))" >&2
    fi
    sleep 2
    waited=$((waited + 2))
  fi
done
[ "$waited" -gt 0 ] && echo "slot: got slot $(basename "$held") after ${waited}s" >&2

"$@"
