# Collector inputs

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
