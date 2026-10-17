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
- **Reported throughput (legacy API)**: the retained low-level 10-second reported-window calculation. It is no longer the UI default; the UI uses Work average throughput.
- **Turn average**: verified new output over observed full turn duration, including tool and approval time. Missing start or baseline means unavailable.
- **Coverage**: measured active runs / discovered active or activity-unknown runs. Confirmed idle runs are excluded. Parent/child overlap must be resolved by the adapter before marking scope verified.
- **History**: finished turn metadata and reported output. Late usage can correct history without changing current activity or speed.
- **Monotonic time**: caller-injected nonnegative finite seconds from one monotonic clock; never wall-clock timestamps. Adapters serialize calls.

- **Idle**: an observed session has completed its current turn and is waiting for work. The Hub summary shows Idle when at least one connected session is observed idle and no connected session has an active turn; historical Unknown rows do not hide observed idle. Process existence or missing traffic alone does not prove a session is idle.
- **Unknown**: current session activity has not been observed reliably. The summary uses Unknown only when there is no observed connected active or idle session. It does not mean Hook installation or log collection failed.

- **Running process list**: current same-user Codex executables verified by PID and OS start time. A session attaches only through an exact writable file device/inode or validated managed controller identity. Stored transcripts alone are history. Unmatched live processes remain explicit and contribute no fabricated session or usage.

- **Process context**: the latest reported last_token_usage.total_tokens and model_context_window for the matched session, shown as used tokens / window. It is separate from cumulative lifetime input/output.
- **Remaining usage**: 100 minus the reported used_percent for each available rate-limit window, with its actual window_minutes and reset time. No default 5-hour/weekly label or account lookup is inferred.
- **Process input/output**: the selected authority's last reported cumulative input/output counter snapshot. Inherited/fork history can be included; these are not current-turn generation counters.

- **Activity reattachment**: the app proves the current process owns the exact source file identity before the collector restores its recorded latest turn state. A fresh validated Hook can recover a matching turn whose start is unavailable. Reattachment clears the rate window and preserves an incomplete turn average; historical token deltas never become current throughput.

- **Requested speed tier**: the session's recorded service_tier selection (Fast includes fast/priority, Ultrafast is ultrafast). It is not proof of the provider's actual served tier.
- **Home default tier**: the read-only root service_tier in the selected Codex home's config.toml. Profile/CLI/project overrides may differ; this value never substitutes for missing per-session evidence.

- **Work average throughput**: reported output token growth divided by monotonic elapsed time from the observed work start to the current frame, including generation, tools and approval waits. This replaces the UI's 10-second reported window by the user's 2026-10-17 decision. Active process averages are summed at the same frame; Idle clears the current rate and retains the completed average in Summary.
- **Observed-period average**: when start/baseline was missed or a gap invalidated continuity, the next valid report establishes a new numerator baseline and start time. Only subsequent fresh increments are averaged. It is explicitly partial and never described as the whole work average.
