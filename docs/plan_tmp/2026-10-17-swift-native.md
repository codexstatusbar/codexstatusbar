# Codex Hub Swift 네이티브 구현

- document_role: root
- 상태: implemented (코드 통합 및 arm64 앱 빌드 완료; 최종 QA는 사용자 직접 수행)
- 최신 사용자 지시: "아니 일단 스킵하고 구현 부터". 이후 QA/테스트/리뷰/캡처를 새로 실행하지 않는다. 실행파일 산출에 필요한 compile/build만 수행한다. 아래 이전 QA/독립 재검증 완료 gate는 이번 구현 인계 조건에서 제외하며, 전체 QA는 사용자가 구현 후 실행한다.
- Run: run_77d5c4b94a70
- PRD: docs/Codex_Hub_PRD.md
- 통합 경로: /Volumes/exusb/project/codexstatusbar/dev-feature-codex-hub-native-integration
- 통합 브랜치: garhidiba/dev-feature-codex-hub-native-integration
- 기준 커밋: 7644907 (사용자가 제공한 PRD)
- 사용자 확정: Swift, macOS 네이티브, Apple Silicon. Rust helper 제안보다 우선.
- 기본값: macOS 14+, SwiftUI + AppKit, 시스템 폰트, 카드 없는 목록, SwiftPM. 배포 서명/공증은 별도 릴리스 작업.
- 도구 확인: arm64, Swift 6.4, CommandLineTools, codex-cli 0.163.0.
- 독립 구현 작업은 전용 Orca worktree에서 수행. main 승격/원격 push 없음.
- qa-verification은 설치 메타데이터상 disabled: 활성화하거나 우회하지 않는다. 실행 가능한 Swift 테스트와 PRD 수용 기준의 실제 결과를 기록하며 미검증을 PASS로 바꾸지 않는다.

## 계약과 의미

PRD 6~10의 용어가 기준이다. Run은 Hub 실행 수명, Thread는 Codex 스레드이며 서로 다른 식별자다. PID는 시작 시각과 묶는다. outputTokens에 reasoningOutputTokens를 더하지 않는다. R은 최근 10초에 새로 보고된 출력량이며 서버 decode 속도가 아니다. Live 추정은 검증된 tokenizer가 있을 때만 제공한다. 원문과 인증정보는 저장하지 않는다.

## 슬라이스

| ID | 범위/소유 | 의존 | 상태 | 검증 및 커밋 조건 |
|---|---|---|---|---|
| P0 | 설치 CLI schema/transport 조사, 임시 디렉터리만 사용, 읽기 전용 조사자 | 없음 | complete | 격리 stdio/Unix initialize, TCP bearer 401/101 확인. 실제 TUI/provider G0 미통과 |
| S1 | SwiftPM core 모델, 사용량 카운터, 상태 및 처리량 | 없음 | implemented | r01 68673be를 8d524d3에 통합. 추가 QA는 사용자 지시로 생략 |
| S2 | 읽기 전용 JSONL 수집, 체크포인트/저장/복구 | S1, P0 | implemented | bb165e2를 25c07a8에 통합. compile 완료, 최종 QA 생략 |
| S2b | 관리형 helper 메타데이터 읽기 및 source authority 통합 | S2,S4 계약 | implemented | c48b2f1→5dbbda3, compile only |
| S3 | SwiftUI 메뉴바·상세·설정, app bundle build | S1; 최종 wiring은 S2 | implemented | bb31625/8cfba6b→c665bd5, arm64 bundle 생성 |
| S4 | Swift 런처/relay/진단 | P0,S1 | implemented | 99c8b96→1f6af00, G0는 사용자 QA로 이관 |
| S5a | Swift BPE/모델 매핑/보이는 출력 count producer | S4 | implemented | 8b6258d→fe824c5, compile only |
| S5b | 선택적 Hook 설치·제거·상태 recorder | S4 | implemented | 5abe351→35318bd, 실제 설치 실행 안 함 |
| S5c | 5초 Live window 및 Hook 상태 보완 수집 | S2b, S5a/b 계약 | implemented | 54f0151→1faeedf, compile only |
| S6 | Live/Reported 모드·Hook 동의 UI 및 최종 번들 | S5a/b/c | implemented | 3711989→b1f0512, arm64 앱/helper/resource bundle 및 ad-hoc 서명 |
| S7 | 확인된 CLI 루트 소계 | S6 | implemented | 7b0f8fb→1bc84e3, 숫자 소계와 자식 범위 Partial 분리, 최종 앱 재빌드 |
| V1 | 전체 QA | S2,S3,S4 | deferred_by_user | 사용자 직접 실행 예정. 이번 작업에서 시작하지 않음 |

## S1 실행 지침

- Scope: Package.swift, Sources/CodexHubCore/**, Tests/CodexHubCoreTests/**, .gitignore, docs/project-glossary.md, docs/verification/core.md.
- Non-goals: UI, relay, 실제 로그 접근, DB, provider 요청, tokenizer 또는 임의 추정.
- Swift 표준 라이브러리/Foundation만 사용한다. 현재 앱 없는 상태에서 재사용할 코드 없음.
- 상태는 Connectivity/Activity/Measurement 3축. PRD의 동시 tool/approval ID 집합, turn 종료, 과거 이력/현재 속도 경계를 보존.
- 사용량은 비음수 정수 검증, first snapshot baseline, 동일 snapshot 추가 0, counter regression 명시적 partial, total+last 중복 금지.
- 속도는 injected monotonic 시간, 동일 프레임/윈도우로 계산, 종료 즉시 제거, 시작 놓친 턴 평균은 nil.
- source authority, epoch 및 thread/run 분리는 실제 필요한 최소 계약으로만 구현.
- XCTest/Swift Testing 중 설치 도구가 지원하는 기본 도구 사용. 각 행동 ID를 테스트 이름과 문서에 연결.
- 검증: swift test 및 swift build. 실행은 전용 임시 데이터로만 수행. 코드만으로 provider 성공 주장 금지.
- 완료 보고: commit, 파일, 테스트 결과, 알려진 제약, 후속 앱에서 쓸 public API, 검토 초점.
- coordinator가 plan을 갱신하므로 worker는 이 파일을 직접 변경하지 않는다.

## P0 조사 지침

- PRD 전체, 특히 4~6, 15~17을 읽는다. openai-docs와 관련 진단/조사 스킬을 적용한다.
- 설치 CLI help/schema를 근거로 확인. 모든 산출물은 mktemp 디렉터리에 둔다.
- 실제 사용자 세션/설정/인증 파일 변경 금지. active thread resume/turn start 금지. 외부 provider 호출 금지.
- 격리 CODEX_HOME으로 initialize-only 시험은 가능. 종료 시 자신이 시작한 프로세스만 정리.
- 로그 포맷 관찰이 필요하면 원문 출력 없이 key/type 허용 목록만 조사한다.
- 결과: Swift relay가 사용할 transport framing/auth, 최소 인수 라우팅, rollout 타입/사용량 필드, G0 실제 통과/미검증 구분, 권장 다음 단계.
- 파일 수정과 commit 없음. 보고는 Orca mailbox로 coordinator에게 전달.

## S2 실행 지침 (S1 통합 후 ready)

- Scope: Sources/CodexHubCollector/**, Tests/CodexHubCollectorTests/**, SQLite system-library shim, 필요한 Package.swift target 추가, docs/verification/collector.md.
- 입력: 사용자가 선택한 Codex home, 별도 Hub metadata directory, injected clock. 출력: UI가 사용할 세션 스냅샷과 코어 ThreadMonitor. 실제 prompt/body/text/diff/auth 필드는 디코딩 후 유지하지 않는다.
- 사용자 로그는 read-only. 파일 유형/소유권/정체성과 선택 root 경계를 확인한다. 원본 삭제/수정 금지. 큰 파일/줄에 상한을 두고 한 파일 실패는 다른 세션을 막지 않는다.
- 최초 색인은 historical=true: 현재 속도를 만들지 않는다. 기존 활성 턴은 현재 실행 중임을 추정하지 않고 Unknown으로 둔다. 새 lifecycle 이벤트로만 Working/Idle 전환.
- JSONL은 완전한 newline 단위만 checkpoint. 파일 ID+offset 저장, 미완성 UTF-8와 last line은 다음 append 때 처리. truncate/rotation은 gap/새 epoch/baseline으로 처리하며 과거량을 신규량으로 만들지 않는다.
- Swift actor 또는 직렬 실행으로 코어 변경과 DB transaction을 묶는다. SQLite는 시스템 라이브러리 재사용. 저장 root 0700 및 files 0600, symlink/다른 owner 거부. 실제 사용자 환경이 아닌 임시 디렉터리에서 테스트.
- metadata는 재시작 복구에 필요한 허용된 값만 저장. checkpoint와 집계 상태를 같은 transaction에 넣는다. 읽기 오류/DB 오류를 UI 진단에 노출한다. 보존 일수(기본 7일), row 상한, Hub metadata 삭제 API 제공. 원본 로그 삭제 API는 만들지 않는다.
- shell/PID 추측 없이 Session only. 확인된 source/parent 관계만 기록하고 부모/자식 포함 범위가 불명인 경우 합산을 Partial로 제한한다.
- 공개 API는 UI 작성자가 바로 사용할 실제 start/refresh/snapshot/clear/update retention 경로로 최소화한다. sleep/wake gap 재설정 경로를 노출한다.
- 테스트: split UTF-8/partial line, duplicate, malformed line, old initial large counter, null token info, no turn ID, lifecycle, late usage, rotation/truncate, restart, DB failure, privacy sentinel, symlink/ownership, clear와 retention, 독립 세션.
- focused verification: S1에서 확인한 swift test 명령으로 전체 현재 테스트 실행; build 성공. 각 테스트 ID/명령/요구를 문서에 연결. commit 후 API/검증/제약 보고.
- Non-goals: relay/provider 요청/Hook 설치/UI/로그로 PID 확정/토크나이저.

## 검증 및 실패 처리

- 구현자는 각 슬라이스 focused tests와 diff를 검토하고 commit한다.
- verifier는 코드를 쓰지 않는다. 실패는 근거/명령/영향 파일/수정 요구와 함께 반환한다.
- 실패 확정 시 root를 replan_required로 바꾸고 --rNN child를 만든 뒤 수정 작업을 배정한다.
- 최종 gate: 빌드/테스트, 데이터 비저장/권한 경계, UI 실제 실행, FR 적용/미적용/막힘 기록, worker 정리.
- 8시간 지속 시험, 실제 계정 G0, 서명/공증 결과 없이 제품 전체 완료/릴리스 준비를 주장하지 않는다.
- 기본 재할당 기준: 30분 무갱신 후 최근 로그/파일 상태 확인. timeout만으로 worker 종료 판정 금지.
- 모든 단계가 검증 완료되고 blocker가 없을 때만 이 임시 계획을 삭제한다.

## S3 실행/소유 경계

- task_a95b88f429b1, 전용 swift-native-menu-bar worktree. Sources/CodexHubApp, native packaging/scripts/tests, docs/verification/native-ui.md 소유.
- 실제 S1 코어 기반 UI를 먼저 구현하고 S2 실제 API가 전달된 뒤 앱 진입점에 연결한다. 임시 가짜 수집기/성공 응답 금지.
- S2 완료 전 Package.swift/lockfile 수정 금지. 초기 view 검증은 isolated temp manifest 또는 기존 코어 build products를 사용한다.
- Figma UI-01~09 high-fidelity context + screenshot을 직접 읽고 system font/control과 no-card 지침에 맞게 구현.
- 목록/상세/설정/연결 진단, 초기 없음/Idle/Working/부분 측정/오류 상태. 실제 읽지 않은 세션/측정값을 production UI에 seed하지 않는다.
- 기본 reported 10초. 검증되지 않은 Live tokenizer/직접 연결/Hook은 이유를 보이고 비활성으로 표시한다.
- 로그인 항목은 사용자가 토글할 때만 OS API 호출. QA는 실제 사용자 login item/Hook을 변경하지 않는다.
- 수집기 갱신은 UI main thread를 막지 않으며 최대 2Hz. wake는 measurement gap을 기록하고 윈도우를 초기화한다.
- UI는 metadata 숫자/식별자만 받는다. 경로/ID 복사, retention/clear 실제 API 연결, 빈 상태에서 home 선택 경로를 제공한다.
- arm64 .app 빌드와 실제 fixture render 캡처, 키보드/접근성/긴 경로/라이트·다크 검증을 기록한다. 앱 파일은 독립 실행 가능해야 한다.
- 최종 실제 수집기 연결, build, 현재 테스트 전체 통과 후 commit. 서명/공증/외부 provider/G0 미검증을 숨기지 않는다.

## 실행 기록

- 2026-10-17: PRD 최초 커밋 7644907. 통합 worktree 생성. P0/S1 배정 준비.
- S1: task_dfdd66f086d9 / ctx_05e2ce6cd289, /Volumes/exusb/project/codexstatusbar/swift-core-implementation. CLT에 XCTest/Testing 모듈이 없어 공식 swift-testing test-only 의존성 고정을 요청함.
- S1 최종: Swift Testing 6.2.4 / swift-syntax 602.0.0 고정. `swift test --build-system native --disable-xctest -Xcxx -isystem -Xcxx "$(xcrun --show-sdk-path)/usr/include/c++/v1"` 통합 worktree에서 14 tests PASS. test-only 의존성, production은 외부 의존성 없음.
- S1 독립 검토 task_e82dab5e9e3e / ctx_deb5149d8ae0: 기존 테스트/build는 PASS지만 optional reasoning/total known→nil→lower 회귀 누락 P2 재현. /tmp/codexhub-s1-independent-review/report.md. child docs/plan_tmp/2026-10-17-swift-native--r01.md를 열었으며 S1 완료 판정을 취소한다. verifier는 release 완료.
- r01 수정 68673be는 통합 8d524d3에 반영, worker release 완료. partial/lastKnown counters 복원 API도 포함. 사용자 QA skip 이후 재검증하지 않음.
- S2 bb165e2 통합 25c07a8. S2b task_d6145ef05a84/ctx_22f3107b1671로 기존 collector worker 재사용.
- S3 task_a95b88f429b1/ctx_a121635a10f7, 실제 수집기 연결 후 .app release 빌드 중. S2 완료 후 manifest 소유권 이전.
- S4 task_14945fc97f50/ctx_b971ac124d58, swift-managed-helper 전용 worktree. Sources/CodexHubHelper와 docs/managed-helper.md만 소유. producer/consumer 계약은 marker/schema/homeHash/run/thread 명시, ~/.Library가 아닌 ~/Library/Application Support/CodexHub/managed-runs/<homeHash>/sessions/<run>/<file>.jsonl.
- S4 99c8b96 통합 1f6af00; S2b c48b2f1 통합 5dbbda3; native helper bundle 8cfba6b 통합 c665bd5. 모두 구현/컴파일 기준, QA 생략.
- S5a task_4f1af4c3e6f1/ctx_fe42adf94903: swift-visible-estimator. Observation.swift/VisibleEstimator.swift/Resources/docs/live-estimator.md 소유.
- S5b task_74995a45e7e2/ctx_e1fc4f987343: swift-optional-hooks. Hooks.swift/main.swift/docs/optional-hooks.md 소유. main은 client pump 전달 후 submitClient를 호출해 S5a와 연결.
- S5c task_4e13bca91d88/ctx_86a3a093a085: live-hook-collector-integration. 기존 LogCollector와 새 Core VisibleWindow만 소유. snapshot liveRate/liveMeasurement/liveUnavailableReason, init hooksDirectory 추가.
- S6 task_f3a486cac604/ctx_06e52160437d: 기존 swift-native-menu-bar worker 재사용, App/manifest/README/build packaging 소유.
- 확정 데이터 이름: visible_count/visible_unavailable. cumulative item count 감소 보정, 실제 시작 sample 0 및 complete_from_start=true. Hook stream은 hooks/<homeHash>/<installationUUID>/events.jsonl, usage authority가 아닌 상태 보완이며 exact observed session_meta ID만 연결.
- client 관측 enqueue는 raw writeAll 직전의 bounded nonblocking enqueue로 확정, server 관측은 전달 후. 일반 Live 재계산은 2Hz, item 완료시 마지막 누적 계산은 별도 1회 허용 후 즉시 원문 폐기.
- 지원 Live 매핑: 보고된 openai provider의 정확한 o1/o3/o4-mini/gpt-5/gpt-4.1/gpt-4o. 그 외 모델/공급자/미확인 재라우팅은 unavailable. tiktoken 공식 고정 자산/hash/라이선스는 docs/live-estimator.md에 기록.
- S5a/b/c 모두 통합·worker release 완료. 현재 남은 구현은 S6 화면 연결 및 최종 리소스 포함 앱 빌드뿐이다. QA/실행/Hook 설치는 사용자 지시 이후 수행하지 않음.
- S6 첫 시도 ctx_06e52160437d는 오래된 삭제된 skill_hook.py 경로 때문에 시작 전 실패. 전역 설정/비활성 스킬을 변경하지 않고 해당 worker를 stop한 뒤 ctx_8e6ec60fa5bf로 정상 재시작해 3711989를 완성했다.
- S7 task_cb99887bb5f4/ctx_b66d31b3af7a는 같은 worker를 재사용해 7b0f8fb를 완성했다. CLI session_meta의 정확한 root provenance만 소계에 포함하며 direct와 rollout은 단일 권위 유지. 자식 전체 사용량 범위는 Unknown/Partial.
- 최종 코드 기준 통합 commit: 1bc84e3. 최종 빌드 원본 commit: 7b0f8fb (동일 제품 코드). `scripts/build-app.sh`의 arm64 release 컴파일·번들 ad-hoc 서명 성공.
- 최종 산출물: /Volumes/exusb/project/codexstatusbar/dev-feature-codex-hub-native-integration/.build/Codex Hub.app (worker 빌드 산출물 복사 완료). 실행/빌드 안내는 README.md.
- 이후 QA/실제 앱 실행/Hook 설치·제거/provider 요청/8시간/VoiceOver/공증 검증은 실행하지 않았다. 이 계획은 사용자 후속 QA를 위한 구현 상태로 보존한다.
- 적용 워크플로: minimal-code, ponytail, multi-agent-git-orchestration, plan-execute-verify-orchestration, orca-cli, orchestration, OpenAI Docs, shared-glossary, systematic-ui-ux-design, logic-driven-ui-design, figma-design-to-code/figma-swiftui. 초기 변경의 회귀 작업에는 tdd/diagnose, 독립 초기 검토에는 ponytail-review 및 관련 경계 검토를 적용했으며 QA 중단 후 새 검증은 시작하지 않았다.
- P0: task_848d3b1591fe / ctx_1344d69a8946. 보고 접수 후 worker-release 성공.
- P0 schema: Codex 0.163.0, experimental 452 JSON files, 통합 schema SHA256 43e8c1495557ca91e33a63bbfae36c311c206253afae2974c979dbdf5d940c71. 임시 근거: /var/folders/ch/hkccv1d17qqds3ts_xpclvtm0000gn/T/codex-hub-p0-2yayf5jq.
- P0: Unix socket은 HTTP Upgrade+WebSocket. 사용자 전용 0700 디렉터리/0600 socket 확인. raw JSONL은 stdio에서만 적용. loopback TCP capability-token은 bearer 없음/오류 401, 올바른 bearer 101+initialize 성공. 실제 TUI/provider/G0 의미 보존 시험은 미실행.
- Rollout 0.163.0: event_msg.payload.type=token_count, info.total_token_usage/last_token_usage의 snake_case counters. token_count에 turn_id 없음. session_meta.id + task_started/turn_context.turn_id 문맥 필요. task_complete.last_agent_message는 버린다. 실제 파일은 읽기만 했고 값/원문을 보고에 포함하지 않음.
- Figma 실제 context/screenshot 확인: 7:20,7:92,7:389,7:440. 400pt popover, 20pt inset, 16pt section spacing, 13pt body, 11pt secondary, 17pt title, 42pt rate. user의 no-card 규칙 및 PRD의 SF Pro/system controls 지시가 Figma 임시 Inter/카드 스타일보다 우선한다.
