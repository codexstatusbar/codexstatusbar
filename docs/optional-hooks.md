# Optional Swift hook status source

Implementation compiled only. All QA, tests, review, actual install/uninstall,
recorder execution, trust changes and runtime compatibility checks were NOT RUN
at the user's request. This document supersedes the old “hooks unavailable”
statement in managed-helper.md for this optional CLI only.

## Explicit installation and consent

Examples below are documentation, not commands run during implementation:

```sh
codex-hub hooks status --home /absolute/CODEX_HOME
codex-hub hooks install --home /absolute/CODEX_HOME --consent
codex-hub hooks uninstall --home /absolute/CODEX_HOME --consent
```

The home must already exist, be normalized/absolute, owned by the current user,
and not be writable by others. Symlink components are refused. No default-home
selection, automatic installation, shell aliases, enabling features, or trust
writes occur. Open Codex `/hooks` and review/trust each exact hook hash manually.
Changing the hook definition may require renewed trust. Status cannot determine
whether Codex trusts or enables these hooks.

Status stdout is one JSON object:

```json
{"schema_version":1,"state":"installed","trust":"manual_review_required","runtime_verified":false,"codex_home_id":"<sha256>","installation_id":"<UUID>"}
```

`state` is `not_installed`, `installed`, or `conflict`; `installation_id` is absent
when no manifest exists. Invalid/unsafe configuration returns nonzero with a
sanitized error on stderr. Install/uninstall return human-readable success and
the manual trust reminder; callers must use exit status and refresh status.
Do not present `installed` as runtime or trust confirmation.

The installer semantically merges user `CODEX_HOME/hooks.json`, preserving all
unrelated keys, groups and handlers; JSON formatting/order can change. Inline
TOML and every other configuration source remain byte-for-byte untouched.
Duplicate JSON keys, invalid structure, symlinks, hardlinks, unsafe permissions,
foreign ownership, an existing manifest, or orphaned recorder commands fail
closed. Unknown unrelated JSON values remain present. Each handler is exactly
`{type:command, command:<quoted absolute recorder command>, timeout:1}` inside
its own `hooks` group. Registered events are SessionStart, UserPromptSubmit,
Stop, SessionEnd, Interrupt, PreToolUse and PostToolUse, as documented by the
current official release docs. Installed-version execution remains unverified;
unsupported clients must not be presented as compatible.

The unique command embeds an installation UUID and copied recorder location.
Uninstall removes only exact owned groups; modifications to owned groups cause
failure. It does not remove other handlers, backups or arbitrary binaries.
Backups can contain the original user's command configuration, so they remain
private, are never printed, and are retained for user-directed recovery.

## Storage and failure handling

`~/Library/Application Support/CodexHub/hooks/<homeHash>/manifest.json`

`~/Library/Application Support/CodexHub/hooks/<homeHash>/<installationID>/recorder`

`~/Library/Application Support/CodexHub/hooks/<homeHash>/<installationID>/events.jsonl`

`homeHash` is lowercase SHA256 of the normalized absolute home UTF-8 path.
Because symlinks and lexical aliases are rejected, this matches the managed
source's canonical-home hash for accepted paths. Manifest version 1 stores home,
installationID, exact command and registered events. App-owned directories are
0700; manifest, backups and events are 0600; copied recorder is 0700. Moving the
app does not alter this copied command target. Source executable must also pass
regular-file/owner/no-symlink checks; no downloaded or arbitrary binary is used.

A private exclusive `hooks-backup-<UUID>.json` is fsynced before a same-directory
staged atomic merge. A directory advisory lock serializes Hub operations; file
contents are rechecked and atomic swap validates the displaced version. An
absent file uses exclusive rename. Conflicting replacement attempts are rolled
back where possible; recovery staging/backup is retained when restoration is
uncertain. Editors that ignore advisory locks must not edit hooks.json during
installation. A failed install may retain manifest, recorder and backup for
recovery; inspect status and explicitly uninstall before retrying. A missing
original file has no backup. No automatic destructive recovery runs.

## Consumer contract: state only

Each line of events.jsonl is a bounded JSON object:

```json
{"hub_schema_version":1,"hub_source":"hook","codex_home_id":"<sha256>","installation_id":"<UUID>","session_id":"session-1","turn_id":"turn-1","hook_event_name":"Stop","timestamp":"2026-10-17T09:00:00Z","received_monotonic_ns":"1000000000"}
```

`turn_id` is required except SessionStart/SessionEnd. `tool_use_id` is required
and emitted only for PreToolUse/PostToolUse. Identifiers are 1–128 ASCII letters,
digits, hyphens or underscores; malformed IDs cause the entire event to drop.
Timestamp is local receive time (official common fields contain no timestamp),
not a claimed provider timestamp. No thread_id, PID, cwd, transcript path,
model, prompt, tool name/arguments, response text, permission content or tokens
are persisted. Session/turn/event are the only ordinary input fields retained;
the two tool events additionally retain their exact tool-call ID.

Official common fields are session_id, transcript_path, cwd, hook_event_name,
and model. Turn-scoped events add turn_id; tool events add tool_use_id.
The official docs explicitly say subagent hooks can use the parent session_id.
Therefore the collector MUST establish identity from trusted rollout metadata
(and exclude ambiguous parent/subagent attribution) before attaching events to
an actual thread. The recorder intentionally emits no fabricated thread_id and
never opens transcript_path. Similar cwd or aliases are not proof. Unresolved
identity stays unattached/unknown. Stop is a completion candidate, never final
Idle. SessionEnd/Interrupt are separate lifecycle signals. PermissionRequest is
not registered: its documented shape has no stable resolve ID, so no approval
correlation is invented. Tool start/end use exact turn/tool IDs only.

Recorder stdin is limited to 256 KiB and 150 ms; parsing is in memory only.
It always returns neutral `{}` and success, including missing/invalid input or
storage failure; it never emits decisions or context. Events use a nonblocking
lock and a 4 MiB per-installation cap with no destructive rotation. At the cap,
lock contention or any failure, new records are dropped. A stale source is
unknown/disconnected, never Idle. No durable gap can be guaranteed on disk
failure. The collector must handle age, incomplete lines and bounded retention;
this stream is never token authority and cannot add to rollout usage.

## Compile only

```sh
swiftc -swift-version 6 -O -o /tmp/codex-hub-optional-hooks Sources/CodexHubHelper/LocalIO.swift Sources/CodexHubHelper/Observation.swift Sources/CodexHubHelper/VisibleEstimator.swift Sources/CodexHubHelper/Hooks.swift Sources/CodexHubHelper/main.swift
```

The shared relay dispatch also enqueues client observation before forwarding
using the bounded nonblocking `submitClient` API; server observation remains
after forwarding. Queue overflow invalidates measurement only; relay bytes and
approval messages are not changed. This wiring requires the Live observer
implementation from its owning worker before compiling the combined helper.
Combined Swift 6 optimized compilation passed using Observation.swift and
VisibleEstimator.swift from the swift-visible-estimator worktree and this
worktree’s LocalIO.swift, Hooks.swift and main.swift; the binary was not run.

No production dependencies added. Applied workflows: minimal-code, ponytail,
OpenAI Docs, reuse-defensive-decoupled-coding, orca-cli and orchestration.

Source: [official Hooks documentation](https://learn.chatgpt.com/docs/hooks),
fetched 2026-10-17. Runtime verification is deferred to the user's later QA.
