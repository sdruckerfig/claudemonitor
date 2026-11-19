#!/usr/bin/env bash
# Claude Monitor installer: builds the menu bar app from source and installs it.
#
#   curl -fsSL https://raw.githubusercontent.com/sdruckerfig/claudemonitor/main/install.sh | bash
#   ./install.sh [options]          (from a clone)
#
# Options:
#   --system        install into /Applications (asks for your password if needed)
#   --dir DIR       install into DIR (default: ~/Applications)
#   --login         also start Claude Monitor automatically at login
#   --no-launch     don't launch the app after installing
#   --ref REF       git branch or tag to build when installing via curl (default: main)
#
# Requires macOS 14+ and Apple's Command Line Tools (xcode-select --install). Xcode is not needed.

# Everything lives in main() so that `curl | bash` reads the whole script before running any of it.
main() {
    set -euo pipefail
    unset CDPATH   # a CDPATH would make `cd dir` print the directory and corrupt $(cd … && pwd)

    local repo_url="${CLAUDEMONITOR_REPO:-https://github.com/sdruckerfig/claudemonitor.git}"
    local app="ClaudeMonitor.app"
    local dest_dir="$HOME/Applications"
    local launch=1 login=0 ref="main"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --system) dest_dir="/Applications" ;;
            --dir) [[ $# -ge 2 && -n "$2" ]] || die "--dir needs a directory"; dest_dir="$2"; shift ;;
            --login) login=1 ;;
            --no-launch) launch=0 ;;
            --ref) [[ $# -ge 2 ]] || die "--ref needs a branch or tag"; ref="$2"; shift ;;
            -h|--help) usage; return 0 ;;
            *) usage >&2; die "unknown option: $1" ;;
        esac
        shift
    done

    # Absolute, so a name like "-x" is never read as an option and messages name the real place.
    [[ "$dest_dir" == /* ]] || dest_dir="$PWD/$dest_dir"
    # Catch a bad destination now, not after a several-minute build.
    local existing
    existing="$(nearest_existing "$dest_dir")"
    [[ -d "$existing" ]] || die "can't install into $dest_dir: $existing isn't a folder."

    # --- Requirements -----------------------------------------------------------------------
    [[ "$(uname -s)" == "Darwin" ]] || die "Claude Monitor runs on macOS only."
    local os_version os_major
    os_version="$(sw_vers -productVersion)"
    os_major="${os_version%%.*}"
    (( os_major >= 14 )) || die "macOS 14 (Sonoma) or later is required; this Mac has macOS $os_version."

    if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swift >/dev/null 2>&1; then
        die "Apple's Command Line Tools are needed to build Claude Monitor. Install them with:

    xcode-select --install

then run this installer again."
    fi
    local swift_out swift_version
    swift_out="$(xcrun swift --version 2>&1)" || true
    swift_version="$(printf '%s\n' "$swift_out" | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -1)" || true
    if [[ -z "$swift_version" ]]; then
        die "couldn't run the Swift compiler. It said:

$(printf '%s\n' "$swift_out" | head -5)

Reinstalling the Command Line Tools usually fixes this: xcode-select --install"
    fi
    version_at_least "$swift_version" 5.9 \
        || die "Swift 5.9 or later is required (found $swift_version). Update the Command Line Tools: softwareupdate --list"

    # --- Source -----------------------------------------------------------------------------
    local src script_dir=""
    if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    fi
    if [[ -n "$script_dir" && -f "$script_dir/Package.swift" && -f "$script_dir/scripts/build-app.sh" ]]; then
        src="$script_dir"
        say "Building from $src"
    else
        command -v git >/dev/null 2>&1 || die "git is required (it comes with the Command Line Tools)."
        WORK_DIR="$(mktemp -d -t claudemonitor)"
        trap 'rm -rf "$WORK_DIR"' EXIT
        say "Downloading Claude Monitor ($ref)"
        git clone --quiet --depth 1 --branch "$ref" "$repo_url" "$WORK_DIR/src" </dev/null \
            || die "could not clone $repo_url (ref: $ref)"
        src="$WORK_DIR/src"
    fi

    # --- Build ------------------------------------------------------------------------------
    say "Compiling (first build takes a few minutes)"
    local log
    log="$(mktemp -t claudemonitor-build)"
    if ! "$src/scripts/build-app.sh" </dev/null >"$log" 2>&1; then
        # Leave out the compiler's multi-kilobyte command lines.
        grep -E 'error:' "$log" | grep -v 'swift-frontend' | cut -c1-300 | head -20 >&2 || true
        grep -v 'swift-frontend' "$log" | tail -15 | cut -c1-300 >&2 || true
        die "the build failed. Full log: $log"
    fi
    rm -f "$log"

    # --- Install ----------------------------------------------------------------------------
    local sudo="" mkdir_err
    # Ask for a password only when permissions are the problem, not for a path that can't exist.
    existing="$(nearest_existing "$dest_dir")"
    [[ -d "$existing" ]] || die "can't install into $dest_dir: $existing isn't a folder."
    if [[ ! -w "$existing" || ( -d "$dest_dir" && ! -w "$dest_dir" ) ]]; then
        sudo="sudo"
        say "Administrator access is needed to write to $dest_dir"
        sudo mkdir -p "$dest_dir" || die "couldn't create $dest_dir"
    elif ! mkdir_err="$(mkdir -p "$dest_dir" 2>&1)"; then
        die "couldn't create $dest_dir: $mkdir_err"
    fi
    dest_dir="$(cd "$dest_dir" && pwd -P)"
    local dest="$dest_dir/$app"
    # A copy installed by the .pkg is owned by root, even inside a folder you can write to.
    if [[ -z "$sudo" && -e "$dest" ]]; then
        local foreign
        foreign="$(find "$dest" ! -user "$(id -u)" -print 2>/dev/null | head -1)" || foreign="unknown"
        if [[ -n "$foreign" ]]; then
            say "Administrator access is needed to replace the existing $dest"
            sudo="sudo"
        fi
    fi
    # Ask for the password before changing anything, so a cancelled prompt leaves things as they were.
    if [[ -n "$sudo" ]]; then
        sudo -v || die "administrator access is needed to install into $dest_dir"
    fi

    # Launch at login is registered by bundle ID. If the installed copy has a different ID
    # (older versions used another), switch it off with the old copy and back on with the new.
    local new_id old_id="" was_login=0
    new_id="$(plist_id "$src/build/$app")"
    if [[ -x "$dest/Contents/MacOS/ClaudeMonitor" ]]; then
        old_id="$(plist_id "$dest")"
        if [[ "$old_id" != "$new_id" ]] \
            && "$dest/Contents/MacOS/ClaudeMonitor" --login-item status 2>/dev/null | grep -q ': enabled'; then
            was_login=1
            "$dest/Contents/MacOS/ClaudeMonitor" --login-item off >/dev/null 2>&1 || true
        fi
    fi

    quit_running "$dest"
    $sudo rm -rf "$dest"
    $sudo ditto "$src/build/$app" "$dest"
    codesign --verify "$dest" 2>/dev/null || die "the installed app failed its signature check: $dest"
    say "Installed $dest"

    local other
    while IFS= read -r other; do
        warn "another copy is installed at $other. Only the copy started last runs; the uninstall command below removes it too."
    done < <(other_copies "$dest")

    if (( login || was_login )); then
        "$dest/Contents/MacOS/ClaudeMonitor" --login-item on || warn "couldn't enable launch at login; use the checkbox in the app instead."
    fi

    if (( launch )); then
        # -n starts the new build even if the old one is still shutting down; the new one
        # quits any other running copy itself.
        open -n "$dest"
        say "Claude Monitor is running: look for the colored dot and session count in your menu bar."
    fi
    # Launch at login belongs to the bundle ID, so it is shared by every installed copy.
    if ! "$dest/Contents/MacOS/ClaudeMonitor" --login-item status 2>/dev/null | grep -q ': enabled'; then
        say "To start it at login, tick “Launch at login” in its menu, or re-run with --login."
    elif (( ! login && ! was_login )) && [[ -n "$(other_copies "$dest")" ]]; then
        say "Launch at login is on, but it may start the other copy; re-run with --login to make it this one."
    fi
    local uninstall="curl -fsSL https://raw.githubusercontent.com/sdruckerfig/claudemonitor/main/uninstall.sh | bash"
    if ! same_file "$dest_dir" "$HOME/Applications" && ! same_file "$dest_dir" "/Applications"; then
        uninstall="$uninstall -s -- --dir $(squote "$dest_dir")"
    fi
    say "Uninstall: $uninstall"
}

usage() {
    sed -n '2,15p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null | sed 's/^# \{0,1\}//' || true
    cat <<'EOF'
Usage: install.sh [--system | --dir DIR] [--login] [--no-launch] [--ref REF]
EOF
}

# The closest path that exists, walking up from $1 ("." for a relative path with none). A dangling
# symlink counts as existing, so it fails the folder check instead of being walked past.
nearest_existing() {
    local p="$1"
    while [[ ! -e "$p" && ! -L "$p" ]]; do
        [[ "$p" == */* ]] || { echo "."; return; }
        p="${p%/*}"
        [[ -n "$p" ]] || { echo "/"; return; }
    done
    echo "$p"
}

# Installed copies in the standard folders other than $1, one per line.
other_copies() {
    local other
    for other in "$HOME/Applications/ClaudeMonitor.app" "/Applications/ClaudeMonitor.app"; do
        [[ -d "$other" ]] && ! same_file "$other" "$1" && echo "$other"
    done
    return 0
}

# Single-quotes $1 for pasting into a shell. Unlike bash 3.2's printf %q, the result stays valid
# UTF-8 (%q escapes bytes of characters such as ’ or – one at a time).
squote() {
    local q="'" r="'\\''"
    printf "'%s'" "${1//$q/$r}"
}

# True when both paths exist and are the same file (same device and inode). Path strings can
# differ in letter case or symlinks and still name the same folder.
same_file() {
    local a b
    a="$(stat -L -f '%d:%i' "$1" 2>/dev/null)" || return 1
    b="$(stat -L -f '%d:%i' "$2" 2>/dev/null)" || return 1
    [[ -n "$a" && "$a" == "$b" ]]
}

plist_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null || true
}

# Quits the copy running from this exact bundle (a `ClaudeMonitor --worktrees` run from a
# terminal, or a copy installed elsewhere, is left alone) and waits briefly for it to exit.
quit_running() {
    local target="$1/Contents/MacOS/ClaudeMonitor" pids="" pid i alive
    [[ -e "$target" ]] || return 0
    for pid in $(pgrep -f '/ClaudeMonitor\.app/Contents/MacOS/ClaudeMonitor$' 2>/dev/null || true); do
        # A GUI launch has no arguments, so its command line is the executable's path.
        same_file "$(ps -o args= -p "$pid" 2>/dev/null || true)" "$target" && pids="$pids $pid"
    done
    [[ -n "$pids" ]] || return 0
    say "Quitting the running Claude Monitor"
    kill $pids 2>/dev/null || true
    for i in 1 2 3 4 5 6 7 8 9 10; do
        alive=0
        for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive=1; done
        (( alive )) || return 0
        sleep 0.5
    done
    kill -9 $pids 2>/dev/null || true
}

version_at_least() {  # version_at_least 5.10 5.9  -> true
    local IFS=.
    local -a have=($1) want=($2)
    (( ${have[0]:-0} > ${want[0]:-0} )) && return 0
    (( ${have[0]:-0} < ${want[0]:-0} )) && return 1
    (( ${have[1]:-0} >= ${want[1]:-0} ))
}

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

main "$@"
