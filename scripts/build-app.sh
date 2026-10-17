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
    test -x "$BIN/codex-hub"
    test -d "$BIN/CodexHub_CodexHubHelper.bundle"
    printf 'Reusing compiled products from exact CI cache.\n'
else
    swift build --build-system native -c "$CONFIGURATION" --arch arm64 --product CodexHubApp
    swift build --build-system native -c "$CONFIGURATION" --arch arm64 --product codex-hub
fi
APP="$ROOT/.build/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN/CodexHubApp" "$APP/Contents/MacOS/"
cp "$BIN/codex-hub" "$APP/Contents/Helpers/"
# The native SwiftPM builder emits a flat resource directory without bundle metadata.
TOKENIZER="$APP/Contents/Helpers/CodexHub_CodexHubHelper.bundle"
TOKENIZER_SOURCE="$BIN/CodexHub_CodexHubHelper.bundle"
if [[ -d "$TOKENIZER_SOURCE/Contents/Resources" ]]; then
    TOKENIZER_SOURCE="$TOKENIZER_SOURCE/Contents/Resources"
fi
rm -rf "$TOKENIZER"
mkdir -p "$TOKENIZER/Contents/Resources"
ditto "$TOKENIZER_SOURCE/Resources" "$TOKENIZER/Contents/Resources/Resources"
cp "$ROOT/Resources/Tokenizer-Info.plist" "$TOKENIZER/Contents/Info.plist"
codesign --force --sign - "$TOKENIZER"
codesign --force --sign - "$APP/Contents/Helpers/codex-hub"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
