#!/usr/bin/env bash
# Report what is missing for a full build. Exits non-zero if something required is absent.
set -uo pipefail
ok=1
check() { if eval "$2" >/dev/null 2>&1; then echo "ok    $1"; else echo "MISS  $1  ->  $3"; ok=0; fi; }
xcode="/Applications/Xcode.app/Contents/Developer"
check "Xcode installed" "[ -d '$xcode' ]" "install Xcode from the App Store"
check "Xcode licence accepted" "DEVELOPER_DIR='$xcode' xcrun --find swiftc" "sudo xcodebuild -license accept"
check "Metal toolchain" "DEVELOPER_DIR='$xcode' xcrun --find metal" "xcodebuild -downloadComponent MetalToolchain"
check "zig 0.16" "zig version | grep -q '^0.16'" "mise install"
check "gh signed in" "gh auth status" "gh auth login"
echo "DEVELOPER_DIR=${DEVELOPER_DIR:-unset}"
[ "$ok" = 1 ]
