#!/usr/bin/env bash
# List the worktrees whose .build (and build/ app bundle) has not been built in for a while, with their sizes, and delete
# them only when asked. Each worktree keeps its own .build, 3 to 4 GB, and Swift Build's state is tied to the absolute path
# so one cannot be shared or moved: the only lever is not keeping the idle ones. A deleted .build costs one full build the
# next time that worktree builds.
#
#   scripts/prune-worktree-builds.sh [DAYS]            list (default 3 days idle), delete nothing
#   scripts/prune-worktree-builds.sh [DAYS] --delete   delete the .build and build/ of what is listed
set -euo pipefail
cd "$(dirname "$0")/.."

days="${1:-3}"
delete=0
for arg in "$@"; do [ "$arg" = "--delete" ] && delete=1; done
case "$days" in --delete) days=3 ;; esac

total=0
count=0
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')" # the main checkout is never listed
# `git worktree list --porcelain` keeps paths with spaces whole, which a column split would not.
while IFS= read -r line; do
  case "$line" in worktree\ *) ;; *) continue ;; esac
  tree="${line#worktree }"
  [ "$tree" = "$main" ] && continue
  [ -d "$tree/.build" ] || continue
  # swift build touches .build/.lock on every run, so it is when this worktree last built.
  stamp="$tree/.build/.lock"
  [ -e "$stamp" ] || stamp="$tree/.build"
  if [ -n "$(find "$stamp" -maxdepth 0 -mtime "-$days" 2>/dev/null)" ]; then continue; fi
  # Skip one that is building right now.
  if pgrep -f "$tree/.build" >/dev/null 2>&1; then echo "busy   $tree"; continue; fi
  kb=$( { du -sk "$tree/.build" "$tree/build" 2>/dev/null || true; } | awk '{s+=$1} END {print s+0}')
  idle=$(( ( $(date +%s) - $(stat -f %m "$stamp") ) / 86400 ))
  printf '%5d MB  idle %2dd  %s\n' $((kb / 1024)) "$idle" "$tree"
  total=$((total + kb)); count=$((count + 1))
  if [ "$delete" = 1 ]; then rm -rf "$tree/.build" "$tree/build"; fi
done < <(git worktree list --porcelain)

if [ "$delete" = 1 ]; then
  echo "prune-worktree-builds: deleted $count builds, $((total / 1024 / 1024)) GB"
else
  echo "prune-worktree-builds: $count idle more than ${days}d, $((total / 1024 / 1024)) GB (nothing deleted; --delete to delete them)"
fi
