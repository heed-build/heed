#!/usr/bin/env bash
# Give every tracked file a modification time that depends only on its content, so a build that was cached on one
# checkout is incremental on another.
#
# Swift Build decides what to recompile from each input's modification time (a changed one, older or newer, rebuilds;
# the inode does not matter). A fresh `git checkout` stamps every file with the time it ran, so a restored `.build`
# looked entirely out of date and heed's own sources rebuilt in full on every run. Here a file's time is derived from its
# git blob id: the same content gets the same time on every machine and every run, and different content gets a
# different one (a collision is 1 in 2^28). No history is needed, which a shallow CI clone does not have.
#
#   scripts/pin-mtimes.sh
set -euo pipefail
cd "$(dirname "$0")/.."

git ls-files -s -z | python3 -I -c '
import os, sys
base = 946684800  # 2000-01-01
for entry in sys.stdin.buffer.read().split(b"\0"):
    if not entry:
        continue
    meta, _, path = entry.partition(b"\t")
    blob = meta.split()[1]
    if not os.path.isfile(path) or os.path.islink(path):
        continue
    stamp = base + int(blob[:7], 16)
    os.utime(path, (stamp, stamp))
'
echo "pin-mtimes: tracked files stamped from their content"
