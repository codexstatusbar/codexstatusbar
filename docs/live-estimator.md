# Live visible estimate (Swift helper)

Implementation status: compile-only; QA, tests, review, captures, actual relay,
provider, app runtime and tokenizer parity checks are NOT RUN by explicit user
instruction. This is an estimate implementation, not a verified production claim.

## Schema 1 contract

Existing managed-helper direct-relay envelope and exact observed thread ID apply.
`received_monotonic_ns` is decimal UInt64 local uptime at receipt of source bytes;
never server generation time. Timer samples retain the latest contributing delta
receipt time. Collector uses its shared monotonic frame and rejects stale/buffered
records; it must not assume a sample every 500 ms or extrapolate missing text.

`visible_count` payload:

- `turn_id`, `item_id`: exact observed identifiers, never synthesized.
- `count`: nonnegative integer cumulative ordinary-text BPE count for this item.
- `complete_from_start`: true; an actual empty agent item start was observed.
- `final`: boolean, true only for the actual item completion.
- `corrected`: boolean, true for downward BPE correction or final text mismatch.
- `text_mismatch`: boolean, distinguishes final reconstruction mismatch from normal BPE correction.
- `model`: observed allowlisted model identifier; `encoding`: `o200k_base`.

Start emits count=0, final=false. Repeated equal deltas are appended. Never sum
these cumulative counts or discard negative corrections. A final mismatch marks
quality partial; ordinary count decreases alone are valid boundary corrections.
Collector owns the 5-second window, warming-up, authority, gap/epoch invalidation
and completed-turn removal. Live and reported usage remain separate.

`visible_unavailable`: `turn_id`, `item_id`, and `reason`, with no text/count.
Reasons: `model_changed`, `turn_boundary`, `duplicate_start`, `missing_turn_start`,
`unsupported_mapping`, `message_bound`, `nonempty_start`, `missing_item_start`,
`tokenizer_unavailable`, `work_bound`.
A global observer gap additionally invalidates all estimates, including resource
tracking exhaustion (`metadata_bound`). No fabricated item/turn IDs for gaps.

## Integration ownership

Main owner: pass client bytes to `observer.submitClient(data)` **before** upstream
`writeAll`, using the existing bounded nonblocking observer enqueue. This preserves
request/response ordering while leaving raw relay bytes and approval replies
unchanged. Existing server `observer.submit(data)` stays after downstream write.
Do not parse, rewrite or persist the client frame in main.

Manifest owner: add `resources: [.copy("Resources")]` to the `CodexHubHelper`
executable target. The helper safely resolves the generated SwiftPM bundle and loads its
`resourceURL/Resources/` directory. It does not invoke the generated accessor,
which would trap on a missing bundle.
Package the generated `CodexHub_CodexHubHelper.bundle` next to the standalone helper
or at the application bundle resource location supported by SwiftPM's generated
accessor (`Bundle.main.resourceURL` or `Bundle.main.bundleURL`). The first lookup
is next to the actual executable from `_NSGetExecutablePath`, resolving symlinks;
portable app layout is `Contents/Helpers/codex-hub` plus
`Contents/Helpers/CodexHub_CodexHubHelper.bundle`. No argv/env path is trusted. Assets: `o200k_base.tiktoken`, `o200k_base.pattern`,
`tiktoken-LICENSE.txt`. Direct swiftc builds use `Bundle.main.resourceURL/Resources`
and compile without an accessor; no resources means unavailable, not a fallback.
No Package.swift/main/packaging changes are owned by this worker.

## Model evidence and boundaries

Installed Codex 0.163.0 generated schema (P0 aggregate SHA256
`43e8c1495557ca91e33a63bbfae36c311c206253afae2974c979dbdf5d940c71`):
`ThreadStartResponse`, `ThreadResumeResponse`, `ThreadForkResponse` report top-level
`model`, `modelProvider`, and `thread.id`; `ThreadSettingsUpdatedNotification`
reports `threadId`, `threadSettings.model` and `threadSettings.modelProvider`.
`ThreadStartedNotification.thread` also has model/provider; model may be null.
`TurnStartParams.model` and `collaborationMode` override selections. Client
requests retain only typed request IDs and method classification; model overrides
invalidate mapping until a matching server observation re-establishes it. Older pending responses
are rejected after selection revision changes. No mapping is enabled before any
client protocol metadata has been observed, so absent main wiring fails closed.
`model/rerouted` invalidates mapping and raw item buffers. Client prompts and
other fields exist transiently in bounded JSON/frame decoding only, never retained.

Only provider identifier `openai` and exact models `o1`, `o3`, `o4-mini`, `gpt-5`,
`gpt-4.1`, `gpt-4o` are supported. These are explicit mappings in pinned tiktoken,
not speculative prefix matches. Other encodings, newer models, custom providers,
missing model metadata or observed overrides without server confirmation are
unavailable. Provider ID is observed configuration, not attestation of remote
endpoint identity. No direct source requests are made.

## Bounds and privacy

Whole cumulative message is tokenized, never independent delta sums. Four active
items maximum, each 16 KiB UTF-8; only empty starts after observed turn start are
accepted. Duplicate item starts, missing starts and gaps fail closed. Raw text is
cleared immediately on completion, invalidation, gap and turn boundary. Finished
item IDs (up to 4096 per relay) prevent replay; exhaustion stops observation.

Active recalculation batches run at most twice per second across the relay; each regex
segment is capped at 512 bytes, each message at 4 million candidate-byte work and
50 ms progress deadline. The official pattern uses Foundation/ICU Unicode regex;
parity with tiktoken's regex engine is untested. Oversized segments are not split
arbitrarily. Special-token-looking strings are ordinary text.

Terminal completion may perform one bounded final recomputation outside the active
2 Hz limit, per coordinator clarification: final text must be reconciled before
immediate purge. If final text equals the last calculated text, the cached count
is emitted without recalculation. UI rendering remains at most 2 Hz.
No chars/4, chunk counts, reasoning, tool output, diff, user prompts or historical
text are included. Unsupported estimates do not alter reported usage or transport.

## Pinned tokenizer assets

Official source: [openai/tiktoken 0.12.0](https://github.com/openai/tiktoken/tree/97e49cbadd500b5cc9dbb51a486f0b42e6701bee).
Pattern and expected asset hash are from `tiktoken_ext/openai_public.py`;
exact model mapping is from `tiktoken/model.py`; MIT license copied from `LICENSE`.

- Encoding URL: https://openaipublic.blob.core.windows.net/encodings/o200k_base.tiktoken
- Encoding SHA256: `446a9538cb6c348e3516120d7c08b09f57c36495e2acfffe59a5bf8b0cfb1a2d`
- Pattern SHA256 (UTF-8, no trailing newline): `2d1b8dc11e89af71459b36004f698ab3693f59fd84f63e8ec2b49564ab857420`

The encoding download was checked against the official pinned expected hash before
copying into source. Runtime loads only bundled resources, caps their sizes and
checks both hashes, sequential rank structure, unique tokens and byte coverage.
No network download, Python/Rust executable or new runtime dependency is required.

[Official App Server documentation](https://developers.openai.com/codex/app-server)
is background; the installed schema above determines implemented fields.

## Compile evidence

- Direct `swiftc -swift-version 6 -O` compiling LocalIO, Observation,
  VisibleEstimator and existing main: succeeded.
- Isolated SwiftPM release executable target with `.copy("Resources")`: succeeded;
  generated resource layout is
  `CodexHub_CodexHubHelper.bundle/Contents/Resources/Resources/`.
- Linker reports the existing CommandLineTools Developer lib/framework search
  directories missing; build still succeeds. No executable was run.
- License SHA256: `418cb499b436128d653d79941333a5437b7be2ea9213dcc2f04d15d5d2c51d86`.

Applied skills: minimal-code, ponytail, openai-docs,
reuse-defensive-decoupled-coding, orca-cli and orchestration. QA disabled and
explicitly skipped; no nested workers, source runtime/provider calls or reviews.
