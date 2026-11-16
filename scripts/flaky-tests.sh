#!/bin/bash
# Names the tests that failed in exactly one of two runs of the suite, from the output of each (`swift test`):
#   scripts/flaky-tests.sh first.log second.log
# A test that fails both times is a failure, not a flake, and is left to the runs themselves to report. Exits 1 when a
# test is flaky. CI runs the suite twice on pushes to main and fails here, so a flake is named rather than retried away.
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "usage: $0 first.log second.log" >&2
    exit 2
fi

# A failed test shows as `✘ Test <name> recorded an issue …` for each issue and, unless it is parameterized, as
# `✘ Test <name> failed after <n> seconds …` at its end; colours stripped. `✘ Test run with …` is the run, not a test.
failed() {
    sed -e $'s/\x1b\\[[0-9;]*m//g' "$1" | LC_ALL=C awk '
        {
            i = index($0, "✘ Test ")
            if (i == 0) next
            rest = substr($0, i + length("✘ Test "))
            if (index(rest, "run with ") == 1) next
            j = index(rest, " recorded an issue")
            if (j > 0) { print substr(rest, 1, j - 1); next }
            if (match(rest, / failed after [0-9.]+ seconds/)) print substr(rest, 1, RSTART - 1)
        }' | sort -u
}

first=$(failed "$1")
second=$(failed "$2")
# comm needs both sides sorted the same way; an empty side is an empty file, not a blank line.
flaky=$(comm -3 <(printf '%s' "$first" | sed '/^$/d') <(printf '%s' "$second" | sed '/^$/d') | sed 's/^\t//')

if [ -n "$flaky" ]; then
    printf '%s\n' "$flaky" | while IFS= read -r name; do
        if printf '%s\n' "$first" | grep -qxF -- "$name"; then run=first; else run=second; fi
        echo "flaky: $name (failed in the $run run only)"
    done
    exit 1
fi
echo "flaky-tests: no test failed in only one of the two runs"
