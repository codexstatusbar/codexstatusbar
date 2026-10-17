# S2 collector implementation and focused checks

Scope: `Sources/CodexHubCollector`, `Sources/CSQLite`, collector tests and SwiftPM
collector/shim targets. PRD sections 6, 8–10 and FR-04/08/09/11/12/14/17.
No UI, provider request, Hook installation, user-log mutation or PID inference.
Production is Swift plus the system SQLite module map/header, with no fetched
production package. Tests reuse the pinned official Swift Testing dependency.

## Public API for native UI

```swift
let collector = try LogCollector(codexHome: selectedHome,
                                 metadataDirectory: privateHubDirectory)
await collector.start()                  // optional one-second polling
let state = try await collector.refresh() // also usable without start
let latest = await collector.snapshot()
try await collector.updateRetention(RetentionPolicy(days: 7, maximumSessions: 1000))
try await collector.markGap()             // before queued sleep/wake data
try await collector.clearMetadata()       // Hub rows only, never source logs
await collector.stop()
```

The metadata directory's parent must exist. The DB binds a hash of the selected
home identity; a different home with that directory throws `sourceMismatch`.
Use one private metadata directory per home and stop/release the old collector
when switching. Clearing rows does not remove this isolation binding. The collector creates the directory
0700 and SQLite file 0600. Metadata inside selected Codex home is rejected.
`CollectorSnapshot`: sessions, bounded typed diagnostics, observedAt (monotonic).
`SessionSnapshot`: file identity id, cwd, model, core monitor, lastObserved (wall
seconds from file modification time), hasGap, verifiedIndependentScope=false.
Use monitor.key.threadID as upstream identity; runID is nil and UI says Session only.
Caller never supplies a synthetic PID or treats file modification as generation.
`CollectorDiagnostic.message` and `CollectorError.message` are fixed safe strings.
`CollectorError` has no source text. Display source/storage failure diagnostics;
`refresh` can throw without committing a new checkpoint or new usage state.

`start` is idempotent; `stop` cancels this collector's polling only. Explicit refresh
and background polling serialize on the actor. Multiple owners of the same metadata
directory are rejected via an exclusive directory lock. Snapshot copies are Sendable.
Two files claiming the same thread produce one degraded session and a diagnostic,
not two summed counters. Parent/child inclusion cannot be proven from logs, so the
UI must preserve Partial coverage instead of calling it a complete total.

## Persistence, input and security contract

- Selected home opened as owner-checked directory descriptor. `sessions` and all
  descendant opens use `openat`, no-follow and owner checks; source reads use
  O_RDONLY and regular-file/single-link validation. Directory scans are descriptor
  relative, so path replacement does not follow outside the selected directory.
- File identity is device+inode; offset is last complete newline. No incomplete
  UTF-8 bytes are saved. A SHA-256 digest of at most 128 preceding bytes checks the
  checkpoint boundary without persisting text. Shrink/replacement/boundary change
  starts historical replay in a fresh epoch and reports a gap. Moves preserve ID.
- First discovery and restart catch-up are historical. Historical lifecycle events
  supply context only, never assert Working or Idle. A new lifecycle event is
  required for current activity. token_count without a turn context restores a
  cumulative baseline without inventing a turn ID. Null info is ignored.
- Only explicitly allowed numeric counters, source/file identity, thread/turn IDs,
  cwd/model, epoch, offsets, flags and times survive JSON decoding. No prompt,
  response body, last_agent_message, diff, tool output, auth or raw record is saved.
  Unknown event types are ignored; malformed lines produce bounded diagnostics.
- SQLite stores each sanitized file state and offset together in one transaction;
  actor state publishes only after commit. Secure delete, FULL synchronous and
  DELETE journaling are configured. Root/db inode continuity, owner/modes and
  database journal/wal/shm symlink/hardlink conditions are checked before writes.
  SQLite receives a POSIX `realpath` path and SQLITE_OPEN_NOFOLLOW: Foundation URL
  canonicalization on this host rewrote `/private/var` to `/var`, which SQLite
  correctly rejected because `/var` is a symlink.
- Maximum file 256 MiB, read batch 1 MiB, record 256 KiB, 20,000 directory entries,
  16 levels, 100 diagnostics per refresh. Oversized/inaccessible files cannot block
  other valid sessions. Source files are never truncated/deleted to enforce limits.
- Retention defaults to 7 days/1000 file states, configurable within 1–365 days and
  1–10,000 states. Expiry uses source mtime, avoiding perpetual reimport of old files.
  `clearMetadata` deletes Hub rows with secure_delete; subsequent refresh may reindex
  still-existing source logs historically. Stop polling first if UI wants to keep
  the cleared view empty. SQLite file allocation need not shrink after deletion.

## Repeatable focused verification

Latest user direction skips all QA/tests/reviews now, including focused regressions.
No further QA infrastructure, inventory or testing is added; final compilation only.
The commands below are retained for the user to run later, not claimed executed.

All fixtures create UUID-named temporary roots and remove only those roots. No real
Codex logs, home configuration, credentials, provider or production DB are accessed.
All clock-sensitive cases inject one fixed monotonic frame. Tests manipulate only
fixture files, modes and links. Run all current tests, including the core suite:

```sh
swift test --build-system native --disable-xctest \
  -Xcxx -isystem -Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"
swift build
git diff --check
```

The existing focused tests below maps to the exact Swift test function prefix in
`Tests/CodexHubCollectorTests/CollectorTests.swift`; the reverse links are the stable
S2 IDs in function names. To run one test use the same command with `--filter S2NN`.
Core behavior is mapped in `docs/verification/core.md`; all current core tests run
in the command above, including independently supplied r01 remediation tests.

| ID / test prefix | Requirement / observable behavior | Result |
|---|---|---|
| S201 | Initial old large counter becomes baseline; historical task_start stays Unknown | NOT RUN — user skipped QA |
| S202 | New task lifecycle; duplicate total zero; last not summed; late usage stays Idle | NOT RUN — user skipped QA |
| S203 | Split UTF-8 and unfinished JSONL line are retried only after newline | NOT RUN — user skipped QA |
| S204 | Malformed line isolated; null token info ignored; missing turn remains unattributed | NOT RUN — user skipped QA |
| S205 | Restart checkpoint/counter restored; queued old completion cannot imply current Idle; fresh lifecycle resumes | NOT RUN — user skipped QA |
| S206 | Truncate, rotation, moved file identity; no past throughput spike | NOT RUN — user skipped QA |
| S207 | Storage rejection leaves checkpoint/published count unchanged; retry processes once | NOT RUN — user skipped QA |
| S208 | Prompt/auth/body sentinel absent from DB/journal; source bytes unchanged; stored files 0600 | NOT RUN — user skipped QA |
| S209 | Symlink and hardlink source denied; symlink metadata root denied; other file still processed | NOT RUN — user skipped QA |
| S210 | Independent sessions; row cap; metadata clear; source preservation; invalid retention denied | NOT RUN — user skipped QA |
| S211 | Oversized record isolated; negative counter rejected | NOT RUN — user skipped QA |
| S212 | Sleep catch-up excluded; missing sessions root reports Disconnected | NOT RUN — user skipped QA |
| S213 | Metadata/source separation; second owner rejected; malicious journal link never overwritten | NOT RUN — user skipped QA |
| S214 | Same-size boundary rewrite resets epoch; expired source removed | NOT RUN — user skipped QA |
| S215 | Persisted regression remains Partial after restart; no fabricated turn | NOT RUN — user skipped QA |
| S216 | Replaced SQLite inode rejected before state publication | NOT RUN — user skipped QA |
| S217 | Boolean/fractional/negative/overflow/null counters rejected; future records ignored | NOT RUN — user skipped QA |
| S218 | Real polling start/stop idempotent; no duplicate worker loop | NOT RUN — user skipped QA |
| S219 | Duplicate files for one session cause degraded single authority, not double count | NOT RUN — user skipped QA |
| S220 | New task after missed completion reports gap and excludes catch-up amount | NOT RUN — user skipped QA |

## Final implementation status

Core r01 commit `68673becd8cdb4453d36023ba9bab7cb1986e1d6` was merged before the
final collector build. Restore uses its validated UsageCounter initializer and
ThreadMonitor(key:counter:), preserving baseline, partial and both last-known
optional cumulative counters. No S2 core edits remain.

`swift build` completed successfully on 2026-10-17 (Swift 6.4, arm64, macOS 14
compile baseline; existing CLT framework-path/PIF warnings). Final tests, review
and runtime QA: **NOT RUN, explicitly skipped by user**. Earlier first-run fixture
results predate final implementation changes and are not final acceptance evidence.

## Boundaries not claimed as verified

This is implementer-owned S2 evidence, not independent integration approval or a
full-product QA pass. `qa-verification` remains disabled/unloaded. No actual provider,
UI, full TUI relay, tokenizer, macOS 14 runtime, eight-hour endurance, signed bundle
or device performance was tested. A malicious same-UID process has the same authority
as the app; filesystem mode checks are not a sandbox against that user. Negative
foreign-owner behavior requires a separately owned fixture and is not exercised by
these unprivileged temporary fixtures; owner checks are enforced in source and all
positive owner paths run. The source is append-oriented: arbitrary rewrites far
before an unchanged checkpoint boundary are not a complete file-integrity audit.

Applied skills: minimal-code, ponytail, reuse-defensive-decoupled-coding,
mattpocock-skills:tdd, security-hardening-review, orca-cli, orchestration, diagnose.

## S2b managed metadata source

`LogCollector(codexHome:metadataDirectory:managedRunsDirectory:monotonic:wallTime:)`
adds `managedRunsDirectory: URL? = nil`; existing named call sites remain valid.
UI supplies `~/Library/Application Support/CodexHub/managed-runs/<homeHash>`.
Hash uses Foundation `resolvingSymlinksInPath().standardizedFileURL.path`, UTF-8,
SHA-256 lowercase hex, exactly as the producer. Core home identity remains the
selected canonical Codex home, never the synthetic managed metadata root.

The shared safe reader/JSON decoder/SQLite checkpoint path handles both roots.
Managed directories and files must also be private (no group/other access), owned
by the user, regular/single-link where applicable and opened without following
links. A missing managed root or sessions directory is normal. An unsafe managed
root produces a diagnostic and is not read. Bad/missing rollout data does not
block an independent valid managed root. Original rollout logs are never written or deleted.
The closed-owned managed-file cleanup described below is the only producer-file deletion path.

Contract owner: `docs/managed-helper.md` from helper commit `99c8b96`.
Thread file path: `sessions/<run UUID>/<local UUID>.jsonl`; run-events.jsonl is
ignored as a session input. Every accepted direct record must match schema integer
1, literal direct-relay, homeHash, path run UUID, consistent actual thread ID,
ISO8601 receive timestamp and decimal-string received_monotonic_ns. These markers
are grouping checks, not protection against a malicious process with the same UID.

Supported exact payloads: session_meta; event_msg task_started/task_complete,
token_count (actual turn_id and cumulative total only), hub_tool_started/completed,
hub_approval_requested/resolved, measurement_gap, hub_connection disconnected.
Unknown direct types/versions or malformed required fields are rejected with safe
diagnostics. String request IDs and integer IDs use separate typed namespaces.
Resolution clears only an observed matching approval of the active turn. Explicit
turn IDs keep late usage separate from a newer turn's state. Gap stops observation
for that file; no subsequent activity is fabricated. Initial/restart catch-up
remains historical and needs a new lifecycle event for current activity.

New `SessionSnapshot` fields:

- `source: UsageSource` (directRelay or rolloutLog).
- `processes: [ManagedProcessInfo]`: role (.tui/.appServer/.relay), pid:Int32,
  startSeconds/startMicroseconds:UInt64, computed `identity: ProcessIdentity`.
  Values come only from session_meta.payload.processes.{tui,app_server,relay}
  with exact pid/start_seconds/start_microseconds. They are measured historical
  identities, not guessed PIDs. Runtime relay presence compares OS start identity;
  absent/reused/unreadable relay becomes Disconnected/Unknown, never Idle.
- `sourceReconciliationPending: Bool`, `observationStopped: Bool`.
- `measurement: CodexHubCore.Measurement`: authoritative presentation quality;
  pending source reconciliation or stopped observation returns Partial. UI should
  use this property rather than only monitor.measurement for its quality label.

Authority selection is persisted with checkpoints. One visible source is chosen
per actual home+thread, independent of optional run ID; an available matching
managed source is preferred. Secondary rollout counters are never added. Switching
compares complete accepted cumulative checkpoints and last-known optional counter
values, clears the selected rate window, and remains Partial until they match.
If a stopped source can never provide that match, Partial remains explicit instead
of inventing continuity. Ambiguous same-source files degrade one visible authority.
Subagent inclusion remains unverified (`verifiedIndependentScope == false`).

Only collector code/docs changed in S2b; Core, manifest, lockfile, UI and helper
remain under their owners. Applied minimal-code, ponytail,
reuse-defensive-decoupled-coding, orca-cli and orchestration. Build command:
`swift build --target CodexHubCollector`. Tests, captures, reviews, actual sessions,
provider calls and all QA are NOT RUN at the user's explicit request.

### Closed managed-file cleanup

At the coordinator's explicit S2b direction, successful retention/clear transactions
also attempt removal of fully indexed, validated managed thread observation files.
The collector requires the recorded relay PID+OS start identity to be proven gone
(or reused), rechecks the source's private directory/file descriptors, device/inode,
complete offset/size, boundary digest and first session_meta envelope/processes,
then unlinks only that exact managed filename through its checked parent descriptor.
No signal is sent to any process. Active or unreadable/unknown process identity,
malformed/incomplete/replaced files, or unproven markers cause preservation and
`CollectorError.cleanupDeferred`; clear/retention does not claim those files gone.

Exact remaining storage gap: never-indexed old files, run-events.jsonl (which lacks
thread/process ownership records), empty run directories, and unknown/active run
files are not deleted by this implementation. The diagnostic makes that partial
cleanup explicit. Therefore SQLite state has the configured row/age bound, but
aggregate producer-directory disk use is **not claimed fully bounded**. A future
closed-run manifest or lifecycle-authoritative cleanup owner is needed to safely
reclaim those remaining artifacts. UI must display cleanupDeferred after clearing
instead of reporting that all producer files were removed.

Final S2b compiler command `swift build --target CodexHubCollector` succeeded on
Swift 6.4 arm64 with existing CLT/PIF warnings. No test/review/runtime/provider
execution was performed for this slice.
