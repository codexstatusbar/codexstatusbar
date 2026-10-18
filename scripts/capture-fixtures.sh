#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REBUILD=1
if [[ "${TOKLOOM_CACHE_FIXTURES:-0}" == 1 ]]; then
    BUILD="$ROOT/.build/fixture-cache"
    mkdir -p "$BUILD"
    KEY="$(cd "$ROOT"; { swiftc --version 2>&1; xcrun --show-sdk-version; xcrun --show-sdk-path; printf '%s\n' "$ROOT"; shasum -a 256 scripts/capture-fixtures.sh Sources/CodexHubCore/*.swift Sources/CodexHubCollector/*.swift Sources/CodexHubApp/*.swift Sources/CSQLite/module.modulemap Tests/CodexHubAppTests/FixtureHarness.swift; } | shasum -a 256 | cut -d ' ' -f 1)"
    if [[ -f "$BUILD/.source-key" && -x "$BUILD/fixtures" && "$(cat "$BUILD/.source-key")" == "$KEY" ]]; then
        REBUILD=0
        printf 'Fixture compiler cache: hit; running all checks.\n'
    else
        rm -f "$BUILD/.source-key"
        printf 'Fixture compiler cache: miss.\n'
    fi
else
    BUILD="$(mktemp -d "${TMPDIR:-/tmp}/codex-hub-fixtures.XXXXXX")"
    trap 'rm -rf "$BUILD"' EXIT
fi
OUT="${1:-$ROOT/.build/ui-evidence}"
mkdir -p "$OUT"
if [[ "$REBUILD" == 1 ]]; then
swiftc -target arm64-apple-macosx14.0 -emit-module -emit-library -module-name CodexHubCore "$ROOT"/Sources/CodexHubCore/*.swift -o "$BUILD/libCodexHubCore.dylib" -emit-module-path "$BUILD/CodexHubCore.swiftmodule"
swiftc -target arm64-apple-macosx14.0 -I "$ROOT/Sources/CSQLite" -I "$BUILD" -L "$BUILD" -lCodexHubCore -emit-module -emit-library -module-name CodexHubCollector "$ROOT"/Sources/CodexHubCollector/*.swift -o "$BUILD/libCodexHubCollector.dylib" -emit-module-path "$BUILD/CodexHubCollector.swiftmodule"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -I "$ROOT/Sources/CSQLite" -I "$BUILD" -L "$BUILD" -lCodexHubCore -lCodexHubCollector -Xlinker -rpath -Xlinker "$BUILD" "$ROOT/Sources/CodexHubApp/CodexConfig.swift" "$ROOT/Sources/CodexHubApp/RunningCodexProcess.swift" "$ROOT/Sources/CodexHubApp/AppLanguage.swift" "$ROOT/Sources/CodexHubApp/Presentation.swift" "$ROOT/Sources/CodexHubApp/UsageHistoryArchive.swift" "$ROOT/Sources/CodexHubApp/SessionGraphics.swift" "$ROOT/Sources/CodexHubApp/ProviderBadge.swift" "$ROOT/Sources/CodexHubApp/HubView.swift" "$ROOT/Sources/CodexHubApp/MenuBarImage.swift" "$ROOT/Sources/CodexHubApp/NativeMenuController.swift" "$ROOT/Tests/CodexHubAppTests/FixtureHarness.swift" -o "$BUILD/fixtures"
    if [[ "${TOKLOOM_CACHE_FIXTURES:-0}" == 1 ]]; then printf '%s' "$KEY" > "$BUILD/.source-key"; fi
fi
"$BUILD/fixtures" "$OUT"
