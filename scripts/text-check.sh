#!/bin/bash
# Fails when other people's text (ExternalText) or a Prompt is interpolated into a plain String. Swift cannot make
# that a compile error (it ranks an unavailable overload last), so Prompt.swift makes it a deprecation with its own
# message, and this looks for that message in a build's warnings and fails on it only. Other warnings are left alone.
#
#   scripts/text-check.sh LOG...   scan build logs that compiled every heed source (CI: the test build, which touches
#                                  HeedCore and the tests first, and the release build, whole-module, which compiles
#                                  everything it has). Builds nothing.
#   scripts/text-check.sh          build everything here, in its own .build/text-check (so `mise run test` keeps its
#                                  incremental state), with every heed source touched so each warning appears again.
set -euo pipefail
cd "$(dirname "$0")/.."

pattern="^/.*warning: 'appendInterpolation' is deprecated: (use \.display for the UI, or interpolate it into a Prompt|use \.text where the prompt leaves heed)"

if [ "$#" -gt 0 ]; then
  for log in "$@"; do
    [ -s "$log" ] || { echo "text-check: $log is empty or missing, so it checked nothing" >&2; exit 1; }
  done
  out=$(cat "$@")
else
  find Sources Tests -name '*.swift' -exec touch {} +
  out=$(swift build --build-tests --scratch-path .build/text-check 2>&1) || { printf '%s\n' "$out" | tail -40; exit 1; }
fi

hits=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "$pattern" | sort -u || true)
if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "text-check: other people's text or a Prompt is interpolated into a String (see Sources/HeedCore/Domain/Prompt.swift)"
    exit 1
fi
echo "text-check: no ExternalText or Prompt in a String interpolation"
