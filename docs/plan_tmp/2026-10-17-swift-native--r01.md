# S1 optional 카운터 회귀 보완

- document_role: child
- root_doc: docs/plan_tmp/2026-10-17-swift-native.md
- parent_doc: docs/plan_tmp/2026-10-17-swift-native.md
- 상태: implemented (68673be, 통합 8d524d3)
- 최신 사용자 지시로 이후 QA/테스트/독립 재검증은 스킵한다. 알려진 결함 코드 수정과 build만 마무리하고 미검증을 명시한다. 아래 기존 테스트 절차는 나중에 사용자가 실행할 참고이며 지금 실행하지 않는다.
- triggering_failure: 09b185f 독립 검토 FAIL, Usage.swift optional 누적 필드 known→nil→lower 감소 미탐지(P2).
- 근거: /tmp/codexhub-s1-independent-review/report.md
- ancestor_reverification_gate: S1 전체 Swift Testing, build, optional 회귀 재현, 이후 전체 제품 V1.

## 범위 및 소유

- 전용 core-counter-remediation worktree에서 Sources/CodexHubCore/Usage.swift, Sources/CodexHubCore/ThreadMonitor.swift, Tests/CodexHubCoreTests/CoreTests.swift, docs/verification/core.md만 수정한다.
- PRD 6.4, root plan, glossary, core verification, 독립 report를 읽는다.
- UI/collector/manifest/lockfile/root plan/사용자 데이터 수정 금지. 다른 worker는 UI와 collector의 독립 파일만 작업한다.
- 마지막으로 알려진 optional 누적 검증값을 같은 epoch에서 보존한다. 공개 최신 snapshot의 nil은 유지한다. reconcile은 검증 기준을 새 baseline으로 재설정한다.
- source/epoch 거부 및 regression/suspended 상태에서 검증 기준을 변경하지 않는다. 최소 변경으로 고친다.
- 실제 S2 호출자가 DB에서 복원해야 하므로 partial flag와 마지막 알려진 optional 검증값을 읽고 복원할 최소 API도 포함한다. restart로 high-water 검증값을 잃거나 partial이 정상화되면 안 된다. 최신 snapshot nil은 보존하고, 복원은 임의 턴/속도 생성 없이 검증된 숫자만 수락한다. 일반 reconcile(새 epoch 기준 재설정)과 persistence restore 의미를 구분한다. 새 serialization framework는 만들지 않는다.

## 실행과 검증

1. worktree/branch 확인. 실패하는 테스트를 먼저 추가한다.
2. reasoning과 total 각각 known→nil→lower 회귀 및 후속 suspended를 확인한다.
3. known→nil→equal/higher는 정상. reconcile 후 낮은 새 epoch 기준은 허용. nil 표시는 유지.
4. ThreadMonitor partial 및 nil rate 전파를 확인한다.
5. 다른 nonoptional 카운터(input/cached/cacheWrite)의 감소 true 분기도 기존 validation 계약대로 회귀 검사한다.
6. `swift test --build-system native --disable-xctest -Xcxx -isystem -Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"`, `swift build`, `git diff --check` 통과.
7. 작은 commit 후 SHA/파일/테스트/잔여 위험 보고. 독립 재검증 전 스스로 ancestor를 완료하지 않는다.

## 현재 상태

- 구현: 완료. UsageCounter에 optional lastKnown 보존 및 검증된 복원 initializer, ThreadMonitor(key:counter:) 제공.
- 독립 검증: 사용자 QA skip 지시로 후속 실행 안 함.
- 실패 원문은 root 기록과 독립 보고서에 보존한다.
- 완료 후 root가 수정본을 통합하고 원래 S1 gate를 재실행해야 한다. 전체 root 닫히기 전 이 문서를 삭제하지 않는다.
