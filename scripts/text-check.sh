#!/bin/bash
# Fails when other people's text (ExternalText) or a Prompt is interpolated into a plain String. Swift cannot make
# that a compile error (it ranks an unavailable overload last), so Prompt.swift makes it a deprecation with its own
# message, and this rebuilds heed's own sources (not its dependencies) to see every warning again and fails on that
# message only. Other warnings are left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
find Sources Tests -name '*.swift' -exec touch {} +
out=$(swift build --build-tests 2>&1) || { printf '%s\n' "$out" | tail -40; exit 1; }
hits=$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g' \
    | grep -E "^/.*warning: 'appendInterpolation' is deprecated: (use \.display for the UI, or interpolate it into a Prompt|use \.text where the prompt leaves heed)" \
    | sort -u || true)
if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    echo "text-check: other people's text or a Prompt is interpolated into a String (see Sources/HeedCore/Domain/Prompt.swift)"
    exit 1
fi
echo "text-check: no ExternalText or Prompt in a String interpolation"
