#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
./scripts/build-app.sh release
APP="$ROOT/.build/Tokloom.app"
OUT="$ROOT/.build/dist"
mkdir -p "$OUT"
for binary in "$APP/Contents/MacOS/CodexHubApp" "$APP/Contents/Helpers/codex-hub"; do
    test -x "$binary"
    lipo -verify_arch arm64 "$binary"
    codesign --verify --strict "$binary"
done
plutil -lint "$APP/Contents/Info.plist"
test -s "$APP/Contents/Resources/AppIcon.icns"
TOKENIZER="$APP/Contents/Helpers/CodexHub_CodexHubHelper.bundle"
test -s "$TOKENIZER/Contents/Resources/Resources/o200k_base.tiktoken"
codesign --verify --strict "$TOKENIZER"
codesign --verify --strict "$APP"
ARCHIVE="$OUT/Tokloom-macos-arm64.zip"
# ditto preserves macOS bundle metadata and executable permissions.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
unzip -tq "$ARCHIVE"
(cd "$OUT" && shasum -a 256 Tokloom-macos-arm64.zip > Tokloom-macos-arm64.zip.sha256)
printf '%s\n' "$ARCHIVE"
