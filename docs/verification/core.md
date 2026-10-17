# S1 core verification

Scope: `Package.swift`, `Package.resolved`, `Sources/CodexHubCore`,
`Tests/CodexHubCoreTests`, `.gitignore`, glossary, this report.
PRD: `docs/Codex_Hub_PRD.md`, sections 6–10; plan S1.
Production is Swift only, macOS 14 baseline, no production dependency or I/O.
Synthetic inputs only; no user logs, configuration, databases, or providers accessed.

## Public integration boundary

- `TokenUsage` validates nonnegative integer counts. Optional reasoning/total fields
  preserve missing information. `nonReasoningOutputTokens` is nil for missing or
  impossible breakdowns. `last` is deliberately not an ingestion input; adapters
  provide cumulative `total` only.
- `UsageCounter(source:epoch:verifiedEmptyThread:)` and `observe(_:source:epoch:)`
  return baseline/delta/secondarySource/wrongEpoch/regression/suspended. A regression
  latches partial until explicit `reconcile(source:epoch:baseline:)`. Adapters must
  prove authority and checkpoint continuity; the core does not discover identities.
  Last-known optional counters survive missing fields within the epoch; public
  `baseline` remains the exact latest accepted snapshot, including nil fields.
  Rejected observations do not update validation history; reconcile resets it.
- Persist `source`, `epoch`, `baseline`, `isPartial`, `lastKnownReasoningOutputTokens`
  and `lastKnownTotalTokens` together. Restore with throwing
  `UsageCounter(source:epoch:baseline:lastKnownReasoningOutputTokens:lastKnownTotalTokens:isPartial:)`,
  then `ThreadMonitor(key:counter:)`. Restore rejects negative remembered counts,
  disagreement with present baseline optional values, and a missing baseline with
  remembered counts or partial state. A restored monitor has unknown activity,
  no turns and no rate samples. Do not use reconcile for persistence restoration:
  it deliberately resets validation history and clears partial state.
- `ThreadKey(homeID:runID:threadID:)` keeps optional Hub run distinct from thread.
  `ProcessIdentity(pid:osStartTime:)` prevents PID-reuse equality.
- `ThreadMonitor` owns a single thread counter, activity, connectivity, measurement,
  current turn, tool/approval ID sets and turn history. Use `startTurn`, `finishTurn`,
  `setTool`, `setApproval`, `setGenerating`, `setConnectivity`, `markGap`, `reconcile`,
  `observeUsage` and `reportedRate`. All time arguments are finite, nonnegative,
  nondecreasing **monotonic seconds from one shared clock**. Caller serializes calls.
  Read-only UI queries must use a frame no earlier than latest ingested event.
- `observeUsage(... historical: true)` updates history/checkpoints without adding
  rate samples. Use for initial indexing/replay. Explicit reconnect/gap invalidates
  the window; first catch-up report is excluded. Adapters must label queued history
  and correlate each cumulative delta to its proven turn, never invent attribution.
- A new active turn with a baseline but no observed report is `warmingUp` with nil
  speed. A valid zero-delta report is measured zero; expiration of previously
  observed samples is also zero. Completion always returns nil current speed.
- `TurnRecord.average` is nil without the initial baseline, observed start/end,
  complete interval, and positive duration. Late usage can revise history/average,
  but never starts/reopens a turn. Completion and failure both clear current speed.
- `ReportedFrame(monitors:verifiedIndependentThreads:at:)` fixes the PRD 10-second
  interval `(time - 10, time]` for all rows, sums unrounded values and groups coverage
  by home/run (unassigned threads get their own coverage group). Unknown activity
  is eligible; confirmed idle is excluded. Unverified parent/child scope is excluded
  from the subtotal and makes coverage partial; UI must label excluded rows.
  Duplicate thread keys are rejected. An empty/no-measurable frame has nil speed.

## CLT-only commands

From this worktree:

```sh
swift test --build-system native --disable-xctest \
  -Xcxx -isystem -Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"
swift build
git diff --check
```

No global environment or toolchain changes. Build artifacts and dependency checkouts
are confined to ignored `.build`; SwiftPM may use its normal dependency cache.

Toolchain observed: Apple Swift 6.4 (`swiftlang-6.4.0.34.1`), arm64,
CommandLineTools, macOS 27 SDK. This is not a macOS 14 runtime test.

Initial built-in XCTest and Testing imports both failed (modules absent).
Official Swift Testing 6.4.1 compiled with explicit SDK C++ includes but failed to
link `_TestingInterop`, absent in CLT; its manifest disallows linking the internal
DO_NOT_USE substitute. Official 6.2.4 avoids that toolchain dependency. The CLT
clang default search omitted SDK `usr/include/c++/v1`, causing `atomic file not found`;
the command adds that path only for the test build. Native SwiftPM is deprecated by
this toolchain, so revalidate/remove the workaround after a toolchain upgrade.

## Behavior evidence

Every behavior below lives in `Tests/CodexHubCoreTests/CoreTests.swift` and runs with
the test command above. This is focused S1 verification, not full product QA.

| ID / test prefix | Behavior / PRD mapping | Result |
|---|---|---|
| C01 | First snapshot baseline; 100 repeats add zero; output 12,480 reasoning 8,960 gives 3,520; FR-04/05 | PASS |
| C02 | Regression latches suspension; explicit epoch/authority reconciliation; secondary source ignored | PASS |
| C03 | Late usage corrects history/average, remains idle with nil speed; FR-09/17 | PASS |
| C04 | Same frame A600+B300=R90; exact lower boundary expires; completion removes speed; FR-07/09 | PASS |
| C05 | Negative fields rejected; missing/impossible reasoning unavailable; Int.max accepted | PASS |
| C06 | Multiple tools/approvals, correct underlying state, silence remains working, stale events ignored; FR-10 | PASS |
| C07 | Missing initial baseline/start means nil average; old first snapshot never boosts rate | PASS |
| C08 | Disconnect and sleep catch-up excluded; active state preserved; incomplete average unavailable; FR-11 | PASS |
| C09 | Historical replay, secondary authority and wrong epoch excluded from current speed | PASS |
| C10 | Identity/PID reuse separation, coverage and unverified scope, duplicate thread rejection; FR-03/08/16 | PASS |
| C11 | Nonfinite/backward time rejected; regression suspends speed until reconciliation | PASS |
| C12 | Overflow rejects usage without advancing checkpoint or corrupting history | PASS |
| C13 | No report is unavailable; observed zero is zero; new turn resets measurement; FR-10 | PASS |
| C14 | Multiple threads count one run; incomplete run stays partial; idle excluded; FR-08 | PASS |

Final execution on 2026-10-17: Swift Testing 6.2.4 ran 14 tests, all passed.
`swift build` passed (default SwiftBuild; CLT framework-path/PIF warnings only).
`git diff --check` passed. C12/C13 were observed failing before their fixes.
The temporary executable test harness was removed in favor of standard test discovery.

## Dependency review

Test-only direct package `swiftlang/swift-testing` exact 6.2.4; transitive
`swiftlang/swift-syntax` 602.0.0. Full revisions are pinned in `Package.resolved`.
Production target has no dependencies. Upstream manifests use standard Swift
compiler macros and C++ testing internals; no added custom project build plugin.
SwiftPM downloads official swift.org macro prebuilts when available.

Official repository public security-advisory API queries returned empty arrays on
2026-10-17 for both packages. This is a **partial static dependency review**, not a
vulnerability scanner or a security certification. Recheck advisory/compatibility
status when upgrading; 6.4.1 is newer but requires absent CLT interop support.

Sources: [Swift Testing releases](https://github.com/swiftlang/swift-testing/releases),
[6.2.4 manifest](https://github.com/swiftlang/swift-testing/blob/6.2.4/Package.swift),
[6.4.1 manifest](https://github.com/swiftlang/swift-testing/blob/6.4.1/Package.swift).

## Remaining boundaries

No UI, parser, filesystem collector, DB transaction/recovery, tokenizer, relay,
provider, G0, performance endurance, signing or notarization proof. `qa-verification`
is disabled and was not loaded. S2 owns persistence/retention and source verification;
S3 owns rendering, accessibility, rounding and actual app runtime. History is an
in-memory map, not a bounded persistence store. Scope and identity verification
cannot be inferred by this core. Independent integration review remains with the
coordinator/verifier; these are implementer-owned checks.

Applied skills: minimal-code, ponytail, reuse-defensive-decoupled-coding,
mattpocock-skills:tdd, shared-glossary, orca-cli, orchestration, diagnose,
dependency-vulnerability-audit.

## r01 implementation handoff

Fixed optional known → nil → lower regression; retained public nil values and
source/epoch rejection semantics. Added validated checkpoint restoration for S2;
no serialization, collector, manifest or dependency changes.

C15 reproduced reasoning/total failures twice before the fix; C15 then passed.
Before the latest QA-stop instruction was received, the 19-test core run passed,
followed by focused C19/C20 restoration tests (including four C19 cases).
Logs: `/tmp/codexhub-r01-red.log`, `/tmp/codexhub-r01-red-repeat.log`,
`/tmp/codexhub-r01-tests.log`, `/tmp/codexhub-r01-restore-tests.log`.
C16 covers equal/higher, rejected authorities/epochs and reconcile reset; C17
partial/nil rate propagation; C18 input/cached/cache-write decreases; C19 restore
retention without invented activity; C20 invalid restoration boundaries.

Final QA/review/retest is **user-cancelled**, not PASS. No further QA infrastructure
or tests were started after receiving the stop instruction. Full product/native,
provider, persistence integration and independent verification remain unrun here.
Applied: minimal-code, diagnose, mattpocock-skills:tdd, ponytail,
reuse-defensive-decoupled-coding, orca-cli, orchestration. Disabled qa-verification
was not loaded.

## Work-average mode (user-approved 2026-10-17)

The app's ReportedFrame now sums workAverageRate values at one shared frame time.
Each turn retains an observation start and output baseline; waiting/tools/approval
do not reset them. Completion clears the current rate and retains workAverage for
Summary. Late same-turn usage updates that completed record without reviving it.
A missing start/baseline, gap or reconciliation establishes an observed-period
baseline, excluding catch-up increments. Such averages are explicitly partial.
No-report, zero-duration and nonfinite rates remain unavailable; an actual zero
increment report can produce zero. The low-level reportedRate API retains its
legacy rolling-window behavior for compatibility, but the UI no longer uses it.

C21 failed before the change (10-second expiry returned zero instead of 20/10).
C21–C26 now cover sustained means, tools/waits/completion/late usage, observation
baselines and gaps, valid zero, differing start times summed at a common end, and
zero/tiny-time boundaries. S227 also checks the reattached observed average.
All 58 Core/Collector tests passed. This is scoped verification, not full QA approval.


## Usage-event-held averages

The user changed the display contract to calculate only when fresh usage arrives.
C27 failed on the previous implementation (time decay, Idle clear, next-turn
clear), then passed with a cached usage-event average. C21/C22 now verify unchanged
rates across elapsed time, tools, approval, and completion. C27 also checks that a
late older-turn report cannot overwrite the newest turn's value and that gaps
invalidate held data. C26 requires a positive elapsed interval at the actual
report time; a later UI tick cannot manufacture a rate. ReportedFrame sums held
verified values, including Idle rows with a usable rate, while preserving scope
suppression. All 59 Core/Collector tests passed. Legacy reportedRate remains a
separate API and does not drive the UI.
