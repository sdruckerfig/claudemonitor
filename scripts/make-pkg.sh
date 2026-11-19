#!/usr/bin/env bash
# Builds dist/ClaudeMonitor-<version>.pkg: a double-clickable installer containing a universal
# (Apple Silicon + Intel) build. It installs ClaudeMonitor.app into /Applications, or into
# ~/Applications if the user picks "Install for me only", then launches it.
#
#   scripts/make-pkg.sh                                   unsigned (ad hoc) package
#   scripts/make-pkg.sh --team TEAMID                     signed with the team's Developer ID
#   scripts/make-pkg.sh --team TEAMID --notarize PROFILE  ...and notarized and stapled
#
# --team uses the "Developer ID Application" and "Developer ID Installer" certificates for TEAMID
# in your keychain. --notarize uses credentials saved with
# `xcrun notarytool store-credentials PROFILE --apple-id … --team-id TEAMID`.
#
# A package downloaded from the internet that isn't notarized (signed or not) is blocked by
# Gatekeeper until the user allows it in System Settings → Privacy & Security → "Open Anyway".
set -euo pipefail
unset CDPATH   # an exported CDPATH could send the cd below to another "scripts" folder
cd "$(dirname "$0")/.."

TEAM="" PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) [[ $# -ge 2 && -n "$2" ]] || { echo "--team needs a team ID" >&2; exit 2; }; TEAM="$2"; shift ;;
        --notarize) [[ $# -ge 2 && -n "$2" ]] || { echo "--notarize needs a notarytool profile name" >&2; exit 2; }; PROFILE="$2"; shift ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "usage: scripts/make-pkg.sh [--team TEAMID [--notarize PROFILE]]" >&2; exit 2 ;;
    esac
    shift
done
[[ -z "$PROFILE" || -n "$TEAM" ]] || { echo "--notarize needs --team (Apple only notarizes Developer ID signed packages)" >&2; exit 2; }

# The full name of TEAM's certificate of the given kind, e.g. "Developer ID Installer: Jane Doe (AB12CD34EF)".
identity() {
    security find-identity -v ${2:+-p "$2"} | sed -nE "s/.*\"($1: .*\($TEAM\))\"$/\1/p" | head -1
}
APP_IDENTITY="" INSTALLER_IDENTITY=""
if [[ -n "$TEAM" ]]; then
    APP_IDENTITY="$(identity "Developer ID Application" codesigning)"
    INSTALLER_IDENTITY="$(identity "Developer ID Installer")"
    [[ -n "$APP_IDENTITY" ]] || { echo "no \"Developer ID Application\" certificate for team $TEAM in the keychain" >&2; exit 1; }
    [[ -n "$INSTALLER_IDENTITY" ]] || { echo "no \"Developer ID Installer\" certificate for team $TEAM in the keychain" >&2; exit 1; }
    echo "Signing with: $APP_IDENTITY"
    echo "              $INSTALLER_IDENTITY"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
OUT="dist/ClaudeMonitor-$VERSION.pkg"

CODESIGN_IDENTITY="${APP_IDENTITY:--}" scripts/build-app.sh --universal

STAGE="$(mktemp -d -t claudemonitor-pkg)"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/root" "$STAGE/scripts" dist
ditto build/ClaudeMonitor.app "$STAGE/root/ClaudeMonitor.app"
cp scripts/pkg/postinstall "$STAGE/scripts/postinstall"
chmod 755 "$STAGE/scripts/postinstall"

# Not relocatable: otherwise Installer "upgrades" any other copy with the same bundle id
# wherever it finds one (e.g. a build folder) instead of installing into Applications.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Set :0:BundleIsRelocatable false' "$STAGE/components.plist"

pkgbuild --quiet \
    --root "$STAGE/root" \
    --component-plist "$STAGE/components.plist" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    --scripts "$STAGE/scripts" \
    "$STAGE/ClaudeMonitor-component.pkg"

cat > "$STAGE/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Claude Monitor $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <volume-check>
        <allowed-os-versions>
            <os-version min="14.0"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="$IDENTIFIER"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="$IDENTIFIER" visible="false">
        <pkg-ref id="$IDENTIFIER"/>
    </choice>
    <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">ClaudeMonitor-component.pkg</pkg-ref>
</installer-gui-script>
EOF

SIGN=()
[[ -n "$INSTALLER_IDENTITY" ]] && SIGN=(--sign "$INSTALLER_IDENTITY" --timestamp)
rm -f "$OUT"
productbuild --quiet ${SIGN[@]+"${SIGN[@]}"} --distribution "$STAGE/distribution.xml" --package-path "$STAGE" "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
[[ -n "$INSTALLER_IDENTITY" ]] && pkgutil --check-signature "$OUT" | sed -n '2,4p'

if [[ -n "$PROFILE" ]]; then
    echo "Notarizing (usually a few minutes)"
    xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait --output-format json > "$STAGE/notary.json" || true
    status="$(plutil -extract status raw -o - "$STAGE/notary.json" 2>/dev/null || echo unknown)"
    if [[ "$status" != "Accepted" ]]; then
        echo "Notarization failed (status: $status)." >&2
        id="$(plutil -extract id raw -o - "$STAGE/notary.json" 2>/dev/null || true)"
        [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || cat "$STAGE/notary.json" >&2
        rm -f "$OUT"
        exit 1
    fi
    xcrun stapler staple -q "$OUT"
    xcrun stapler validate -q "$OUT"
    spctl --assess --type install -vv "$OUT" 2>&1 | sed 's/^/  /'
    echo "Notarized and stapled $OUT"
fi
