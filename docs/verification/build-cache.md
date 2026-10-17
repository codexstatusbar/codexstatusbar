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

- Separate debug, release and verify caches use compiler/SDK/OS/architecture,
  Package.swift + Package.resolved, mode and commit in their keys.
- Compatible earlier commits can restore a prefix-matching cache; SwiftPM still
  executes its build/test commands and determines what needs rebuilding.
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
cache miss as intended. This is not yet a measured hosted-runner improvement.

## Artifact cleanup

Cleanup runs only after bundle publication succeeds and the uploaded DMG and
checksum exist. It deletes only artifact IDs belonging to that workflow run;
no cache or release-asset API is used for deletion. Failure artifacts remain
available for 14 days. Native Actions logs/history remain.

Previously published runs were checked for successful release-publishing steps.
41 artifacts (61,749,322 bytes) across 10 successful published runs were deleted;
zero caches were deleted. Release assets were retained.
