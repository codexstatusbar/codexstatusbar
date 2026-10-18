#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIGURATION="${1:-release}"
case "$CONFIGURATION" in
    release) APP_NAME="Tokloom" ;;
    debug) APP_NAME="Tokloom Debug" ;;
    *) printf 'Usage: %s [release|debug]\n' "$0" >&2; exit 2 ;;
esac
BIN="$(swift build --build-system native -c "$CONFIGURATION" --arch arm64 --show-bin-path)"
# CI enables this only after an exact source-commit and toolchain cache hit.
if [[ "${TOKLOOM_REUSE_COMPILED:-false}" == true ]]; then
    test -x "$BIN/CodexHubApp"
    printf 'Reusing compiled products from exact CI cache.\n'
else
    swift build --build-system native -c "$CONFIGURATION" --arch arm64 --product CodexHubApp
fi
APP="$ROOT/.build/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/CodexHubApp" "$APP/Contents/MacOS/"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
