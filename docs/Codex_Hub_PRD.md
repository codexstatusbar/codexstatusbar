# Codex Hub — macOS 메뉴바 모니터 PRD

> **문서 버전:** 1.0 · 2026-10-17  
> **제품명:** Codex Hub — 작업명, 최종 명칭 미확정  
> **대상:** 여러 Codex CLI 작업을 동시에 사용하는 macOS 개발자  
> **산출물:** 제품 요구사항, 연결 방식 조사, 수집·계산 설계, Figma UI  
> **구현 확정 (2026-10-17):** 사용자 지정에 따라 앱과 helper를 Swift로 구현하며 Apple Silicon(arm64) macOS 네이티브를 대상으로 한다. 기존 Rust helper 제안보다 이 결정이 우선한다.
> **검증 범위:** 공식 문서·공개 소스 조사 및 Figma 제작 완료. 사용자 Mac에서 실제 Codex 연결·성능·토큰 정합성을 실행 검증한 상태는 아니다.

## 1. 결정 요약

**Codex에 직접 연결하는 공식 인터페이스는 있다.** App Server와 CLI의 `--remote`를 이용하면 기존 터미널 UI를 유지하면서 실행 이벤트와 사용량을 관찰하는 통합을 설계할 수 있다. 따라서 이 제품을 처음부터 로그 감시 전용으로 제한하지 않는다. 다만 App Server 명령 및 WebSocket 경로는 공식 문서에서 실험적 기능으로 안내되므로, 설치 버전별 호환성 검증과 대체 경로를 필수로 둔다. [S01][S02]

### 채택안

| 우선순위 | 방식 | 적용 대상 | 결정 |
|---|---|---|---|
| 1 | **관리형 직접 연결: TUI ↔ 로컬 중계기 ↔ App Server** | Hub 실행 경로로 새로 시작하는 Codex | 직접 연결의 기본 설계. 호환성 시험을 통과한 버전에서 활성화 |
| 2 | 기존 공유 App Server/daemon 연결 | 이미 접속 가능한 엔드포인트가 있는 Codex | 기능 탐지. 읽기·구독·승인 충돌 검증을 통과한 어댑터만 제공 |
| 3 | **로그 + 선택적 상태 Hook** | 기존 독립 프로세스, 미지원 버전, 직접 연결 미사용 | 필수 호환 모드. 현재 실행 중인 Codex를 강제 재시작하지 않음 |

**직접 연결은 정확한 토큰별 서버 생성 시각을 제공한다는 뜻이 아니다.** 화면에는 `≈`가 붙는 실시간 **보이는 출력 추정 속도**와 `R`이 붙는 **보고된 출력 처리량**을 구분한다. 서버가 보고한 누적 출력 토큰 수는 별도 지표로 보관한다. 서로 다른 기준의 숫자를 합산하지 않는다.

### 사용자가 얻게 되는 결과

메뉴바에서 전체 활동과 합산 속도를 확인하고, 클릭하면 프로젝트·프로세스·스레드별 상태와 토큰 수를 본다. 프롬프트가 끝나면 이전 속도 대신 `Idle`이 표시된다. 실행 중인데 측정 자료가 없으면 `Working`, 연결 상태를 모르면 `Disconnected` 또는 `Unknown`을 표시한다.

## 2. Figma 디자인

**[Figma 전체 파일 열기](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm)**  
**[전체 화면 보드](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=3-39)**

| 화면 | 용도 | Figma |
|---|---|---|
| UI-01 | 실시간 합계, 개별 프로세스, 도구 실행·Idle 혼합 | [Live overview](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-20) |
| UI-02 | 프로세스·세션 상세, 출력/추론 구분, 마지막 턴 평균 | [Process detail](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-92) |
| UI-03 | 모든 프로세스가 프롬프트 입력 대기 | [All idle](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-165) |
| UI-04 | 실행 중이지만 샘플 없음, 승인 대기 | [Working and approval](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-230) |
| UI-05 | Direct/Logs 혼합, 보고 처리량, Partial 표시 | [Mixed sources](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-281) |
| UI-06 | 연결 끊김, 마지막 관측 시각, 재연결 진단 | [Disconnected](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-341) |
| UI-07 | 연결 검사, 관리형 직접 연결, 호환 모드 | [Connection setup](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-389) |
| UI-08 | 표시 기준, 측정 구간, Hook 동의, 보존 설정 | [Preferences](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-440) |
| UI-09 | 밝은 테마의 메인 화면 | [Light appearance](https://www.figma.com/design/P9TNlM9tQhWRAvhzPoAekm?node-id=7-506) |

Figma는 편집 가능한 텍스트·벡터·오토레이아웃·프로세스 행/버튼/배지 컴포넌트로 제작했다. 숫자, PID, 경로, 연결 검사 결과는 모두 설명용 가상 데이터다. 시안은 영문 UI이며 한국어 현지화를 막지 않는 구조로 구현한다.

**폰트/라이브러리 인계:** 연결된 macOS UI Kit의 가져오기 권한이 거부되어 로컬 네이티브 스타일 컴포넌트를 만들었다. Figma 서버에서 SF Pro 글자가 렌더링되지 않아 시안은 Inter로 대체했다. 실제 macOS 앱은 시스템 폰트(SF Pro)와 시스템 컨트롤을 사용하고, 시안의 대체 폰트를 앱에 강제로 이식하지 않는다. 폰트 파일은 산출물에 포함하지 않는다.

## 3. 목표와 범위

### 3.1 필수 목표

1. 여러 Codex 실행을 발견하고 동일한 기준으로 전체·개별 토큰 수와 속도를 표시한다.
2. 프로세스가 켜진 상태와 프롬프트를 처리 중인 상태를 구분한다.
3. 직접 연결을 우선 지원하되, 기존 터미널 사용 흐름을 유지한다.
4. 측정 기준·누락 범위·최신성을 사용자가 확인할 수 있게 한다.
5. 모니터링 때문에 승인·프롬프트·작업 결과가 변경되지 않게 한다.

### 3.2 v1 범위

- macOS 네이티브 메뉴바 앱, 클릭형 팝오버, 상세·설정 화면.
- 관리형 직접 연결 실험 기능과 로그 호환 모드.
- 프로세스/실행 단위 그룹, 내부 스레드·서브에이전트 구분.
- 출력 토큰, 추론 하위 항목, 현재 턴/이번 실행 통계.
- 보이는 출력 추정 속도, 보고 처리량, 마지막 완료 턴 평균.
- 상태 표시, 연결 진단, 메타데이터 삭제·보존.
- Hook 설치·삭제는 선택 사항이며 사용자 동의를 요구한다.

### 3.3 비목표

- Codex 대신 프롬프트를 작성하는 채팅 클라이언트.
- 승인 자동 수락, 도구 실행 제어, 원격 컴퓨터 관리.
- 숨겨진 추론 전체의 실시간 토큰 수 또는 서버 내부 순수 decode TPS 보장.
- 계정 과금 내역과 100% 일치하는 청구 분석.
- API 키 수집, 로그인 대행, 클라우드 대시보드.
- Codex 바이너리 패치, 네트워크 TLS 가로채기, 접근성 API를 이용한 터미널 OCR.
- v1에서 모든 IDE·Desktop 앱·원격 Codex를 무조건 지원한다는 약속.

### 3.4 제안 기본값

| 항목 | 기본값 |
|---|---|
| 지원 OS | macOS 14 이상을 개발 기준으로 제안. 실제 지원표는 빌드·시험 결과로 확정 |
| UI | SwiftUI + AppKit 보완, MenuBarExtra 또는 NSStatusItem |
| 수집·중계 | 번들 Swift helper; Swift UI와 별도 프로세스 |
| 저장소 | 로컬 SQLite, 숫자·식별자·시각만 저장 |
| Live 구간 | 5초 |
| 기본 평균 구간 | 작업 시작부터 현재까지 (2026-10-17 사용자 결정) |
| UI 갱신 | 최대 초당 2회, Idle에서는 이벤트 중심 |
| 메타데이터 보존 | 7일, 설정에서 변경·즉시 삭제 |
| 모양 | 시스템 Light/Dark 따름 |

위 항목은 구현 제안이며 측정 완료된 성능이나 사용자가 확정한 정책이 아니다. 메뉴바 API 선택의 근거는 Apple 문서다. [S14]

## 4. 직접 연결 조사 결과

### 4.1 공식 연결 경로

공식 문서에 다음 실행 예가 있다. 이는 연결 가능성을 확인하기 위한 예이며, 이 명령만으로 Hub 모니터가 완성되지는 않는다. [S01]

```bash
# 터미널 A: 로컬 App Server
codex app-server --listen ws://127.0.0.1:4500

# 터미널 B: 해당 서버에 기존 Codex 터미널 UI 연결
codex --remote ws://127.0.0.1:4500
```

App Server는 stdio JSONL과 WebSocket 계열 전송을 제공한다. 읽을 수 있는 정보에는 턴·아이템 상태, 답변 텍스트 조각, 스레드 사용량 갱신 등이 있다. 실제 바이너리에서 제공하는 스키마를 생성하여 클라이언트 어댑터를 검증한다. [S01][S03]

```bash
codex --version
codex --help
codex app-server --help
codex app-server generate-json-schema --out ./codex-hub-schemas
```

마지막 명령의 지원 여부와 옵션도 `--help`로 확인한다. 공개 `main` 소스가 설치된 바이너리와 같다고 가정하지 않는다.

### 4.2 수집에 필요한 실제 필드

조사한 App Server 스키마의 사용량 알림 구조는 다음과 같다. 응답 식별자 `responseId`가 항상 들어온다고 가정하면 안 된다. [S03][S04][S05]

```typescript
// 공식 타입에서 이번 제품에 필요한 부분만 발췌한 구조 설명.
// 실제 파서는 해당 설치 버전의 생성 스키마를 기준으로 한다.
type UsageNotification = {
  threadId: string;
  turnId: string;
  tokenUsage: {
    total: TokenUsage;
    last: TokenUsage;
    modelContextWindow: number | null;
  };
};

type TokenUsage = {
  totalTokens: number;
  inputTokens: number;
  cachedInputTokens: number;
  cacheWriteInputTokens: number;
  outputTokens: number;
  reasoningOutputTokens: number;
};
```

`total`과 `last`를 더하지 않는다. 같은 `last`가 재전송될 때 반복 누적하지 않는다. 생성 처리량에는 입력 토큰이나 캐시 입력 토큰을 포함하지 않는다.

### 4.3 기존 프로세스에 붙는 경우의 제약

현재 CLI에는 공유 서버 관련 경로가 있으므로 “기존 Codex에는 절대로 붙을 수 없다”고 단정하지 않는다. 반대로 아무 PID에 연결하면 모든 이벤트가 나오는 공개 전역 모니터 API가 있다고 가정하지도 않는다. [S02]

같은 App Server 안에는 연결별 스레드 구독 관리가 있다. 그러나 `thread/read` 스냅샷 읽기와 실시간 구독은 다르다. `thread/resume`을 단순한 무부작용 구독 함수로 취급하지 않는다. [S06][S01]

특히 서버의 outgoing 코드에는 스레드 구독 연결들에 서버 요청을 전송하는 경로가 있다. 두 번째 관찰 클라이언트가 승인 요청에 임의 응답하면 원래 TUI와 충돌할 수 있다. 따라서 v1 기본은 별도 관찰 클라이언트가 아니라 **기존 연결을 통과시키는 중계기**다. [S07]

서로 다른 App Server가 같은 저장 스레드를 동시에 쓰려고 하면 소유권 충돌이 발생할 수 있다는 저장소 설명도 고려해야 한다. 기존 작업을 새 서버에서 무조건 `resume`하는 접근은 채택하지 않는다. [S15]

### 4.4 대안 비교

| 방법 | 기존 TUI 유지 | 실시간 이벤트 | PID 연결 | 채택 판단 |
|---|---|---|---|---|
| 관리형 App Server 중계 | 가능, 실행 경로 변경 | 연결에서 관측되는 이벤트 | 런처가 직접 기록 | **우선 구현**, 버전 호환 검증 필수 |
| 기존 공유 서버의 추가 클라이언트 | 가능 | 구독 가능한 스레드 범위 | 별도 매칭 필요 | 안전한 관찰 어댑터를 확인한 경우만 |
| 세션 로그 감시 | 변경 없음 | 로그 저장 이벤트에 한정 | 불확실할 수 있음 | **필수 대체 경로** |
| 사용자 정의 Hook | 변경 없음, 설치 동의 필요 | 지원 생명주기 이벤트 | 세션 중심 | 상태 보완. 토큰 수집 대체 아님 |
| SDK / 비대화형 JSON 실행 | 실행 방식 변화 | 해당 실행 범위 | 런처 기반 | v1 인터랙티브 CLI 목표에 비주력 |
| OpenTelemetry | 설정 필요 | 전송·배치 지연 고려 | 별도 매칭 | 후속 계측 후보. v1 필수 아님 |
| MCP 도구 등록 | 도구로 호출될 때만 | 전역 토큰 관찰자로 보장되지 않음 | 별도 연결 | 주 수집원으로 미채택 |
| Codex 포크·토큰 콜백 추가 | 바이너리 관리 필요 | 직접 추가한 범위 | 가능 | 유지보수 비용 때문에 미채택 |

이 표의 마지막 열은 본 PRD의 설계 판단이며, 모든 대안을 실행 비교한 벤치마크 결과가 아니다.

## 5. 선택한 시스템 구조

```text
터미널 A                              터미널 B
codex-hub run                         codex-hub run
     │                                    │
     ├─ Codex TUI --remote                 ├─ Codex TUI --remote
     │      ↕                             │      ↕
     ├─ 로컬 Relay A                      ├─ 로컬 Relay B
     │      ↕ stdio JSONL                 │      ↕ stdio JSONL
     └─ 전용 App Server A                 └─ 전용 App Server B
            │                                    │
            └─ Relay가 메타데이터만 복사 ──────────┘
                              │
                    로컬 Collector / IPC
                              │
        기존 세션 로그 ───────┤
        선택적 상태 Hook ─────┤
                              ▼
                   정규화 / 중복 제거 / 상태 관리
                              ▼
                  SQLite + 메모리 속도 윈도우
                              ▼
                    macOS 메뉴바 / 상세 화면
```

`codex-hub run`은 **이 제품에서 구현할 런처 명령**이며 기존 Codex 명령이 아니다.

### 5.1 관리형 런처

- 실행마다 `run_id`를 생성한다.
- Codex 실행 파일의 절대 경로와 버전을 기록한다. 실행 중인 서버 버전도 별도로 확인 가능한 범위에서 기록한다.
- 작업 디렉터리, 프로필, 모델·샌드박스·승인 관련 설정을 기존 사용자 선택과 일치시킨다.
- `codex --remote`가 받는 인수와 App Server 시작에 필요한 인수를 구분하여 전달한다. 모든 CLI 옵션을 양쪽에 무조건 복제하지 않는다.
- 검증하지 않은 옵션을 받으면 명시적으로 실패하거나 사용자가 선택한 호환 모드로 시작한다. 조용히 옵션을 버리지 않는다.
- TUI PID, 서버 PID, 각각의 OS 시작 시각, `run_id`를 수집기에 등록한다.
- 인증은 Codex 자체 경로를 유지한다. Hub가 API 키나 계정 비밀번호를 요구하지 않는다.
- 원래 `codex` 명령을 몰래 대체하거나 shell alias를 자동 설치하지 않는다.

### 5.2 투명 중계기

기본 전송은 로컬 WebSocket ↔ 전용 App Server stdio의 변환이다. Unix socket 경로는 지원·권한·핸드셰이크 시험을 통과한 버전에서 우선 사용할 수 있다. 이는 제공된 공식 전송을 조합하는 **새 구현**이며 이미 제공되는 Hub 기능이라는 뜻은 아니다.

**보존 규칙**

1. 요청·응답·알림을 양방향으로 전달한다. 알 수 없는 메서드와 필드도 보존한다.
2. TUI의 `initialize` / `initialized` 교환을 전달하며 중계기가 별도의 초기화를 삽입하지 않는다.
3. JSON-RPC의 요청 ID와 방향을 변경하지 않는다. 승인 응답을 생성하지 않는다.
4. 프롬프트, diff, 도구 인수, 출력 원문은 전달에는 필요할 수 있으나 저장하지 않는다.
5. stdout의 JSONL과 stderr 진단을 분리한다. stderr 내용도 기본 저장하지 않는다.
6. 스트림 조각 수를 토큰 수로 사용하지 않는다.
7. 인증 토큰·원문을 로그에 출력하지 않는다. 허용 목록의 수치·상태만 수집기로 보낸다.

**장애 격리**

UI 종료 또는 팝오버 닫기는 중계기·Codex 종료를 의미하지 않는다. 수집기 중단이나 DB 쓰기 실패 시에도 중계 경로는 계속 동작해야 한다. 관측 큐와 제어 메시지 큐를 분리한다. 관측 큐가 넘치면 관측 자료를 버리고 `measurement_gap`을 기록하되, 제어 메시지는 임의 폐기하지 않는다.

다만 중계기 자체가 충돌하거나 통신 채널이 끊기면 Codex 연결에 영향을 줄 수 있다. 이 구조가 “어떤 장애에서도 작업에 영향이 없다”고 약속하지 않는다. 재접속 때 프롬프트나 도구 호출을 자동 재실행하지 않는다.

### 5.3 로컬 보안

- Unix socket 파일은 사용자 전용 권한으로 만든다. TCP 사용 시 `127.0.0.1`에만 바인딩한다.
- 로컬 TCP라도 인증 없는 제어 포트를 노출하지 않는다. 실행별 난수 토큰을 사용하고, CLI가 지원하는 환경변수 기반 전달 경로를 검증한다. [S01]
- 런타임 디렉터리는 사용자 전용 `0700`, 메타데이터 파일은 `0600`을 기준으로 한다.
- 실제 구현에서 PID 재사용, 심볼릭 링크, 소유권, 임의 IPC 메시지 주입을 검사한다.
- 종료 시 소유한 소켓·토큰만 삭제한다. 다른 Codex 서버나 다른 실행의 파일은 삭제하지 않는다.

### 5.4 기존 공유 서버 연결 어댑터

자동 탐지 자체는 수동 모드보다 먼저 시도할 수 있지만, 다음 검증 없이 활성 스레드에 개입하지 않는다.

- 해당 사용자가 접근 가능한 동일한 서버인지 확인.
- 초기화, 서버 정보, 지원 API, 인증·소켓 권한 확인.
- 읽기 가능한 스냅샷과 live 구독 경로의 차이 확인.
- 추가 연결이 승인 요청을 가로채거나 설정을 바꾸지 않는지 검사.
- 연결 해제가 마지막 구독자를 제거하여 스레드를 unload시키는지 검사.
- 연결 가능한 서버가 다른 서버 소유 스레드를 재실행하지 않는지 검사.

안전성이 확인되지 않은 버전에서는 “현재 작업은 로그로 관찰 / 다음 실행부터 직접 연결”을 안내한다. 공유 서버만으로 제어 TUI의 PID를 확정할 수 없으면 서버 또는 세션 단위로 표시한다.

## 6. 토큰 수집 규약

### 6.1 기준 정보

| 정보 | 직접 연결 | 호환 모드 |
|---|---|---|
| 스레드 사용량 | `thread/tokenUsage/updated` | 검증된 `event_msg` → `token_count` |
| 턴 시작/종료 | `turn/started`, `turn/completed` | 저장된 생명주기 이벤트 + 선택적 Hook |
| 보이는 출력 | `item/agentMessage/delta` | 일반적으로 실시간 수집 불가 |
| 도구 상태 | `item/started`, `item/completed` 등 | 지원 Hook 또는 저장된 이벤트 범위 |
| 승인 대기 | 서버 승인 요청의 메타데이터 | 지원 `PermissionRequest` Hook |
| 프로젝트/모델 | 스레드·설정·실행 이벤트의 검증된 필드 | 해당 버전 로그 메타데이터 |

직접 이벤트와 사용량 구조의 근거는 공식 App Server 스키마·문서다. 로그가 모든 delta를 저장하지 않는다는 근거는 공식 rollout 저장 정책이다. [S01][S03][S08]

### 6.2 정규화 데이터 모델

다음은 **Hub 내부 모델**이다. 공식 Codex wire schema에 이 필드가 모두 있다는 뜻이 아니다.

```typescript
type Source = 'direct-relay' | 'shared-server' | 'rollout-log' | 'hook';
type Quality = 'reported' | 'estimated' | 'partial' | 'unavailable';

type ProcessIdentity = {
  pid: number;
  osStartTime: string;
  role: 'tui' | 'app-server' | 'relay';
};

type NormalizedEvent = {
  schemaVersion: 1;
  localSequence: string;       // Hub가 부여. 서버 이벤트 ID로 오인하지 않음
  source: Source;
  sourceEpoch: string;
  codexHomeId: string;
  runId?: string;
  threadId?: string;
  turnId?: string;
  itemId?: string;
  parentThreadId?: string;
  receivedMonotonicNs: string;
  reportedWallTime?: string;   // 존재할 때만. 생성 토큰별 시각이 아님
  kind: 'usage-snapshot' | 'state' | 'visible-sample' | 'gap';
  data: Record<string, unknown>; // 저장 전 숫자/상태 허용 목록으로 제한
};
```

공식 식별 필드와 내부 식별자는 분리한다. `session_id`, `thread_id`, Hook 부모 세션을 무조건 같은 키로 취급하지 않는다. PID는 `(pid, osStartTime)` 조합으로 식별하고 `runId`로 실행의 생애를 구분한다.

### 6.3 출력과 추론

OpenAI usage의 추론 토큰은 출력 상세 항목이다. 다음처럼 표시한다. 다른 공급자는 어댑터 시험으로 의미를 확인한다. [S11]

```text
보고된 생성 토큰 = outputTokens
추론 토큰        = reasoningOutputTokens   # 생성 토큰 중 하위 항목
추론 외 출력     = outputTokens - reasoningOutputTokens
```

추론 외 출력은 반드시 사용자에게 보이는 최종 답변 텍스트만을 의미하지 않는다. UI에 “보이는 답변 토큰의 정확한 수”로 표시하지 않는다. 추론 값이 출력보다 크거나 필드가 누락되면 이상 상태를 기록하고 해당 분해를 제공하지 않는다.

### 6.4 누적 스냅샷 처리

정상적인 동일 카운터 구간에서는 다음 차이를 사용한다.

```text
신규 보고 출력 = 이번 total.outputTokens - 직전 total.outputTokens
```

필수 처리:

- 새로 시작한 빈 스레드임이 확정된 경우에만 기준값 0을 사용한다.
- 이미 실행 중인 스레드를 처음 발견하면 첫 스냅샷은 기준값이다. 과거 누적량을 방금 생성된 토큰으로 집계하지 않는다.
- 같은 누적 스냅샷 재수신은 추가 0이다.
- `total`과 `last`는 합산하지 않는다.
- 누적값 감소는 reset·rollback·복구 또는 잘못된 연결 가능성을 뜻한다. 단순 `max(0, delta)`로 숨기지 않는다.
- 검증된 lifecycle/reset 원인이 있는 경우 새 카운터 epoch를 만들고, 그렇지 않으면 정합성 확인 전까지 속도를 Partial/Unknown으로 둔다.
- 중단 후 최종 사용량이 없으면 마지막 보고값까지만 확정한다. 추정치를 확정값에 덧씌우지 않는다.
- 사용량이 늦게 와도 끝난 턴을 다시 Working으로 바꾸지 않는다.

```python
# 알고리즘 설명용 의사 코드. 실제 구현은 스키마 검증·트랜잭션·정수 범위 검사를 포함.
def on_usage(snapshot, authority, counter):
    validate_nonnegative_integer_usage(snapshot)
    if not authority.is_primary_for(snapshot.thread_id):
        return "secondary-source: reconcile only"

    if counter.baseline is None:
        counter.baseline = snapshot.total
        return "baseline: not current generation"

    if snapshot.total.output_tokens < counter.baseline.output_tokens:
        mark_counter_anomaly(snapshot.thread_id)
        suspend_rate_until_reconciled(snapshot.thread_id)
        return "counter regression: investigate epoch/rollback"

    delta = snapshot.total.output_tokens - counter.baseline.output_tokens
    # 아래 두 변경을 같은 DB 트랜잭션에서 수행한다.
    save_usage_delta_and_checkpoint(delta, snapshot)
    counter.baseline = snapshot.total
    return delta
```

새 빈 스레드 경로는 위 핸들러 전에 검증된 0 기준을 설정한다. `last`를 대체 합산하는 예외 규칙은 해당 버전별 테스트 없이는 만들지 않는다.

### 6.5 수집원 중복 제거

같은 스레드·카운터 구간에 대한 기본 사용량 수집원은 하나다.

```text
검증된 direct → 검증된 shared-server → 검증된 log
Hook은 사용량 합산 수집원이 아니라 상태 보조 수집원
```

선택하지 않은 수집원의 데이터는 복구·대조에만 사용한다. 직접 연결이 끊겨 로그로 전환할 때는 마지막 확정 누적 체크포인트를 대조한 뒤 전환한다. 같은 세션이라는 증거가 없으면 병합하지 않고 “연결 미확인”으로 남긴다.

`responseId`가 제공되지 않는 알림을 위해 가짜 응답 ID를 만들어 정확히 중복 제거했다고 주장하지 않는다. 누적 사용량·카운터 epoch·수집원 소유권으로 처리한다. 실제 응답 ID가 제공되는 미래 어댑터는 별도 기능으로 추가할 수 있다.

### 6.6 이전 설명 중 채택하지 않는 가정

- 조사한 현재 `protocol.rs`를 기준으로 `token_usage_record` / `TokenUsageRecord`를 v1 필수 포맷으로 삼지 않는다. [S09]
- 공식 목록에서 검증하지 않은 `OnTokenGenerated` Hook을 등록하지 않는다. [S10]
- 스트림 delta 하나가 토큰 하나라는 가정을 하지 않는다.
- 파일 수정 시각이나 프로세스 존재만으로 Generating/Idle을 확정하지 않는다.

## 7. 속도 계산과 합산

### 7.1 모드 A — Live visible estimate

**표시:** `≈325 tok/s`  
**의미:** 최근 5초 동안 관측한 보이는 agent 메시지를 로컬 토크나이저로 계산한 추정 출력 속도.

모델·공급자·encoding 매핑을 검증한 경우에만 숫자를 제공한다. `tiktoken`은 토크나이저 검증의 참고 구현이다. 모든 미래 모델이나 사용자 정의 공급자에 맞는 encoding이 자동 보장되지는 않는다. [S12]

**구현 규칙**

1. `threadId + turnId + itemId`별 agent 메시지 텍스트를 순서대로 메모리에서 누적한다.
2. 조각마다 독립 토큰화한 개수를 더하지 않는다. 조각 경계에서 BPE 결과가 달라질 수 있으므로 누적 메시지를 기준으로 재계산한다.
3. v1은 먼저 정확한 전체 재계산 방식을 검증하고, 큰 메시지는 검증된 증분 알고리즘 또는 계산 빈도 제한으로 처리한다.
4. 누적 토큰화 결과가 경계 재분할 때문에 수정될 수 있다. 최근 샘플을 교정할 수 있는 구조를 사용한다. 음수 수정분을 무조건 버려 장기 합계를 부풀리지 않는다.
5. 메시지 조각의 문자 해시로 중복 제거하지 않는다. 동일 문자열이 반복되는 정상 출력일 수 있다.
6. 재연결·중간 참여 시 과거 조각을 live로 다시 넣지 않는다. 시작을 놓친 item은 불완전으로 표시하고 다음 온전한 item부터 측정할 수 있다.
7. `item/completed`의 최종 텍스트와 대조하되, 재구성 차이는 품질 메타데이터로 남긴다.
8. 추론 요약·도구 stdout·diff·유저 입력을 agent 답변 토큰에 섞지 않는다.
9. 원문은 저장하지 않고 해당 item 계산이 끝난 후 폐기한다. 긴 출력으로 메모리 상한을 넘으면 추정 기능을 제한하고 Partial로 표시한다.

```text
V_i(t) = 스레드 i의 교정 가능한 누적 visible-token 추정치
W_live = 5초
r_i(t) = [V_i(t) - V_i(t - W_live)] / W_live
```

초기 관측 기간이 5초 미만이면 UI는 “수집 중” 또는 Warm-up 표시를 하며, 이를 정상 5초 측정값과 섞지 않는다. 토큰 재분할·누락 때문에 유효 구간이 되지 않으면 `—`를 표시한다. 임의의 `문자 수 ÷ 4`는 허용하지 않는다.

### 7.2 모드 B — 작업 평균 (2026-10-17 사용자 결정)

**표시:** 메뉴바 `평균 90 tok/s`, 메인 `작업 평균 합계`.
**의미:** 작업 시작 이후 새로 보고된 출력 토큰을 현재까지의 경과 시간으로 나눈다. 도구 실행·승인·대기를 포함한다.

```text
r_i(t) = 작업 시작 이후의 검증된 신규 outputTokens / 작업 시작부터 t까지의 경과 초
```

로그가 묶여 도착하면 갱신에 계단 현상은 남지만 10초 뒤 샘플을 버려 갑자기 0으로 만들지 않는다. 시작/기준을 놓쳤거나 연결 공백이 있으면 첫 유효 보고로 다시 기준을 잡고, 그 이후 증가량을 관측 경과 시간으로 나눈다. 이 값은 `관측 이후 평균`으로 구분하며 전체 작업 평균으로 주장하지 않는다. 첫 유효 증가 보고 전이나 경과 시간이 0이면 숫자를 만들지 않는다.

동일 시점에서 A가 20초 동안 100개, B가 10초 동안 100개를 보고했다면 각각 5, 10이며 합계는 15 tok/s다.

### 7.3 마지막 작업 평균

Idle 복귀 시 현재 속도는 사라지고 마지막 완료/중단 작업의 평균은 작업 요약에 남긴다. 정확히 같은 완료 턴의 늦은 사용량은 해당 이력만 보정한다. 부분 관측은 `직전 관측 구간 평균`으로 표시하며 순수 추론/decode 속도로 부르지 않는다.

### 7.4 전체 합계의 일관성

- 메뉴바는 선택된 **하나의 모드**에서 같은 현재 시점의 값을 합산한다.
- 현재 활성 턴에 대한 유효 샘플을 기본 합산 대상으로 한다. 완료된 턴의 이전 속도는 상세 이력에만 남긴다.
- 같은 갱신 프레임에서 동일한 종료 시점으로 모든 행을 계산한다. 작업 평균의 시작 시점은 각 작업 또는 관측 구간마다 다를 수 있다.
- 전체 = 표시 대상 각 행의 합. 반올림 전 합산 후 표시하며, 반올림 오차 정책을 명시한다.
- 모든 턴이 종료되면 최근 구간에 자료가 남아 있어도 메뉴바는 즉시 Idle로 전환한다.
- 실시간 visible 추정과 보고 처리량을 혼합하지 않는다.
- 모드 변경은 사용자가 인지할 수 있게 `실시간 추정` / `작업 평균`, 기준 라벨을 함께 변경한다.
- 지원하지 않는 세션은 숨기지 않고 `—`와 명확한 작업/측정 상태를 표시한다. 커버리지와 제외 이유는 작업 요약으로 옮기고 메인에는 Partial 문구를 표시하지 않는다.
- 커버리지는 “해당 모드로 측정 가능한 활성 실행 수 / 발견한 활성 또는 활동 불명 실행 수”로 정의한다. 확인된 Idle 실행은 분모에서 제외한다.
- 서브에이전트 포함 범위를 확인할 수 없으면 합계를 전체 사용량이라고 단정하지 않는다.

### 7.5 시간 기준

현재 구간은 로컬 monotonic clock을 사용한다. 서버 시각은 지연·상관관계 진단에 쓰되, 이벤트 수신 시각이나 `emittedAtMs`를 토큰이 서버 내부에서 생성된 정확한 시각으로 취급하지 않는다. [S07]

절전 복귀·시계 변경·연결 epoch 변경 시 live 윈도우를 새로 시작한다. 절전 중 누적된 자료를 복귀 순간의 초당 생성량으로 표시하지 않는다.

## 8. 상태 모델

단일 enum에 모든 의미를 넣지 않고 세 축을 유지한다.

```text
Connectivity: connected | degraded | disconnected | unknown
Activity:     idle | working | generating | tool_running |
              approval_wait | completed | interrupted | failed | unknown
Measurement:  warming_up | estimated | reported | partial | unavailable
```

| 관측 | 상태 처리 | 메뉴바/행 |
|---|---|---|
| 턴 시작 | Working, 측정 윈도우 초기화 | Working |
| agent 답변 delta + 검증된 샘플 | Generating | ≈값 또는 선택 모드 |
| 도구 실행 시작 | Tool running | 도구 상태; 관련 없는 stdout은 미집계 |
| 승인 요청 | Approval wait | Approval needed / 주의 표시 |
| 승인 요청 해소 | 실제 후속 상태로 이동 | 계속 대기 중이라고 고정하지 않음 |
| 최종 턴 완료 | Idle, 평균은 이력에 저장 | Idle 또는 남은 활성 작업의 합계 |
| 중단/실패 | Interrupted/Failed 이력 기록 | 남은 작업 없으면 현재 속도 제거 |
| 데이터 연결 단절 | Connectivity 변경 | Disconnected; Idle로 오인하지 않음 |
| 일정 시간 토큰 증가 없음 | 종료를 추정하지 않음 | Working 또는 측정 불가 |

동시 item·승인 요청을 ID 집합으로 관리한다. 도구 하나가 끝났다고 다른 실행 중 도구까지 끝난 것으로 처리하지 않는다. 승인 요청이 여러 개일 때 한 요청의 해결로 전체 승인 대기 상태를 해제하지 않는다.

**상태 우선순위:** 연결 장애/불명 → 승인 대기 → 도구 실행/생성 등 관측된 활동 → Working → 확정 Idle. 여러 작업이 혼재하면 속도와 주의 배지를 함께 표시할 수 있다.

## 9. 프로세스·스레드·서브에이전트

```text
Run (Hub가 추적하는 실행)
  ├─ TUI process identity
  ├─ App Server process identity
  └─ Threads
       ├─ Turns
       │    └─ Items
       └─ Child thread relationships
```

- 프로세스 수와 스레드 수를 다른 값으로 표시한다.
- 관리형 실행은 TUI와 서버 PID를 확정적으로 기록한다.
- 기존 로그의 작업 경로·시간이 유사하다는 이유만으로 PID를 확정하지 않는다.
- PID 연결이 없으면 “Session only”로 표시한다. 확인된 실행 목록과 관측된 세션 목록을 구분한다.
- 같은 디렉터리에서 실행한 Codex 두 개는 별도 run으로 유지한다.
- fork/resume은 이전 토큰 이력을 상속할 수 있다. 상속한 값은 이번 실행 생성량으로 합산하지 않는다.
- 부모 사용량이 자식 합계를 이미 포함하는지 어댑터별로 검증한다. 포함한다면 부모 합계와 자식을 다시 더하지 않는다.
- 자식 이벤트가 TUI 연결에 전달되지 않는 버전에서는 로그 보완을 시도하되, 중복·귀속을 확인할 수 없으면 Partial로 둔다.
- 토큰을 여러 프로세스에 동일하게 귀속시키지 않는다. 공유 서버에서 단일 귀속을 결정할 근거가 없으면 서버/스레드 단위로 표시한다.

## 10. 로그·Hook 호환 모드

### 10.1 로그 수집

기본 탐색은 사용자가 선택한 Codex home 및 해당 버전의 세션 저장 위치다. 일반적인 `~/.codex/sessions`를 기본 후보로 사용하되, `$CODEX_HOME`·별도 프로필·새 저장 형식을 고려한다. 모든 버전·일시적 스레드에 JSONL이 존재한다고 보장하지 않는다.

- 최초 색인과 이후 실시간 수집을 분리한다.
- FSEvents는 변경 힌트로 사용하고 누락에 대비해 주기적으로 파일 목록·크기를 대조한다.
- 파일 식별자 + 읽은 바이트 offset + 마지막 완전한 레코드를 체크포인트로 저장한다.
- 미완성 마지막 줄, UTF-8 조각, 파일 잘림·회전·이동, 앱 재시작을 처리한다.
- 파싱 불가 파일 하나 때문에 전체 수집기를 중단하지 않는다.
- 읽기만 하며 Codex 원본 로그를 수정·삭제하지 않는다.
- 레코드를 파싱한 뒤 숫자와 허용된 식별 정보만 유지한다.

### 10.2 Hook 상태 수집

공식 Hook은 지원되는 생명주기에서 명령을 실행하는 확장점이다. 버전별로 SessionStart, UserPromptSubmit, 도구/승인 관련 이벤트, Stop, SessionEnd 등의 지원을 탐지한다. 존재하지 않는 이벤트를 강제 등록하지 않는다. [S10]

Hook 명령은 매번 Python 런타임을 찾는 방식보다 앱에 번들한 작은 helper를 호출하도록 설계한다. 메시지는 이벤트명·세션 식별자·시각·작업 경로 등 최소 정보로 제한한다. 수집기가 꺼져 있어도 빠르게 종료하며 Codex 작업을 막거나 출력을 바꾸지 않는다.

**설치 요건**

- 설정 파일 위치·스키마는 설치 버전의 문서/기능으로 확인한다.
- 기존 Hook 설정 백업 및 병합. 전체 파일 덮어쓰기 금지.
- 설치·신뢰 승인 절차를 사용자에게 표시한다.
- 제거 시 Hub가 등록한 항목만 삭제한다.
- Hook의 부모 PID를 곧바로 Codex PID로 표시하지 않는다. shell/helper 중간 프로세스가 있을 수 있다.
- Stop은 종료 후보이며 다른 Hook이나 이벤트로 작업이 이어질 수 있다. 최종 완료와 구분한다.

## 11. UI·UX 상세 요구사항

### 11.1 메뉴바

| 상황 | 예시 |
|---|---|
| 유효한 live 추정 | `≈325 tok/s · 2` |
| 보고 처리량 모드 | `R90 tok/s` |
| 아직 측정 자료 없음 | `Working` |
| 승인 대기 포함 | `Working · !` 또는 `≈값 · !` |
| 모든 턴 종료 | `Idle` |
| 데이터 연결 단절 | `— · disconnected` |
| Codex 발견 안 됨 | 아이콘 또는 `No sessions` |

숫자는 monospaced digit 처리하여 폭 변화에 의한 흔들림을 줄인다. 노치·메뉴바 공간을 고려해 간략 표시 옵션을 둔다. `≈`나 `R` 의미는 툴팁과 팝오버 설명에서 확인할 수 있어야 한다. 단위나 기준을 숨긴 채 실시간 정확값처럼 보이게 하지 않는다.

### 11.2 팝오버

- 기준 폭 400pt. 실제 화면 크기에 따라 조정 가능한 최소 폭을 시험한다.
- 헤더, 측정 기준/구간, 합계, 커버리지, 프로세스 목록, 최신성/설정 순서.
- 행에는 프로젝트명, 검증된 PID 또는 Session only, 연결 방식, 해당 모드 속도, 실행 상태를 둔다.
- 기본 정렬은 승인/오류 → 활동 중 → Idle. 상태 변화마다 과도하게 순서가 바뀌지 않게 안정화한다.
- 선택 행은 상세로 연결하고 뒤로가기를 제공한다.
- Figma에는 전체 콘텐츠를 펼쳐 놓았다. 앱에서는 가용 화면 높이에 맞춰 목록/상세 내용만 스크롤하고 헤더·핵심 액션을 유지한다.
- 수집 실패를 사용자 작업 실패처럼 표현하지 않는다.

### 11.3 상세·설정

상세는 모델, cwd, TUI/서버 PID, thread/run 식별자, 현재 턴 보고 토큰, 추론 하위 항목, 마지막 완료 턴 평균을 구분한다. 경로와 식별자를 복사할 수 있다. 모델은 관측값을 쓰고, 모델 전환·재라우팅 시 갱신한다.

설정은 측정 모드·구간, Idle 표시, 로그인 시 실행, 호환 Hook 설치, 보존 기간, 메타데이터 삭제를 제공한다. 원문 저장 기능은 v1에 두지 않는다. UI 종료와 관리형 작업 종료를 별개로 표시한다.

### 11.4 접근성

VoiceOver가 상태·측정 기준·값을 함께 읽게 한다. 상태는 색상만으로 전달하지 않는다. 키보드로 팝오버 열기/행 선택/뒤로가기/닫기가 가능해야 한다. 숫자만 급변하는 자동 알림으로 화면 읽기를 방해하지 않는다. Reduce Motion 설정에서는 불필요한 애니메이션을 제거한다.

## 12. 기능 요구사항과 수용 기준

| ID | 요구사항 | 수용 기준 |
|---|---|---|
| FR-01 | 관리형 직접 연결 | 원래 TUI에서 입력·출력·도구·승인이 정상 동작하고 Hub는 별도 승인을 만들지 않음 |
| FR-02 | 설치 버전 탐지 | 미지원 옵션/스키마에서 직접 모드를 비활성화하고 이유·대안을 표시 |
| FR-03 | 다중 실행 분리 | 같은 cwd에서 4개 실행을 시작해도 run/PID가 섞이지 않음 |
| FR-04 | 사용량 집계 | 같은 누적 스냅샷 100회 반복에도 신규 사용량 1회만 반영 |
| FR-05 | 추론 중복 방지 | output=12,480, reasoning=8,960이면 전체는 12,480, 추론 외는 3,520 |
| FR-06 | Live 추정 | 모델별 테스트 encoding과 일치. 조각 분할 방식이 달라도 최종 visible count 동일 |
| FR-07 | 작업 평균 | A100/20초 + B100/10초 = 합계15 tok/s, 10초 경과만으로 샘플이 사라지지 않음 |
| FR-08 | 합계 기준 | 동일 모드·현재 시점의 프로세스별 평균을 합산. 커버리지·제외 이유는 작업 요약에 표시 |
| FR-09 | Idle 처리 | 완료 이벤트 처리 후 다음 UI 갱신에서 이전 속도 제거 |
| FR-10 | 실행 상태 | 토큰 이벤트가 없어도 활성 턴은 Idle로 잘못 표시되지 않음 |
| FR-11 | 연결 장애 | 단절 시 Disconnected, 재접속 후 과거 토큰이 순간 속도로 튀지 않음 |
| FR-12 | 로그 복구 | 잘린 마지막 줄·회전·앱 재시작 후 중복/누락 범위를 식별 |
| FR-13 | Hook 안전성 | 기존 설정 보존, 설치/삭제 가능, 수집기 종료 상태에서도 Codex 진행 |
| FR-14 | 원문 비저장 | DB·진단 로그·충돌 리포트·IPC 영속 파일에 원문/인증정보 없음 |
| FR-15 | UI 장애 격리 | 메뉴바 앱을 종료해도 관리형 Codex 실행·중계는 유지 |
| FR-16 | 서브에이전트 | 검증된 스코프에서 부모/자식 중복 없음. 불명일 때 완전한 합계로 표시하지 않음 |
| FR-17 | 종료 경계 | 중단/완료 후 늦은 사용량이 이력만 보정하고 실행 상태를 되살리지 않음 |

## 13. 비기능 요구사항

아래는 **구현 목표값**이며 현재 달성한 성능 수치가 아니다.

| 항목 | 목표 / 검증 방식 |
|---|---|
| 동시 실행 | 우선 20개 run, 100개 스레드 메타데이터 스트레스 시험 |
| UI 응답 | 수집 지연과 독립적으로 메뉴바 클릭·스크롤이 멈추지 않음 |
| 표시 지연 | 이벤트 도착 후 500ms 이내 상태 반영 목표. upstream 지연 별도 |
| 중계 오버헤드 | localhost 메시지 전달 추가 지연 p95 10ms 미만 목표 |
| 유휴 CPU | 시험 장비에서 앱+수집기 평균 1% 미만 목표, Codex 자체 사용량 제외 |
| 메모리 | UI+수집기 합계 150MB 이내 목표. Codex 서버와 TUI는 별도 측정 |
| 지속 시험 | 8시간 실행·절전/복귀·연결 반복 후 누적 메모리 증가 여부 확인 |
| 디스크 | 원문 저장 없음. 보존 기간·행 수 상한으로 DB 증가 제한 |
| 보안 | 사용자 외 접근 차단, 인증된 로컬 제어 연결, 민감 필드 마스킹 |
| 변경 대응 | 버전별 fixture와 capability matrix. 알 수 없는 데이터는 전체 앱 충돌 대신 기능 저하 |

모든 20개 run에 전용 App Server를 두는 구조의 비용도 측정한다. 공유 서버로 통합하면 사용 메모리를 줄일 가능성이 있지만, 프로세스 귀속·승인 분배·실행 격리를 다시 검증해야 하므로 기본 구조를 조용히 바꾸지 않는다.

## 14. 저장소·구현 모듈

```text
CodexHub/
  app/                 # SwiftUI 메뉴바·팝오버·설정
  helper/
    launcher/          # 실행 경로, PID+시작시각, 설정 전달
    relay/             # 양방향 프레이밍·인증·전달
    adapters/
      app_server/      # 버전별 메서드/필드 해석
      rollout/         # JSONL tail·체크포인트
      hooks/           # 최소 상태 이벤트
    normalize/         # thread/run 매핑·source authority
    metrics/           # 카운터·visible estimator·윈도우
    store/             # SQLite·보존·트랜잭션
    ipc/               # 사용자 전용 로컬 통신
  fixtures/            # 합성·민감정보 제거 데이터
  tests/               # 단위·프로토콜·장애·UI 테스트
  docs/                # 이 PRD, 호환성표, 릴리스 검증 결과
```

Swift 라이브러리의 정확한 버전은 초기 기술 검증에서 고정하고 lockfile로 관리한다. PRD에 확인하지 않은 패키지 버전을 넣지 않는다.

권장 테이블은 `runs`, `process_identities`, `threads`, `turns`, `usage_checkpoints`, `usage_deltas`, `source_authorities`, `state_events`, `measurement_gaps`, `file_checkpoints`, `settings`다. 실시간 원문과 토크나이저 작업 버퍼는 DB 테이블로 만들지 않는다. 카운터 변경과 체크포인트 저장은 한 트랜잭션으로 묶는다.

## 15. 시험 계획

### 15.1 출시 차단 기술 검증 — G0

실제 Mac에서 다음을 통과하기 전에는 직접 연결을 안정 기능으로 표시하지 않는다.

1. 설치된 CLI로 `--remote`와 전용 App Server 간 초기화 성공.
2. 중계기 전/후 프롬프트, 답변, 도구, 승인, 취소의 의미가 동일함.
3. 같은 연결에서 token usage 및 agent delta가 관측되는지 확인. TUI의 알림 opt-out에 의해 빠지는 이벤트가 있다면 capability로 반영.
4. 올바른 작업 디렉터리·모델·프로필·샌드박스·승인 정책 유지.
5. 원래 터미널의 입력·Ctrl-C·리사이즈·종료 동작 유지.
6. 추가 관측 수집기 장애가 중계 메시지를 손상하지 않음.
7. 로그와 직접 사용량 대조, 재개/fork/reset 포함.
8. 한 프로세스에서 여러 모델 호출과 서브에이전트가 생기는 경우의 카운터 스코프 확인.

G0 실패 시 원인을 명시하고 **로그 + 선택적 Hook을 해당 버전의 기본 지원 방식으로 출시**한다. 직접 연결 기능을 조용히 시뮬레이션하거나 가짜 live 속도로 대체하지 않는다.

### 15.2 필수 회귀 시나리오

| 시나리오 | 기대 결과 |
|---|---|
| 4개 프로세스 중 2개 생성, 1개 도구, 1개 Idle | 상태 분리, 같은 구간의 2개 유효 live 값만 합산 |
| 10초 동안 토큰 알림 없음, 턴은 진행 | Working/Tool/Approval 유지. Idle 오판 없음 |
| 동일한 usage 알림 반복 | 합계 증가 없음 |
| 사용량만 있고 마지막 턴 시작을 놓침 | 누적값 표시 가능, 해당 턴 평균은 불가 |
| 첫 색인에서 오래된 큰 로그 발견 | 과거 통계만 반영, 메뉴바 속도 폭증 없음 |
| 토큰 문자열 조각을 여러 분할 방식으로 제공 | 최종 visible 토큰화 결과 동일 |
| 같은 delta 문자열이 연달아 출력 | 정상 반복 출력으로 처리, 해시 중복 제거 금지 |
| unsupported tokenizer | 보이는 출력 tok/s는 —, 보고 카운트는 별도 유지 |
| 롤백/누적값 감소 | 오류·epoch 처리, 음수 속도나 허위 양수 증가 없음 |
| 직접 연결+같은 로그 동시 수집 | 하나의 authority로 집계 |
| 부모+자식+fork 사용량 | 상속·포함 관계 확인, 이중 합산 방지 |
| PID 종료 후 같은 PID 재사용 | 별도 실행으로 인식 |
| UI 강제 종료 | Codex TUI/중계 계속 진행 |
| 관측 큐 포화 | 제어 경로 보존, 측정 Gap/Partial |
| 중계기 자체 충돌 | 연결 장애 명시, 프롬프트 자동 재실행 없음 |
| 절전/복귀 | live 윈도우 재초기화, 밀린 보고를 현재 속도로 오인하지 않음 |
| 승인 요청 여러 개, 하나만 해소 | 나머지 승인 대기 유지 |
| 완료 직후 늦은 사용량 도착 | 이력 보정만 수행, 메뉴바 Idle 유지 |
| Hook 설정에 사용자 명령이 이미 있음 | 기존 명령 보존, Hub 항목만 추가·삭제 |
| 악성/잘못된 로컬 IPC 입력 | 인증·길이·형식 검사로 거부, 실행 제어 불가 |

## 16. 개발 순서와 출시 기준

### 단계 A — 프로토콜 검증

최소 relay와 실제 TUI 연결, metadata 관찰, 사용량·승인·중단 테스트를 먼저 수행한다. 지원하는 Codex 바이너리 버전, 실제 실행 서버 버전, 스키마 식별값, 테스트 일시를 호환성표에 기록한다. 공개 main의 파일 링크만으로 지원표를 확정하지 않는다.

### 단계 B — 신뢰 가능한 수집 기반

원본을 수정하지 않는 로그 수집, 누적 스냅샷 정규화, source authority, 상태 머신, DB 복구를 만든다. 이 단계만으로도 실행/Idle과 보고된 토큰 수를 보여줄 수 있어야 한다.

### 단계 C — 메뉴바 제품화

Figma UI-01~09, 전체·개별 분리, 커버리지, 측정 기준, 연결 진단을 구현한다. 과거 평균과 현재 속도를 명확히 나누고, 측정 불가 상태를 처음부터 포함한다.

### 단계 D — 직접 연결 Beta

G0을 통과한 조합에서 관리형 직접 연결과 visible 추정 기능을 제공한다. 호환 모드와 동일 데이터 정합성 테스트를 수행한다. Helper 장애·로컬 인증·옵션 전달 검증이 실패하면 릴리스를 차단한다.

### 단계 E — 선택적 확장

검증된 공유 daemon 관찰 어댑터, 추가 공급자 tokenizer, OTel 계측, 장기 통계는 후속 범위다. v1을 완료하기 위해 정확한 서버 순간 TPS를 가정하지 않는다.

### 완료 정의

- 필수 기능 요구사항 FR-01~17의 적용 모드별 테스트 결과가 있다.
- 지원하지 않는 버전·모델·측정 기준이 UI에 명시된다.
- 직접 모드에서 승인·프롬프트·도구 결과를 변경하지 않는 것이 확인된다.
- 누적값·추론·수집원·서브에이전트 이중 계산 회귀 시험을 통과한다.
- Figma와 구현의 상태·라벨·합산 기준이 일치한다.
- 사용자 Mac 실측을 하지 않은 수치를 실측 성능으로 소개하지 않는다.

## 17. 남은 검증 항목

| 항목 | 현재 상태 | 확정 방법 |
|---|---|---|
| 사용자 설치 Codex 버전 | 미확인 | 실제 `--version`, 실행 서버 정보 |
| TUI 중계 조합의 end-to-end 동작 | 문서·소스 근거 확보, 실행 미검증 | G0 |
| 현재 계정·프로필의 remote 인증/옵션 | 미검증 | 기존 실행과 대조 |
| 이미 실행 중인 공유 daemon의 안전한 구독 | 버전 의존 | 승인/소유권/구독 해제 시험 |
| 모델별 tokenizer 정확성 | 모델 미지정 | 모델·encoding 검증 fixture |
| 부모 카운터의 자식 포함 범위 | 어댑터별 확인 필요 | 다중 에이전트 실험 |
| 최소 지원 macOS·배포 방식 | 제안 상태 | 빌드/권한/서명 시험 |
| GitHub main과 설치 바이너리 차이 | 항상 가능 | 릴리스별 스키마·fixture 고정 |

**제품의 최종 약속은 “지금 무엇을 측정했는지 설명할 수 있는 전체·개별 Codex 모니터”다. 모르는 속도를 정확한 생성 속도처럼 보이게 만드는 것은 범위에 포함하지 않는다.**

## 18. 조사 근거

확인일은 2026-10-17이다. 공식 문서와 GitHub `main`은 변경될 수 있다. 아래 자료는 설계 근거이며, 사용자 설치 환경에서의 성공을 증명하는 실행 로그가 아니다. 저장소 인용은 추천 순위·인기도·완성도 보증을 의미하지 않는다.

- **[S01] OpenAI — Codex App Server.** TUI remote, 전송, 초기화, 이벤트, 승인. [공식 문서](https://learn.chatgpt.com/docs/app-server)
- **[S02] OpenAI — Codex CLI reference.** remote 옵션과 CLI/공유 서버 관련 명령의 확인 기준. [공식 문서](https://learn.chatgpt.com/docs/cli/reference)
- **[S03] openai/codex — ThreadTokenUsageUpdatedNotification.ts.** threadId/turnId/tokenUsage. [공식 스키마](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/ThreadTokenUsageUpdatedNotification.ts)
- **[S04] openai/codex — ThreadTokenUsage.ts.** total/last/modelContextWindow. [공식 스키마](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/ThreadTokenUsage.ts)
- **[S05] openai/codex — TokenUsageBreakdown.ts.** 입력·출력·추론 카운터 필드. [공식 스키마](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/TokenUsageBreakdown.ts)
- **[S06] openai/codex — thread_state.rs.** 연결별 스레드 구독 관리. [공식 소스](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/thread_state.rs)
- **[S07] openai/codex — outgoing_message.rs.** 스레드 연결 대상 전송, 서버 요청·응답, emittedAtMs. [공식 소스](https://github.com/openai/codex/blob/main/codex-rs/app-server/src/outgoing_message.rs)
- **[S08] openai/codex — rollout/policy.rs.** 로그에 보존할 이벤트 정책과 delta 제외 범위. [공식 소스](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/policy.rs)
- **[S09] openai/codex — protocol.rs.** 원본 토큰 사용량·세션/스레드 이벤트 정의. [공식 소스](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs)
- **[S10] OpenAI — Hooks.** 지원 생명주기, 입력·출력 계약. [공식 문서](https://learn.chatgpt.com/docs/hooks)
- **[S11] OpenAI — Reasoning models.** usage의 reasoning 하위 항목, 숨겨진 추론과 출력 관계. [공식 문서](https://developers.openai.com/api/docs/guides/reasoning)
- **[S12] openai/tiktoken.** 토크나이저의 공개 구현과 모델 encoding 매핑 참고. [저장소](https://github.com/openai/tiktoken)
- **[S13] kcosr/codex-threads.** 동일한 공유 App Server를 이용하는 동반 CLI의 구현 참고. 완성도·호환성 보증이 아니라 연결 방식의 사례다. [저장소](https://github.com/kcosr/codex-threads)
- **[S14] Apple — MenuBarExtra.** macOS 메뉴바 인터페이스 구현 근거. [공식 문서](https://developer.apple.com/documentation/swiftui/menubarextra)
- **[S15] openai/codex — App Server README.** 공개 프로토콜, 스레드 소유권 및 전송 관련 설명. [공식 저장소 문서](https://github.com/openai/codex/blob/main/codex-rs/app-server/README.md)

---

**인계 메모:** 이 문서는 구현 가능한 인터페이스에 기반한 제품/기술 설계다. Figma UI는 제작되었지만 macOS 앱, relay, Hook helper가 구현·배포된 것은 아니다. 개발은 G0 검증부터 시작하며, 실패한 조합에는 로그 호환 모드를 제공한다.
