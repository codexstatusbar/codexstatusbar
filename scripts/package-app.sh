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
IMAGE="$OUT/Tokloom-macos-arm64.dmg"
STAGING="$(mktemp -d "$ROOT/.build/tokloom-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Tokloom.app"
ln -s /Applications "$STAGING/Applications"
# Hosted macOS runners occasionally fail hdiutil with a transient "No such file or directory".
for attempt in 1 2 3; do
    if hdiutil create -volname Tokloom -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$IMAGE"; then break; fi
    [[ "$attempt" == 3 ]] && exit 1
    printf 'hdiutil create failed (attempt %s); retrying.\n' "$attempt" >&2
    rm -f "$IMAGE"
    sleep 5
done
hdiutil verify "$IMAGE"
(cd "$OUT" && shasum -a 256 Tokloom-macos-arm64.dmg > Tokloom-macos-arm64.dmg.sha256)
printf '%s\n' "$IMAGE"
