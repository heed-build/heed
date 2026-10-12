#!/usr/bin/env bash
# Print the newest macOS SDK whose Swift interface was built by a compiler no newer than the system swiftc.
# Works around Command Line Tools installs where the default SDK is ahead of the compiler.
set -euo pipefail
swiftc_ver=$(xcrun swiftc --version 2>/dev/null | sed -nE 's/.*swiftlang-([0-9.]+).*/\1/p' | head -1)
sdk_dir=$(dirname "$(xcrun --show-sdk-path)")
best=""
for sdk in $(ls -d "$sdk_dir"/MacOSX[0-9]*.sdk 2>/dev/null | sort -V); do
  iface=$(ls "$sdk"/usr/lib/swift/Swift.swiftmodule/*.swiftinterface 2>/dev/null | head -1) || continue
  sdk_ver=$(sed -nE 's/.*swiftlang-([0-9.]+).*/\1/p' "$iface" | head -1)
  [ -z "$sdk_ver" ] && continue
  if [ "$(printf '%s\n%s\n' "$sdk_ver" "$swiftc_ver" | sort -V | tail -1)" = "$swiftc_ver" ]; then best="$sdk"; fi
done
echo "${best:-$(xcrun --show-sdk-path)}"
