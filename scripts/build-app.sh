#!/bin/bash
set -euo pipefail

# Usage: scripts/build-app.sh [debug|release] [output-directory]
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${1:-release}"
OUTPUT="${2:-$ROOT/dist}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release] [output-directory]" >&2; exit 2 ;;
esac

cd "$ROOT"
swift build --build-system swiftbuild -c "$CONFIGURATION" --product DurableChat
BIN_DIR="$(swift build --build-system swiftbuild -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
# Stage in the destination filesystem. Preserve any unrelated output files.
STAGING="$(mktemp -d "$OUTPUT/.DurableChat.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/DurableChat.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DurableChat" "$APP/Contents/MacOS/DurableChat"
# Swift Build's Bundle.module searches Bundle.main.resourceURL for packaged apps.
# Keep resource bundles in Contents/Resources so the app can be sealed and signed.
for resource in "$BIN_DIR"/*.bundle; do
    [ -d "$resource" ] || continue
    cp -R "$resource" "$APP/Contents/Resources/"
done
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>DurableChat</string>
    <key>CFBundleIdentifier</key><string>com.ks250206.DurableChat</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>DurableChat</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist"
# Preserve required upstream acknowledgements in the distributable artifact.
NOTICES="$APP/Contents/Resources/PiDurableKit_PiDurableKit.bundle/ThirdPartyNotices.txt"
# The newer Swift Build engine produces a Contents/Resources-style bundle.
if [ ! -f "$NOTICES" ]; then
    NOTICES="$APP/Contents/Resources/PiDurableKit_PiDurableKit.bundle/Contents/Resources/ThirdPartyNotices.txt"
fi
if [ ! -f "$NOTICES" ]; then
    echo "Missing PiDurableKit third-party notices/resource bundle" >&2
    exit 1
fi
cp "$NOTICES" "$APP/Contents/Resources/ThirdPartyNotices.txt"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
rm -rf "$OUTPUT/DurableChat.app"
mv "$APP" "$OUTPUT/DurableChat.app"
printf '%s\n' "$OUTPUT/DurableChat.app"
