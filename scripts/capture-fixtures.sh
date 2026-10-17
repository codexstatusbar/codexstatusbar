#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/codex-hub-fixtures.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
OUT="${1:-$ROOT/.build/ui-evidence}"
mkdir -p "$OUT"
swiftc -target arm64-apple-macosx14.0 -emit-module -emit-library -module-name CodexHubCore "$ROOT"/Sources/CodexHubCore/*.swift -o "$BUILD/libCodexHubCore.dylib" -emit-module-path "$BUILD/CodexHubCore.swiftmodule"
swiftc -target arm64-apple-macosx14.0 -I "$ROOT/Sources/CSQLite" -I "$BUILD" -L "$BUILD" -lCodexHubCore -emit-module -emit-library -module-name CodexHubCollector "$ROOT"/Sources/CodexHubCollector/*.swift -o "$BUILD/libCodexHubCollector.dylib" -emit-module-path "$BUILD/CodexHubCollector.swiftmodule"
swiftc -target arm64-apple-macosx14.0 -parse-as-library -I "$ROOT/Sources/CSQLite" -I "$BUILD" -L "$BUILD" -lCodexHubCore -lCodexHubCollector -Xlinker -rpath -Xlinker "$BUILD" "$ROOT/Sources/CodexHubApp/HelperConnection.swift" "$ROOT/Sources/CodexHubApp/RunningCodexProcess.swift" "$ROOT/Sources/CodexHubApp/AppLanguage.swift" "$ROOT/Sources/CodexHubApp/Presentation.swift" "$ROOT/Sources/CodexHubApp/HubView.swift" "$ROOT/Sources/CodexHubApp/NativeMenuController.swift" "$ROOT/Tests/CodexHubAppTests/FixtureHarness.swift" -o "$BUILD/fixtures"
"$BUILD/fixtures" "$OUT"
