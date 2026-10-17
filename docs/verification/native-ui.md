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

## Running processes only

The App now captures same-user live Codex PID/start identities with native libproc
APIs off the main actor. Exact writable regular-file device/inode matches attach
rollout rows; managed controller PID/start identities attach direct rows. A second
start-time check rejects process exit/reuse during enumeration. Historical rows
without a current owner are excluded from the visible list and selected-mode
subtotal. Ambiguous owners remain unmatched. Live processes without matched
sessions have explicit waiting rows; source logs and stored history are preserved.

The UI01–UI20 fixture and P01–P06 native boundary checks passed. The native checks
compile a private tiny file-writer fixture named codex, verify exact inode mapping,
missing/ambiguous mappings, mismatched PID start identity and disappearance after
exit. No actual Codex process/provider is launched or stopped by these fixtures.
The 43 Core/Collector tests and arm64 app build passed. The mode picker now exists
only in Preferences and uses the shorter Live / 5s label. Full QA remains pending.

## Process metadata and compact header

Matched live process rows show model/reasoning effort and individual speed. The
Summary button opens the existing detail page for context usage/window, reported
cumulative input/output, and remaining percentage/reset time for each limit window.
Active rows precede idle and unknown rows (UI25); unmatched processes are last. UI21–UI24 validate formatting and distinguish current
context from cumulative usage. Captures are in `.build/qa-process-metadata/`,
including `process-metadata.png`, `detail.png` and `preferences.png`. UI01–UI25 and native
P01–P06 passed. Main has no mode picker or Codex Hub brand heading; Preferences
owns the short Reported / Live picker, and Close is an xmark button with accessible
name, tooltip and Escape shortcut. The 46 Core/Collector tests and final arm64
app build passed. Missing metadata and unsupported Live estimates stay unavailable.

Official status-field reference: https://learn.chatgpt.com/docs/developer-commands
Actual extraction uses the installed Codex rollout fields, without account/provider
requests, config trust mutation or invented IDs. Full QA remains uncompleted.

## Final process view follow-up

Known session rows precede unmatched live processes. Summary is an explicit button
opening the existing details page; the main row retains title/PID, model/effort,
individual speed and activity only. Active rows sort before idle and Unknown.
The user explicitly retained Live mode: Logs rows therefore show an unavailable
Live rate and a managed-direct requirement notice. The earlier R90 fixture was
synthetic reported throughput, never actual Live/provider evidence.

All 51 Core/Collector tests, UI01–UI25, P01–P06 and final arm64 build passed in
scope. Actual metadata was inspected for the running session; fake/fixture speeds
are not promoted to actual measurement evidence. Full QA remains incomplete.

## Compact numeric formatting

Context is shown as used/window percent. Input/output use decimal K/M/G suffixes
with at most one decimal; source integers are preserved. UI26–UI28 cover small
counts, K/M and G formatting, including explicit half-up rounding. UI01–UI28 and
P01–P06 passed; final app build passed. Actual Live rates remain unavailable for
Logs and are not inferred from these cumulative counters.

## Fast and Ultrafast provenance

Summary separates the recorded/requested session tier from the selected home's
configured default. Current inspected sessions did not report a speed tier, while
the home default was fast; the UI therefore does not claim those sessions actually
used Fast. Optional future turn_context.service_tier records are allowlisted by
the shared ServiceTier enum. No API call, trust change or config write occurs.
Home config reads are owner/regular-file/no-follow/size/change checked. Its parser
accepts only a simple root default and refuses ambiguity/multiline content rather
than guessing profile or CLI configuration. UI29–UI34 cover those boundaries and
Fast/priority/Ultrafast mapping. All 51 Core/Collector tests, UI01–UI34, P01–P06 and
final arm64 build passed in scope. Full QA remains unapproved/uncompleted.

Sources: https://developers.openai.com/api/docs/guides/fast-mode and
https://developers.openai.com/api/docs/guides/ultrafast-mode (retrieved 2026-10-17).

## Actual app verification after final replacement

On the user's opened popover, the actual selected and persisted mode was Reported
10s. The matched live CLI row and aggregate both showed R104.7 tok/s, later R143.4,
with Working; a tool event showed Tool running. These were actual reported-window
observations, separate from synthetic fixture speeds and not a Live estimate.
Known work appeared first, with unmatched live processes below. Summary opened
successfully and showed context percent, K/M token totals, quota remaining, model
and effort. The title was removed and Close used the accessible xmark control.
The requested tier was Not reported and the home default was Fast; no actual Fast
or Ultrafast provider execution was inferred. User source IDs are not copied here.
Idle restoration is regression-tested; the current active conversation was not
artificially ended for an actual Idle capture. No provider run or Hook mutation was
performed. Actual Logs-to-Live estimation remains unavailable by the source
contract, and full-product QA remains incomplete.

## Work-average UI and purpose-first copy

Default reported mode is now labeled 작업 평균. Main shows the combined current
work averages and each process's own average; menu text identifies 평균. Completed
averages are near the top of 작업 요약, with observed-period averages distinguished.
Main uses concise Korean work/readiness states. Internal Partial/coverage text is
removed from main/menu and retained as readable scope information in Summary.
The divider below Close is removed. UI35/36 verify the average persists after ten
seconds and the menu contains only the meaningful metric/unit. UI01–UI36 and
P01–P06 passed; synthetic screenshots are in `.build/qa-work-average/`. Synthetic
values remain separate from any actual runtime observations. Release arm64 app
and helper builds passed. Full-product QA remains incomplete.


The user-opened app initially displayed 22.4 tok/s and Working, then degraded.
Connection diagnostics and bounded local inspection identified a 1.16 MB
compacted rollout record, exceeding the 256 KB per-record bound. This was not a
successful no-gap runtime verification. The collector now persists bounded
oversized-line discard progress, marks the measurement gap, and resumes at the
next record without counting catch-up usage. S232 covers checkpoint restart,
recovery, and fresh usage. Managed and Hook record limits remain fail-closed.
The overview title now shares the close-button row, removing the empty header
row and reducing the top inset. All 58 Core/Collector tests and UI01–UI36/P01–P06
passed after these changes. Actual post-replacement verification is pending.


Connection progress now uses an explicit foreground-check flag. The one-second
background poll retains its serialization guard but no longer changes the button
to Checking on every pass. The page explains the automatic collection interval.
Initial connection and user-requested refresh still show progress and preserve
errors. UI01–UI36/P01–P06 and the arm64 app/helper build passed for this follow-up;
actual replacement UI remains to be checked with the user's opened popover.


## Settings lock follow-up

The user's screenshot exposed a remaining bug: background polling still toggled
`model.busy`, disabling retention, metadata, and connection controls every cycle.
Polling now owns a separate task handle and does not write the foreground UI lock.
Refresh, retention changes, and clear operations acquire that lock immediately,
await any in-flight poll, then execute; home changes cancel the old poll and retain
generation checks. UI01–UI36/P01–P06 and the arm64 build passed. These fixture
checks do not exercise the native polling scheduler; actual multi-cycle settings
interaction after replacement remains unverified. No retention value or metadata
was changed during verification.


## Language preference and compact metric copy

Settings now offers System default, 한국어, and English. The selection updates
app-owned labels, menu status, accessibility labels, and native confirmation copy
without restarting and persists in the existing app defaults. Unsupported saved
values fall back to System default; unsupported system languages use English.
Paths, model names, and external diagnostic output remain unchanged. Date/number
formatting continues to use the system region. Numeric menu text omits the average
prefix (for example, `47.4 tok/s`); the popover retains the measurement explanation.
UI37–UI42 cover default/fallback, isolated defaults persistence, switching both
ways, and preservation of unknown external text. UI01–UI42/P01–P06 passed, and
English/Korean settings fixture images were visually checked for clipped labels.
The arm64 app/helper bundle built successfully. Actual post-replacement menu
interaction and full-product QA remain unverified; no Hook/provider operation or
user metadata change was performed.


## Hold tok/s between usage reports

Work average now samples elapsed time only at usage reports, preserving the value
through Idle, tools, approval, and the next turn's warm-up. Live visible estimates
retain their separate contract. Main explicitly says that the latest usage-log
average is held until the next report. UI01/04/05/07/15/16/18/35/36 verify the new
aggregate, held Idle value, new-turn carryover, source exclusion, and menu copy.
All UI01–UI42/P01–P06 fixtures passed. Synthetic Idle rendering shows rates beside
Idle statuses; it is not proof of actual runtime stability. Actual post-build
observation remains pending, and full-product QA is not complete.


## Tool-excluded estimate display

The reported-mode preference retains its stored key but is now presented as
도구 제외 추정 / Tool-excluded estimate. The heading and tooltip explicitly
separate it from pure generation speed; server response latency can remain.
Completed whole-turn averages in Details are labeled as including tools. Last
values remain held between reports and through Idle. UI01–UI42/P01–P06 fixtures
passed. Actual runtime comparison against a provider's generation clock is not
available from these logs and is not claimed.


## Native compact screenshot adaptation

The user's supplied macOS Native Compact image is the custom visual reference.
The overview is now 380 by 520 points: compact title/activity header, aggregate
speed and process count, observed working/idle/unknown counts, full-row detail
buttons with status icons, and connection/settings footer controls. Unidentified
process rows remain noninteractive rather than pretending to have session details.
The inset row treatment follows the supplied screenshot; there are no nested
content card shells or decorative shadows. The native popover still owns screen
placement, scrolling, keyboard dismissal, and system appearance.

System typography and flat native controls were retained. Dark panel/row colors
are 0.19/0.055 white; the light counterpart uses the system panel and 0.94 rows.
Measured secondary contrast is 6.58:1 on the dark panel and 5.87:1 on light rows;
light active/attention icons are 5.23:1/4.72:1. Status is also written as text.
Synthetic dark/light reference renders were inspected; fixture watermarks are
additional evidence labels and do not appear in the actual app. Measurement
semantics are unchanged, and the heading uses Combined throughput rather than
claiming pure server generation speed. All UI01–UI49/P01–P06 assertions passed.
UI47/48 cover observed process counts; UI49 keeps activity counters unknown during collection errors. Native keyboard/focus interaction and
post-replacement visual acceptance remain unverified; full QA is not claimed.

Applied workflow: minimal-code, systematic-ui-ux-design, logic-driven-ui-design,
and design-md-frontend screenshot implementation guidance.


## Native materials, real usage graphics, and rate units

The latest user screenshot and explicit macOS guidance are the reference: system
SF typography, system popover shadow/corners, regular material with a restrained
blue tint, lightweight grouped rows, and blue/indigo data graphics. Details adds
a real five-minute observed-output chart and context-use ring. Technical fields
remain available in a disclosure section rather than being deleted. Unsupported
one-hour/day history, a fabricated one-minute average, process termination and
share controls were not added. The secondary metric is observed five-minute
output, not an invented rolling speed.

UI50–56 verify no initial cumulative replay, fresh deltas only, no catch-up bars
after gaps, bounded recency, removal of exited processes, icon-only unavailable
menu text, and the first fresh report after a known warmup baseline. History is
in-memory, source/epoch scoped, limited to five minutes and 600 points per current
session. The chart bins actual observations into ten-second columns.

UI57–59 verify second/minute conversion and missing/zero preservation. Rate unit
is saved in the existing defaults and applied to menu, aggregate, rows, and detail
rates. `tok/m` is a display conversion (60x), not a different averaging window.
UI60 verifies the observed generating state and a 57.9% context fixture. All
UI01–UI60/P01–P06 passed; dark/light populated-detail and small-height renders were
inspected. Native blur compositing, keyboard interaction and extended runtime
history have not been independently verified. No provider request was made for
this UI task. Full-product QA remains incomplete.


## Wide detail layout and root usage chart

The user's wide-detail and root-chart references now drive a 680pt layout, clamped
to the current screen width; height is 720pt or the available screen height. The
hosting view receives the same explicit dimensions as the native popover. A
380pt fixture verifies stacked fallback for narrow layouts.

Details now presents summary metrics, context ring/cumulative counters, an actual
observed-output chart, quota, two-column process/connection metadata, an always
visible advanced section, and the latest exact counters. Advanced IDs/path use
compact copy buttons and middle truncation with full-value help; clipboard failure
handling is shared with the existing copy controls. Server diagnostics and source
warnings remain available. No new usage or timing calculation was introduced.

The root chart reuses the same bounded ten-second bins. Only currently verified,
connected, unreconciled-free sources contribute, and a collection error suppresses
the root chart. UI61–63 verify these scope/error boundaries. All UI01–UI63/P01–P06
passed; wide dark/light, full-detail, root-chart and narrow fixtures were inspected.
Charts contain synthetic fixture observations, not provider performance evidence.
Actual desktop placement, copy clicks and native resizing on small screens remain
unverified. Full QA is not claimed.


## Thirty-minute chart window

At the user's request, both overview and detail charts now show the last thirty
minutes in one-minute bins. Retention and chart geometry share the same window
and bin constants; the in-memory cap is 3,600 points per current session. UI64
checks that data survives beyond five minutes, and UI53 now checks thirty-minute
expiry. This changes chart history only, not the throughput calculation or the
tok/s versus tok/m display conversion. History remains observation-only and is
not backfilled from cumulative counts after an app restart.

## Persistent history and compact process colors

Observed chart deltas now persist in the protected metadata SQLite database.
Restart restoration keeps only the last thirty minutes, converts stored wall-clock
ages to the current monotonic clock, and never restores live counter anchors.
Clear Metadata deletes chart history in the same transaction as other metadata.
UI65–UI72 cover restart/reboot mapping, initial discovery, no catch-up samples,
expiry, wrong-home/corrupt archives, re-baselining and future timestamps. S237
covers database reopening and clearing without changing original logs.

The default popover width is 460pt. Project icons use blue/indigo/cyan accents;
working is blue, tool/approval activity purple, generating green, idle gray and
unknown/disconnected orange. State text remains visible alongside color.
UI01–UI72 and P01–P06 passed in `.build/qa-history-persistence`; the 460pt dark
root fixture was inspected. All 68 Core/Collector tests passed for persistence.
These are scoped automated and synthetic rendering checks, not full QA or proof
of a long-running native restart. Old unsaved history cannot be recovered.

## Glass styling and settings hierarchy

The supplied settings screenshot defines the grouping: General, Behavior,
Privacy/Data and Quit. The 460pt layout uses trailing controls, system switches,
section headings and flat separators rather than nested card shells. Existing
bindings, confirmations, availability guards and status/error labels are retained.
The shared popover background supplies material, a restrained light edge and tint
across Overview, Details, Connection and Settings. macOS 26+ uses native glass
button styling; older systems retain bordered controls. Reduce Transparency uses
an opaque system background and bordered controls. No monitoring logic changed.

Validation: UI01–UI72/P01–P06 fixture suite; Korean/dark and English/light settings
renders. Real desktop backdrop compositing and keyboard traversal are not proven
by the fixture captures. Full QA is not claimed.

## Connection page hierarchy

Adapted the supplied connection reference at the existing 460pt width: terminal
intro, log location, optional hooks, diagnostics and managed direct connection.
Flat titled sections reuse the shared glass backdrop. Paths and commands have
adjacent copy controls, wrapping monospace text and explicit unavailable states.
Related actions share a row; diagnostic text and installer/compatibility results
remain visible. Existing confirmation, busy guards and callbacks are unchanged.
No hooks or provider commands were executed for this presentation change.

## Compact speed labels

Speed units now display as `t/s` and `t/m` across the menu, overview, session rows,
details and settings. Stored unit preferences and the 60x minute conversion are
unchanged. The menu uses 12pt monospaced digits; the overview number is 24pt and
row rates are 11pt. UI07/36/57/59 retain explicit unit and conversion assertions.

## Restart persistence scope regression

The application passed the hashed metadata-directory identifier to the chart
archive while Collector ThreadKey.homeID contains the canonical Codex home path.
Encoding silently filtered every real sample out. Read-only inspection confirmed
an existing archive with zero entries and samples. UI73 reproduced the silent
empty-write bug before the fix; UI74 checks the real path-shaped identity round
trip. AppDelegate now supplies the canonical home path for both encode and decode;
encoding rejects mismatched scopes instead of silently discarding samples.
Previously empty archives cannot reconstruct the lost observations.

## Usage-limit percentage and reset countdown

The final user requirement is remaining percentage, calculated as 100 minus
`used_percent`, followed by days and hours until `resets_at` (for example,
`57% left · 6d 19h` when used_percent is 43). The seven-day quota window is
not time remaining. Missing deadlines are unknown; expired deadlines await
reset and do not fabricate a new allowance. UI24/75–77 cover the percentage
direction, reset countdown, English labels and expired deadline. No provider
request was made.

## Stable chart buckets during idle

The chart previously grouped observations relative to the current poll time.
Advancing that time could split or combine existing points into different
one-minute bars without new usage. UI78 reproduces this with two observations
in one fixed minute and a one-second clock tick. Bins now use fixed minute
boundaries, with the displayed thirty-bin window advancing once per minute.
Existing bars keep their totals until new observations arrive or that minute
leaves the window. No usage counters or persisted samples are changed.

Minute boundaries map monotonic sample times to the wall clock using one shared
clock offset. Each bucket begins at second 00, not at process-uptime minute
boundaries. UI82 covers observations straddling wall-clock 00 with a non-zero
uptime offset.

## Tokloom display name

The app UI, accessibility names, Info.plist display name, generated app bundle,
ZIP/checksum names and future release titles now use Tokloom. The bundle identifier,
UserDefaults domain, metadata location, Swift module names and helper protocol
remain unchanged to preserve existing settings, histories and hook ownership.
UI01–UI82/P01–P06 passed. Workflow syntax and packaging are checked locally;
the already-published 0.0.1 release is not rewritten by this rename.

## Ten-second idle rate grace

On the user's request, the shared reported-rate accessor keeps the last average
for less than ten seconds after turn completion, then returns nil. Individual
rows show a dash and ReportedFrame excludes the expired value from the main/menu
aggregate. Working/tool/approval intervals still hold the last rate. Starting
new work after the idle timeout clears the old held value until a fresh report;
chart observations and completed-turn details are retained. C32 tests the exact
boundary and new-turn behavior, while UI83–84 check row/menu agreement and history
preservation. Core/Collector: 72 tests; UI/process checks: UI01–UI84 and P01–P06.
