# Collector Live inputs

Status: implementation and compile only. Tests, QA, review, runtime applications,
provider execution and captures are NOT RUN by user instruction.

## Live API and boundary

`SessionSnapshot.liveRate: Double?`, `liveMeasurement: Measurement` and
`liveUnavailableReason: String?` are independent of reported usage. Callers use
one `CollectorSnapshot.observedAt` frame for every row. No completed-turn speed
is exposed. Reported counters, source selection and reconciliation keep their
existing authority.

`VisibleWindow` stores only bounded item IDs, counts and local frame samples.
Each update replaces that item's current count, including downward BPE boundary
corrections. The 5-second difference uses the sum of current item counts. The
first complete observed zero/start sample begins five seconds of warm-up.
Incomplete starts, invalid samples, reconstruction mismatch, gaps, source changes,
backlogs, restart and sleep invalidate the window; a new complete item can warm
up again. Negative net windows return no speed rather than discarding correction.

Managed schema 1 `visible_count` and `visible_unavailable` records follow
the removed live estimator (producer-owned). Counts require exact active turn and
item IDs, complete_from_start, final, corrected, text_mismatch, model and encoding.
Normal corrected counts remain valid; text_mismatch marks Partial. No tokenizer
or raw text is stored in the collector. The producer owns verified model mapping;
the consumer accepts only its explicit six-model/o200k_base contract.

Historical records never enter Live. Numeric events older than two seconds or
from a future local monotonic timestamp are rejected as buffered. A collector
refresh gap longer than five seconds baselines existing bytes as historical.
The receive timestamp is solely a freshness check, never server generation time.
Window samples use the collector's shared monotonic refresh time. Unknown or
unsupported inputs preserve reported usage and expose unavailable/partial Live.

Compile command (no test target execution):

```sh
swift build --target CodexHubCollector --scratch-path /tmp/codexhub-collector-build
```

## Observed CLI root subtotal

`SessionSnapshot.observedCLIRoot` identifies only a unique rollout transcript in
this selected home whose validated `session_meta.payload.source` is exactly
`cli` and whose ID equals the authoritative monitor thread ID. It does not prove
complete descendant coverage. The optional `cliSource`
checkpoint field persists this same root provenance; old checkpoints without it
and recovered checkpoints reread at most the first `maximumLine + 1` bytes using
the already safely opened file, requiring a complete first session_meta and exact
checkpoint thread match. Missing, malformed, unknown, subagent or ambiguous
transcripts do not qualify. Unreadable transcripts revoke root proof.

A validated managed direct authority can use this same-home root provenance,
without adding the matching log counter. Existing authority selection, source
reconciliation, gaps and inherited/fork usage baselines remain unchanged.
Reported subtotal requires reported measurement quality; Live requires estimated
quality, connected observation and no reconciliation/stopped-source condition.
Both use the collector snapshot frame. UI always labels the result observed CLI
root subtotal and Partial / child scope unknown, even when every eligible root
has a number. Unclassified rows retain individual measurements and an explicit
subtotal exclusion label. Coverage retains discovered eligible run grouping,
including unknown runs, rather than claiming an undiscovered global total.

Implementation validation is compilation/app build only; all QA, tests, reviews,
captures, actual app/helper operations and provider execution remain deferred by
user instruction.
