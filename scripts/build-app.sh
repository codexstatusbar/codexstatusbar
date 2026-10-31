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
# A release tag is the version: CI passes it in TOKLOOM_VERSION, and the Info.plist in the repository holds a placeholder.
if [[ -n "${TOKLOOM_VERSION:-}" ]]; then
    read -r VERSION BUILD < <(python3 "$ROOT/scripts/release-version.py" "$TOKLOOM_VERSION")
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
# An agent that only has the app learns how to drive it from this file.
"$APP/Contents/MacOS/CodexHubApp" --help > "$APP/Contents/Resources/AGENTS.md"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
