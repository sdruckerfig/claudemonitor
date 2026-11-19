#!/usr/bin/env bash
# Removes Claude Monitor: quits it, turns off launch at login, and deletes the app from
# ~/Applications and /Applications (asking for your password if needed).
#
#   curl -fsSL https://raw.githubusercontent.com/sdruckerfig/claudemonitor/main/uninstall.sh | bash
#   ./uninstall.sh [--dir DIR]      (--dir: also remove a copy installed with install.sh --dir DIR)
#
# Nothing else is touched: no worktrees, sessions or repositories are changed.

main() {
    set -euo pipefail
    unset CDPATH
    local app="ClaudeMonitor.app" removed=0 dir id
    local -a dirs=("$HOME/Applications" "/Applications")
    # Current bundle ID first; older versions used local.claudemonitor.
    local -a ids=("io.github.sdruckerfig.claudemonitor" "local.claudemonitor")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dir) [[ $# -ge 2 && -n "$2" ]] || die "--dir needs a directory"; dirs+=("$2"); shift ;;
            -h|--help)
                sed -n '2,8p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
                echo "usage: uninstall.sh [--dir DIR]"
                return 0 ;;
            *) die "unknown option: $1 (usage: uninstall.sh [--dir DIR])" ;;
        esac
        shift
    done

    # Turn off launch at login while the app (which owns that registration) still exists.
    for dir in "${dirs[@]}"; do
        if [[ -x "$dir/$app/Contents/MacOS/ClaudeMonitor" ]]; then
            "$dir/$app/Contents/MacOS/ClaudeMonitor" --login-item off >/dev/null 2>&1 || true
        fi
    done

    local pattern='/ClaudeMonitor\.app/Contents/MacOS/ClaudeMonitor$'
    if pgrep -f "$pattern" >/dev/null 2>&1; then
        say "Quitting Claude Monitor"
        pkill -f "$pattern" 2>/dev/null || true
        sleep 1
        pkill -9 -f "$pattern" 2>/dev/null || true
    fi

    for dir in "${dirs[@]}"; do
        [[ -d "$dir/$app" ]] || continue
        # A copy installed by the .pkg is owned by root even when the folder is writable.
        if ! rm -rf "$dir/$app" 2>/dev/null || [[ -e "$dir/$app" ]]; then
            say "Administrator access is needed to remove $dir/$app"
            sudo rm -rf "$dir/$app"
        fi
        say "Removed $dir/$app"
        removed=1
    done

    # Receipts left by the .pkg installer, if it was used.
    for id in "${ids[@]}"; do
        if pkgutil --pkg-info "$id" >/dev/null 2>&1; then
            sudo pkgutil --forget "$id" >/dev/null && say "Removed installer receipt"
        fi
        if pkgutil --volume "$HOME" --pkg-info "$id" >/dev/null 2>&1; then
            pkgutil --volume "$HOME" --forget "$id" >/dev/null && say "Removed installer receipt"
        fi
        defaults delete "$id" >/dev/null 2>&1 || true
    done

    if (( removed )); then
        say "Claude Monitor is uninstalled."
    else
        say "Claude Monitor wasn't found in: ${dirs[*]}"
    fi
}

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

main "$@"
