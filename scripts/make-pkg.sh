#!/usr/bin/env bash
# Builds dist/ClaudeMonitor-<version>.pkg: a double-clickable installer containing a universal
# (Apple Silicon + Intel) build. It installs ClaudeMonitor.app into /Applications, or into
# ~/Applications if the user picks "Install for me only", then launches it.
#
# The package and app are unsigned (ad hoc) and not notarized: when downloaded from the
# internet, Gatekeeper blocks the first open until the user allows it in System Settings →
# Privacy & Security → "Open Anyway".
set -euo pipefail
unset CDPATH   # an exported CDPATH could send the cd below to another "scripts" folder
cd "$(dirname "$0")/.."

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Resources/Info.plist)"
OUT="dist/ClaudeMonitor-$VERSION.pkg"

scripts/build-app.sh --universal

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

productbuild --quiet --distribution "$STAGE/distribution.xml" --package-path "$STAGE" "$OUT"
echo "Built $OUT ($(du -h "$OUT" | cut -f1 | tr -d ' '))"
