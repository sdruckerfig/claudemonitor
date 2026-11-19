#!/usr/bin/env bash
# Renders the README screenshots (docs/screenshot-light.png and docs/screenshot-dark.png) from
# made-up sample data (Sources/MonitorCore/DemoData.swift), never from this Mac's real sessions
# or worktrees. Uses a debug build; doesn't touch a running copy of the app.
set -euo pipefail
unset CDPATH
cd "$(dirname "$0")/.."
# A failed build must stop here, not render screenshots from an older binary.
if ! out="$(swift build -c debug --product ClaudeMonitor 2>&1)"; then
    printf '%s\n' "$out" >&2
    exit 1
fi
"$(swift build -c debug --show-bin-path)/ClaudeMonitor" --render-screenshots docs
