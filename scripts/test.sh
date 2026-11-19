#!/usr/bin/env bash
# Runs the test suite. Swift Testing needs a Swift 6 toolchain (Command Line Tools 16 or later).
# With only the Command Line Tools installed, SwiftPM sometimes fails to find the Testing macro
# plugin ("plugin for module 'TestingMacros' not found"); pointing the compiler at it fixes that.
set -euo pipefail
unset CDPATH   # an exported CDPATH could send the cd below to another "scripts" folder
cd "$(dirname "$0")/.."
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
    exec swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
fi
exec swift test "$@"
