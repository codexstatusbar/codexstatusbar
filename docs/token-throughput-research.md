# Token throughput measurement research

Date: 2026-10-17. Scope: official documentation, current Tokloom code and offline
Codex 0.163.0 schemas. No new provider request or inference benchmark was run.

## Findings

| Measurement | Definition and applicability |
| --- | --- |
| Server generation rate | Ollama supplies `eval_count` and `eval_duration` in nanoseconds, separately from prompt evaluation/loading. Rate is `eval_count / eval_duration * 1e9`. Streaming usage arrives in the final done chunk. This needs server-provided timing; copying the formula cannot recover missing timing. [Ollama usage](https://docs.ollama.com/api/usage) |
| Request TPOT | vLLM defines TPOT as `(E2E - TTFT) / (output_tokens - 1)`. Its inverse describes the post-first-token average. Streaming event intervals differ when one event contains multiple tokens; event count is not token count. [vLLM metrics](https://docs.vllm.ai/en/stable/design/metrics/) |
| Per-request server diagnostics | vLLM's `generation_time_ms` excludes queue/prefill, but its `tokens_per_second` includes prefill. Multi-generation Responses workflows omit metrics when timing cannot be attributed to cumulative usage. Metric names alone are insufficient. [vLLM per-request metrics](https://docs.vllm.ai/en/latest/features/per_request_metrics/) |
| Client-observed output | Codex app-server exposes agent-message deltas, item lifecycle events and thread token-usage updates. These can support a client observation interval, not a guarantee of server decode time. [Codex app-server](https://learn.chatgpt.com/docs/app-server) |
| Token-count scope | OpenAI usage includes generated non-visible tokens, including formatting/channel/tool structure, even when reasoning count is zero. Subtracting reasoning is not an exact count of visible text. [OpenAI token counting](https://developers.openai.com/api/docs/guides/token-counting) |

[Responses streaming events](https://developers.openai.com/api/reference/resources/responses/streaming-events)
identify output items/content and carry text deltas and completion usage. Chunk
boundaries must not be assumed to match tokenizer boundaries.

## Current local evidence

- `RequestTiming` subtracts the union of tool intervals from log report timestamps.
  This is already better than dividing output by the entire user-turn duration,
  but remaining queue/prefill/network latency is not separable from these logs.
- The current default numerator is reported output, including reasoning; it must
  not be paired with a visible-text-only duration and relabeled pure generation.
- Previous real timing evidence in [server-timing.md](verification/server-timing.md)
  contained output/event counts and event spacing, but no proven engine decode
  duration. That explains why the server-diagnostic UI could not display speed.
- Offline schema export from installed `codex-cli 0.163.0` confirms
  `AgentMessageDeltaNotification` has delta/itemId/threadId/turnId, and
  `ThreadTokenUsageUpdatedNotification` has threadId/turnId/tokenUsage. Their
  schemas do not provide per-token generation timestamps. Turn duration is a
  whole-turn duration; command/MCP/dynamic-tool durations are not model duration.
- Reproduction command: `codex app-server generate-json-schema --experimental --out .build/research-app-server-schema`.
  This was an offline schema export, not a provider call.
- Live tokenization currently supports only the explicit model list in
  `Sources/CodexHubHelper/VisibleEstimator.swift`; current GPT-6 model names are
  not automatically supported. Tokenizer mapping must be verified before expansion.

## Recommended implementation direction (proposal, not implemented)

1. Keep passive log mode as a clearly named estimate. Faster polling improves
   display latency but does not reveal missing server timings.
2. For managed observation, measure each attributable model response/output stream
   independently. Use monotonic receive timestamps for first/last text deltas;
   exclude command output and separate model calls around tool execution.
3. Count the same visible text whose timestamps were observed, using a verified
   tokenizer. Re-tokenize accumulated text or use a correct boundary-aware
   tokenizer; summing independently tokenized chunks can miscount BPE merges.
4. Define client throughput precisely. If the first received chunk contains `k`
   tokens and the stream contains `N`, a post-first-chunk estimate is
   `(N - k) / (last_chunk_time - first_chunk_time)`, subject to tokenizer boundary
   reconciliation. Do not use `N - 1` unless events actually represent individual
   tokens. Single/buffered chunks or zero-duration intervals remain unavailable.
5. Call it observed visible-output speed. Transport buffering, network delay and
   server pauses within the stream still affect it. Do not discard long gaps
   arbitrarily: that biases the result upward.
6. Keep reasoning and visible-output metrics separate; missing reasoning timing
   cannot be recovered from visible events. A Codex user turn can contain multiple
   model calls, so a turnId alone is not a request-level timing guarantee.
7. For serial response summaries, combine compatible counts/durations as
   `sum(tokens) / sum(duration)`, not the unweighted average of rates. Concurrent
   aggregate throughput needs a shared wall-clock window and non-overlapping
   scopes; summing completed-response averages is a different metric.
8. Only introduce server decode speed if a documented per-response token count
   and matching decode duration become available and pass real contract checks.

Validation should cover split/merged chunks, delayed packets, reasoning-only
output, tool interleaving, retries, resumed sessions, one-chunk replies, clock
changes, and parent/child attribution. Compare against a local server exposing
known metrics before claiming quantified accuracy; no percentage improvement has
been established by this research.

## Same-name rows observed during research

Read-only process/log-header inspection found one CLI root and one explicit
`source.subagent.thread_spawn` child owned by the same live PID. They are distinct
threads, not duplicate reads of one file. The child was the research sidecar.
The user confirmed one overview row per parent group, with separate child state,
rate and charts in Details. This does not authorize blindly summing inherited
parent/child counters or treating cwd/PID equality as a parent relationship.
