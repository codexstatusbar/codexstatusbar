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
The measurementModeV2 preference now defaults to the usable tool-excluded
estimate. Server timing is an explicitly selected diagnostic mode; it does not
replace working throughput with an unavailable measurement.

## Verification and remaining work

C29/C30 verify raw and quoted trace fields, invalid identities, warmup exclusion,
size bounds and invalid numeric values. All 65 Core/Collector tests and
UI01–UI44/P01–P06 fixture assertions passed. UI43 proves the server mode cannot
reuse an existing estimated rate; UI44 checks the managed command opts into capture.

At the original code-only checkpoint, provider requests were not run. The native managed relay, actual
stderr formatting, server timing delivery and decode-rate semantics remain
unverified. This is a partial implementation of the user's pure generation-speed
goal, not a claim that pure generation tok/s now works. No fabricated producer,
fake successful telemetry, or speculative TBT conversion was added.


## Authorized real probe and remediation (2026-10-17)

The user subsequently requested testing. One isolated ephemeral Codex inference
was executed with gpt-6-astra, low reasoning, no tools, read-only sandbox, and
per-invocation runtime_metrics. Global configuration and existing Codex sessions
were not changed. A zero-engine warmup event was excluded. The inference exited
successfully in about 8.8 seconds and reported 163 output tokens / 0 reasoning
tokens. Raw identifiers and messages are excluded from this report.

Actual server timing differed from the source fixture:

- `num_sampled_tokens_total`: 163 (matches the completed response usage)
- `websocket_output_text_delta_count`: 159
- `websocket_output_text_delta_tbt_ms`: 16.467705253164556
- `num_engine_calls`: 1
- `critical_path.coverage`: `missing_harness_boundary`
- Engine-service total, TTFT and TBT fields: absent

C31 reproduced the real-schema rejection before the fix, then passed. The parser
now retains the actual output-event metadata without inventing engine timing.
The corrected parser was replayed against the original captured stderr in the
private temporary probe directory: exactly one non-warmup sample was accepted,
and its normalized metadata survived a Codable round trip. No second provider
request was made. S236 checks normalized metadata through the real collector,
wrong-turn rejection and gap invalidation; it also caught and fixed stale timing
after markGap. All 67 Core/Collector tests and UI01–UI46/P01–P06 passed.

The source-only change that made unavailable server mode the default caused the
user's working processes to show no rate. The default and current app preference
were restored to reported/tool-excluded estimate. UI45 prevents recurrence and
UI46 prevents output events from being presented as token throughput. Native
managed relay/TUI provider execution and pure decode timing remain unverified;
only the CLI probe, actual-line parser replay, normalized collector replay, and
synthetic presentation checks were completed. Full QA remains incomplete.

## Diagnostic-mode clarification

Inspection confirmed that server mode intentionally returns nil throughput; it
cannot supply pure generation speed from the previously captured event-interval
metadata. The overview and settings now explicitly state that diagnostics do not
calculate throughput. Settings offers an explicit switch to the tool-excluded
estimate. Available raw server timing is shown in Details regardless of the
selected speed mode, while absent timing explains the new-managed-run boundary.
This is a presentation clarification, not a newly verified server throughput
implementation. No new inference or provider request was performed.

## Removal from the app

The user requested removal after selecting diagnostic mode hid throughput in an
installed release. MeasurementMode now contains only reported and live. Legacy
`server` preferences fall back to reported and are normalized on app launch.
The diagnostic panel and app-generated `--server-timing` opt-in were removed.
The helper parser/explicit developer flag remain separate from the app UI.
UI43 checks removed-mode fallback; UI44 checks the launch command; UI46 checks
that raw server metadata cannot replace the reported estimate.
