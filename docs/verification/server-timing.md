# Server timing integration status

## Source baseline

Installed CLI: 0.163.0. Official source tag: rust-v0.163.0, commit
83086188ae0614bd882818ff1aa23f3194962012.

- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/core/src/client.rs
  requests `x-responsesapi-include-timing-metrics` when runtime metrics is enabled.
- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/codex-api/src/endpoint/responses_websocket.rs
  emits `responsesapi.websocket_timing` at the opt-in trace target with
  thread/turn identity and timing payload.
- https://github.com/openai/codex/blob/rust-v0.163.0/codex-rs/otel/src/events/session_telemetry.rs
  maps raw inference, TTFT, and TBT fields into duration metrics.
- https://learn.chatgpt.com/docs/config-file/config-advanced
  documents these metrics, but does not establish raw TBT aggregation semantics.

## Implemented

The user-requested code-only revision adds `--server-timing` to the managed
launcher. Only that spawned app-server receives runtime_metrics and the selective
trace environment; global config is untouched. Bounded stderr lines are parsed
in memory, and only validated identity plus allowlisted finite numeric timing
fields are written as private metadata. Original payload/log text is not stored.
Collector accepts live direct-source timing only for the same thread and turn;
historical replay, gaps, disconnected sources and reconciliation suppress data.

The new server mode is separate from both estimates. It deliberately returns no
numeric rate: neither 1000/TBT nor tokens/(inference-TTFT) is justified by the
inspected public contract, and per-response token correlation is not implemented.
Raw timing values appear in Details. Older estimates remain explicitly selectable.
The measurementModeV2 preference defaults to server mode rather than silently
reusing an earlier estimate selection.

## Verification and remaining work

C29/C30 verify raw and quoted trace fields, invalid identities, warmup exclusion,
size bounds and invalid numeric values. All 65 Core/Collector tests and
UI01–UI44/P01–P06 fixture assertions passed. UI43 proves the server mode cannot
reuse an existing estimated rate; UI44 checks the managed command opts into capture.

Provider requests were explicitly not run. The native managed relay, actual
stderr formatting, server timing delivery and decode-rate semantics remain
unverified. This is a partial implementation of the user's pure generation-speed
goal, not a claim that pure generation tok/s now works. No fabricated producer,
fake successful telemetry, or speculative TBT conversion was added.
