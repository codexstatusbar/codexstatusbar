#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --build-system native -c release --arch arm64 --product CodexHubApp
swift build --build-system native -c release --arch arm64 --product codex-hub
BIN="$(swift build --build-system native -c release --arch arm64 --show-bin-path)"
APP="$ROOT/.build/Codex Hub.app"
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
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
printf '%s\n' "$APP"
