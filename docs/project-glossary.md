# Core vocabulary

Canonical meanings follow PRD sections 6–10 and the approved S1 plan.

- **Run**: Hub execution lifetime, identified independently from a Codex thread; never inferred from cwd or PID alone.
- **Thread key**: Codex home identity + optional Hub run identity + Codex thread identity. Unknown run remains nil, not a fabricated PID mapping.
- **Process identity**: PID + OS start time. Reused PID is a different process.
- **Authority**: the single verified usage source for a thread counter epoch. Hook is state-only. Secondary sources never add usage.
- **Epoch**: an explicitly reconciled counter interval. Counter regression suspends measurement until an adapter explicitly establishes a new epoch or reconciled authority.
- **Baseline**: first known cumulative snapshot, excluded from current throughput. Zero is allowed only for a verified empty thread.
- **Reported output**: outputTokens, including reasoningOutputTokens as a subset; never total + last.
- **Non-reasoning output**: output minus reasoning when that breakdown is valid; not an exact visible-answer count.
- **Reported throughput**: newly reported output in the shared monotonic (frame − window, frame] interval divided by window seconds. Not decode speed.
- **Turn average**: verified new output over observed full turn duration, including tool and approval time. Missing start or baseline means unavailable.
- **Coverage**: measured active runs / discovered active or activity-unknown runs. Confirmed idle runs are excluded. Parent/child overlap must be resolved by the adapter before marking scope verified.
- **History**: finished turn metadata and reported output. Late usage can correct history without changing current activity or speed.
- **Monotonic time**: caller-injected nonnegative finite seconds from one monotonic clock; never wall-clock timestamps. Adapters serialize calls.
