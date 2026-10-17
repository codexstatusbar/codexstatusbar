# S3 native UI verification

Scope: Sources/CodexHubApp, Tests/CodexHubAppTests, scripts/*-app.sh,
scripts/capture-fixtures.sh, Resources/Info.plist. PRD UI-01–09 and section 11.

## Design evidence

Fetched high-fidelity Figma design context and screenshots for file
P9TNlM9tQhWRAvhzPoAekm nodes 7:20, 7:92, 7:165, 7:230, 7:281,
7:341, 7:389, 7:440, 7:506 on 2026-10-17. No screenshot is a runtime asset.
400pt width, 20pt content inset, 16pt section rhythm, 17pt heading, 13pt body,
11pt supporting text and 42pt numeric hero follow the design hierarchy.
User/PRD overrides: flat separated rows replace provisional card shells;
system SF font, native controls and semantic appearance replace Inter and drawn
control/icon assets. No downloaded Figma asset is needed for these system controls.
Reported R values replace unavailable Live estimates. Unknown PID is Session only.
The view supports all fixture activity states without seeding production telemetry.

Observation -> principle -> change -> evidence:
- Card shells -> grouping through spacing -> flat rows and dividers -> reported PNGs.
- Small secondary text on white -> readable contrast -> primary semantic label color
  for informational copy -> light/dark fixture rendering.
- Long detail -> fixed navigation -> scrollable content, header/footer outside scroll
  -> detail PNG; no arbitrary truncation of copyable paths.
- Missing samples -> truthful state -> em dash/Working, no fabricated zero -> UI03/07.

## Focused executable checks

Run `scripts/capture-fixtures.sh` from the repository. This compiles the actual
Core/presentation/views with CLT for arm64 macOS14 into a disposable temporary
build directory; no manifest edits, fake production collector or user log access.
Assertions live in Tests/CodexHubAppTests/FixtureHarness.swift.

| ID | Assertion | Result |
|---|---|---|
| UI01 | Same-window 600+300 outputs gives R90 | PASS |
| UI02 | No inferred PID; Session only; reasoning remains subset | PASS |
| UI03 | Nil is em dash; measured zero is R0 | PASS |
| UI04 | Scope exclusion gives R60 and 1 of 2 Partial | PASS |
| UI05 | Completion clears current speed and shows Idle | PASS |
| UI06 | Hide idle filters confirmed idle rows | PASS |
| UI07 | New active turn without report is Working with approval marker | PASS |
| UI08 | Disconnected does not become Idle | PASS |
| UI09 | Collection error suppresses aggregate speed | PASS |
| UI10 | Empty discovery is No sessions | PASS |
| UI11 | Disconnected approval state does not announce current approval | PASS |

PNG output: `.build/ui-evidence/`: reported-light, reported-dark, detail,
preferences, connection, partial, idle, working-approval, disconnected, error,
empty, detail-long-path, detail-small-screen, preferences-full, connection-full. Synthetic fixture label is shown in all images.
Rendered image inspection is implementer-owned, not independent verification.

## Production integration

S2 bb165e2 and core r01 68673be were merged through integration 25c07a8.
Manifest ownership transferred to S3 for the real CodexHubApp executable target.
AppDelegate uses the actual LogCollector actor: refresh at 1Hz, safe diagnostic
messages, clearMetadata, updateRetention and wake markGap. No fake production
service or seeded metrics exist. NSStatusItem/NSPopover host the actual views.
Codex home can be selected with NSOpenPanel; metadata is isolated by canonical
home SHA256 under Application Support/CodexHub/homes with private owned directories.
Old collector is stopped/released and old rows cleared on switching homes.
Hide-idle and compact menu preferences persist in UserDefaults. Retention updates
persist only after collector success. Clear requires the native confirmation alert.
SMAppService registration/unregistration runs only from the explicit user toggle;
startup only reads its status. Direct/Live/Hook remain disabled with reasons.

`./scripts/build-app.sh` produces `.build/Codex Hub.app` using SwiftPM/CLT,
arm64 release and an ad-hoc signature. `./scripts/run-app.sh` builds and opens it.
The app bundle requires no Xcode installation. No login item or Hook was changed.

## Remaining boundaries

Earlier fixture assertions/renders predate the final production integration.
No post-integration QA/tests/runtime launch/captures were run after the user's stop.
 Provider/G0, actual VoiceOver interaction, macOS14 hardware,
endurance, notarization and release signing remain unverified.
qa-verification is disabled and was not invoked.

Applied skills: minimal-code, ponytail, systematic-ui-ux-design,
logic-driven-ui-design, figma-design-to-code, figma-swiftui, orca-cli,
orchestration. Core/glossary semantics were reused unchanged.

Latest user direction (coordinator relay): implementation first; bounded checks only.
Full QA, VoiceOver, endurance and G0 are deferred to the user. No additional QA
infrastructure or expanded verification is being added.

Superseding user instruction: skip all QA now and finish implementation first.
No further tests, captures or reviews run after this instruction; only compilation
needed to produce the app is allowed. Earlier PASS evidence is historical and
does not validate later integration changes.

Final build: `scripts/build-app.sh` completed successfully on 2026-10-17, arm64
release, CLT native SwiftPM (61.80 seconds). Bundle: `.build/Codex Hub.app`.
The native SwiftPM build-system deprecation warning remains. This is build evidence,
not runtime or full QA acceptance. Managed helper bundling remains with subsequent
S4 integration; the delivered app currently uses the real logs collector.

## 2026-10-17 resumed local QA

The user resumed QA and reported clipped menu-bar content. The popover now takes
its height from the clicked status button's screen when opened, disables hosting
controller automatic sizing, and sets an explicit viewport size. Page navigation
recreates the scroll view so previous scroll offsets do not hide new headings.
The native popover was opened by the user after rebuilding/restarting; direct UI
inspection showed the complete header, measurement picker, subtotal and footer.
Multi-display moves and long-running resize behavior remain unverified.

Connection now presents optional Hook controls before collection diagnostics.
Repeated diagnostics are grouped with occurrence counts. Real bundled helper
status returned not_installed; the Install hooks button opened the native consent
alert with the selected hooks.json path, backup retention and manual /hooks trust
instructions. Cancel was selected; a subsequent status command still returned
not_installed. No real Hook install, trust mutation or provider action was run.

`./scripts/capture-fixtures.sh .build/qa-20261017-ui` passed UI01–UI15 after
updating stale root-field and coverage contracts. Added cases verify Live-only
root subtotal, missing/warming-up values, source reconciliation suppression and
mode separation. Synthetic Connection capture visibly includes the install and
remove controls above diagnostics; fixture controls are disabled by design because
no helper is attached. Synthetic screenshots do not prove actual installation.

`./scripts/build-app.sh` passed for the current arm64 release app and helper with
ad-hoc signing. `swift test --build-system native --disable-xctest -Xcxx -isystem
-Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"` passed 43 tests. Logs are local
ignored artifacts under `.build/qa-20261017/`.

Remaining actual-home diagnostics include oversized records/files and an
uninterpretable record. Metadata-only inspection found two files over the 256 MiB
file cap; this does not explain every size diagnostic or prove those sources were
collected. No original logs were changed. Full-product QA is not complete:
qa-verification is disabled in the global skill configuration and its enablement
question is pending; no disabled skill workflow was loaded or bypassed.

## Idle summary regression

The summary previously required every discovered session to be connected/idle,
so one historical Unknown row hid a freshly completed session's Idle state.
Connected active turns now take priority, followed by any observed connected
idle session. Individual Unknown rows, missing measurements and Partial coverage
remain unchanged. Process existence or silence is not converted to idle.

UI16 failed before the fix. UI01–UI19 then passed, including historical Unknown
plus observed Idle, unchanged historical row labels, active-turn priority and no
idle claim for disconnected work/unknown-only rows. All 43 Core/Collector tests
and the arm64 app build passed. Evidence is in `.build/qa-idle-summary/`; this
focused regression run does not claim the previously pending full QA gate.
