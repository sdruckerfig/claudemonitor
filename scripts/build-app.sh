#!/usr/bin/env bash
# Builds build/ClaudeMonitor.app (release build, ad-hoc signed).
#
#   scripts/build-app.sh               native architecture only (fast)
#   scripts/build-app.sh --universal   Apple Silicon + Intel (used for the .pkg)
#
# To install, use ./install.sh, which calls this script.
set -euo pipefail
unset CDPATH   # an exported CDPATH could send the cd below to another "scripts" folder
cd "$(dirname "$0")/.."

ARCH_FLAGS=()
if [[ "${1:-}" == "--universal" ]]; then
    ARCH_FLAGS=(--arch arm64 --arch x86_64)
elif [[ -n "${1:-}" ]]; then
    echo "usage: scripts/build-app.sh [--universal]" >&2
    exit 2
fi

# "${ARCH_FLAGS[@]+...}" keeps `set -u` happy when the array is empty (bash 3.2).
swift build -c release --product ClaudeMonitor ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ClaudeMonitor"

APP=build/ClaudeMonitor.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/ClaudeMonitor"
# Drop debug symbols: they hold absolute build paths (the builder's home folder) and aren't needed.
strip -S "$APP/Contents/MacOS/ClaudeMonitor"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/ClaudeMonitor"))"
