# Build cache and artifact lifecycle

## Baseline

GitHub run 39044234485 (0.0.10), before caching:

| Step | Duration |
| --- | --- |
| Core/Collector tests, including compilation | 42 s |
| UI/process fixture compilation and execution | 50 s |
| Release build and DMG packaging | 68 s |

These step times exclude runner queue time and artifact transfer.

## Cache contract

- Separate debug, release and verify caches use compiler/SDK/OS/architecture/workspace,
  Package.swift + Package.resolved, mode and commit in their keys.
- Compatible earlier commits can restore a prefix-matching cache; SwiftPM still
  compiles after prefix-only hits. Exact source-commit/toolchain/workspace hits
  reuse compiled products; tests, packaging, signatures and resources are still
  verified. Missing cached products fail rather than silently publishing a partial app.
- GitHub cannot share caches between sibling tags. A separate main-push cache
  warmer creates default-branch caches that version-tag runs can restore.
  Release publishing remains tag-only.
- UI fixture caching is opt-in with `TOKLOOM_CACHE_FIXTURES=1`. Source files,
  module map, build script, compiler, SDK and workspace path form its fingerprint.
  Only successful compilation writes the key. Every run executes all assertions,
  process fixtures and renders; results themselves are never reused.
- Cache paths exclude final app/DMG bundles, UI screenshots, authentication data,
  application metadata and user logs. Only compiler outputs/dependencies persist.

Source: [GitHub cache access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).

## Local measurements

Same machine and command, `/usr/bin/time -p env TOKLOOM_CACHE_FIXTURES=1
./scripts/capture-fixtures.sh <output>`:

| Run | Duration | Result |
| --- | --- | --- |
| Cold compilation | 26.82 s | UI01–UI94/P01–P06 passed |
| Warm compilation cache | 14.96 s | Same 100 checks passed |
| Warm repeat | 14.93 s | Same 100 checks passed |

The warm median was about 44% faster locally. A script-content change caused a
cache miss as intended. These local figures are separate from hosted-runner results below.

## Artifact cleanup

Cleanup runs only after bundle publication succeeds and the uploaded DMG and
checksum exist. It deletes only artifact IDs belonging to that workflow run;
no cache or release-asset API is used for deletion. Failure artifacts remain
available for 14 days. Native Actions logs/history remain.

Previously published runs were checked for successful release-publishing steps.
41 artifacts (61,749,322 bytes) across 10 successful published runs were deleted;
zero caches were deleted. Release assets were retained.

## Hosted cache verification

Run 39045878034 (0.0.11) restored all three caches from main. Step times were
20 s tests, 26 s UI verification and 49 s build/package, compared with 42/50/68 s
in the baseline. These exclude cache transfer and queue time. Native SwiftPM
still recompiled unchanged targets, so a follow-up uses exact-hit compiled
products, while prefix-only restores continue to compile. The same checks run
on either path. Cleanup succeeded: four uploaded artifacts were removed, release
assets remained, and three caches totaling 537,259,178 bytes remained accessible.

## Exact-hit follow-up

Run 39046386405 (0.0.12) confirmed exact-commit compilation reuse:

| Step | Original | Dependency/build cache | Exact-hit reuse |
| --- | --- | --- | --- |
| Core/Collector tests | 42 s | 20 s | 11 s |
| UI/process verification | 50 s | 26 s | 16 s |
| Release build/package | 68 s | 49 s | 26 s |

The logs confirmed all 74 Core/Collector tests and all 100 UI/process checks ran,
and release products were reused only after an exact cache hit. These are
observed step times, not a guarantee across runner load or cache misses, and
exclude cache transfer/queue time. Main-branch cache warming has its own cost.
Release publication and artifact cleanup both succeeded; run artifacts were
zero afterward, while six cache entries and both release assets remained.
