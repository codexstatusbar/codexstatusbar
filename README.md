# Codex Hub

Apple Silicon macOS용 Swift 네이티브 메뉴바 모니터입니다. Codex 세션의 보고된 출력 토큰, 관리형 Live 가시 출력 추정, 활동 상태와 측정 범위를 보여줍니다. SwiftUI/AppKit 시스템 컨트롤과 카드 없는 400pt 팝오버를 사용합니다.

## 빌드와 실행

macOS 14+ 대상이며, 빌드에는 Swift 6.4 Command Line Tools가 필요합니다. Xcode 프로젝트는 사용하지 않습니다.

```sh
./scripts/build-app.sh
open '.build/Codex Hub.app'
# 또는 빌드 후 실행
./scripts/run-app.sh
```

번들은 arm64 release이며 로컬 ad-hoc 서명을 사용합니다. 배포 서명·공증은 되어 있지 않습니다. 첫 SwiftPM 빌드는 고정된 테스트 의존성을 내려받을 수 있습니다.

앱의 **연결**에서 Codex home을 선택하세요. 기본값은 `CODEX_HOME` 또는 `~/.codex`입니다. 원본 로그는 읽기 전용입니다. 목록에는 현재 살아 있는 프로세스만 표시하며, PID·시작 시각과 정확한 로그 파일 ID로 세션을 연결합니다. 종료된 프로세스의 이력은 메인 목록에 넣지 않습니다.

기본 속도는 **작업 평균**입니다. 사용량 로그가 도착할 때 작업 시작 이후 새로 보고된 출력 토큰을 해당 보고 시점까지의 경과 시간으로 나누며 도구 실행·승인 대기도 포함합니다. 다음 로그까지 값은 유지하며, Idle이나 다음 작업 시작만으로 지우지 않습니다. 살아 있는 프로세스별 마지막 유효 계산값을 합산하므로 현재 순간 생성 속도가 아닙니다. 완료 작업의 전체 평균은 **작업 요약**에 별도로 표시합니다. 시작을 놓쳤거나 연결 공백이 있으면 새 기준 이후의 **관측 이후 평균**으로 구분합니다. 첫 유효 보고 전에는 숫자를 만들지 않습니다.

같은 세션의 direct/log는 단일 권위만 사용하고 중복 여부가 확인된 CLI root만 합계에 포함합니다. 수집 범위·제외 이유는 작업 요약에서 확인할 수 있습니다. 메인과 메뉴바에는 내부 Partial/커버리지 문구를 표시하지 않습니다.

## 실험적 관리형 실행

Connection에서 설치된 Codex 실행 파일을 선택하고, 필요할 때 **Check helper compatibility**를 누릅니다. 이 동작은 제한 시간 내 버전만 검사하며, 실제 TUI·승인·provider 호환성을 검증하지 않습니다. 앱은 Codex 실행을 자동으로 시작하지 않습니다.

아래 명령의 경로는 자신의 설치에 맞게 바꾸거나 Connection에서 안전하게 인용된 명령을 복사하세요. 작업할 프로젝트 디렉터리에서 실행합니다.

```sh
'/path/to/Codex Hub.app/Contents/Helpers/codex-hub' doctor --codex '/absolute/path/to/codex'
env CODEX_HOME="$HOME/.codex" '/path/to/Codex Hub.app/Contents/Helpers/codex-hub' run --experimental --codex '/absolute/path/to/codex'
```

`--codex`를 생략하면 PATH에서 찾습니다. 현재 조사한 `codex-cli 0.163.0`만 허용하며, 임의 위치 인수·프롬프트·추가 플래그·프로필·resume/fork는 거부합니다. 관리형 relay는 **실험적이며 G0 미검증**입니다. 기존 Codex 실행에 붙거나 재시작하지 않으며, 앱 종료와 관리형 실행의 수명은 분리됩니다.

## 구조와 저장

- `CodexHubCore`: 상태·누적 사용량·작업/관측 구간 평균.
- `CodexHubCollector`: 읽기 전용 rollout/관리형 메타데이터 수집과 로컬 SQLite 체크포인트.
- `CodexHubApp`: SwiftUI 화면, AppKit 메뉴바, 사용자 설정.
- `CodexHubHelper`: Swift 런처와 로컬 relay. 프롬프트/응답 원문은 저장하지 않습니다.

프로덕션 구현은 모두 Swift와 macOS 시스템 라이브러리입니다. 메타데이터는 `~/Library/Application Support/CodexHub/homes/<homeHash>`, 관리형 관측 파일은 `managed-runs/<homeHash>`에 분리됩니다. 설정의 삭제/보존은 Hub 수집 메타데이터를 관리하며, 종료·소유권·파일 정체성이 확인된 관리형 관측 파일만 정리합니다. 원본 Codex 로그와 실행 중이거나 판단이 불명확한 관리형 파일은 유지하며, 정리를 보류한 이유는 Connection 진단에 표시합니다.

## 프로세스별 표시

살아 있는 프로세스 행은 개별 tok/s와 모델·추론 강도를 간단히 표시하며 작업 중인 항목이 먼저 나옵니다. Summary 버튼을 누르면 컨텍스트 사용률(%), K/M/G로 줄인 누적 입력·출력 토큰과 제한 창별 남은 사용률을 확인합니다. 컨텍스트는 `last_token_usage.total_tokens / model_context_window`, 입력·출력은 선택된 권위의 누적 스냅샷입니다. 남은 사용량은 각 창의 `100 - used_percent`이며 실제 창 길이와 reset 시각을 사용합니다. 계정 한도를 합산하거나 서버에 별도 조회하지 않습니다. 누적량에는 상속한 이력이 포함될 수 있고 모든 정보는 마지막 보고값입니다.

모드 선택은 설정에 있으며 `작업 평균`과 `실시간 추정 · 5초`로 표시합니다. 메뉴바·상단 대표 값은 같은 모드의 살아 있는 측정 항목 합계이며, 행마다 개별 속도를 보여 줍니다. 현재 모델이나 소스가 Live 추정을 지원하지 않으면 값은 미측정으로 남고 임의로 0을 만들지 않습니다.

Fast/Ultrafast는 Summary에서 프로세스가 기록한 요청 티어와 Codex home의 기본 설정을 따로 표시합니다. `priority`와 `fast`는 Fast로 표시합니다. 프로필·CLI override와 서버의 실제 응답 티어는 기본 설정과 다를 수 있으므로, 세션 기록이 없으면 활성 여부를 미확인으로 둡니다. home 설정은 작고 소유권이 확인된 일반 파일의 단순 root-level `service_tier`만 읽으며 변경하지 않습니다.

## 현재 범위

Live `≈`는 관리형 direct relay에서 처음부터 완전하게 관측한 가시 응답 텍스트만 공식 `o200k_base` 자산으로 계산합니다. 자산과 MIT 라이선스는 SwiftPM 리소스 번들로 helper 옆에 포함되며 실행 중 내려받지 않습니다. 관측된 provider 식별자가 정확히 `openai`이고 모델이 `o1`, `o3`, `o4-mini`, `gpt-5`, `gpt-4.1`, `gpt-4o` 중 하나인 경우만 지원합니다. 다른 모델·provider, 누락된 모델 정보, 완전하지 않은 시작, 갭, 오래된 관측과 워밍업은 unavailable/partial로 남습니다. provider 식별자는 원격 서버 신원의 보증이 아닙니다.

5초 Live 값에는 reasoning, 도구 출력, diff, 사용자 프롬프트와 과거 텍스트를 포함하지 않습니다. chars/4 같은 대체 계산은 없습니다. 최대 4개 항목, 항목당 16 KiB, 정규식 구간 512바이트와 계산 시간/작업량 제한을 넘으면 추정을 중단합니다. Swift 정규식/BPE 결과의 공식 tiktoken 동등성은 아직 검증하지 않았습니다. 현재 갱신은 초당 1회이며 서버의 순수 생성 속도가 아닙니다.

### 선택적 Hook

Connection 또는 Settings의 **Check hook status**, **Install hooks…**, **Remove hooks…**는 실제 bundled helper의 `hooks status/install/uninstall`을 사용합니다. 설치·제거는 선택한 `CODEX_HOME/hooks.json`, 기존 파일의 비공개 백업 보존, 관련 없는 핸들러 보존과 수동 신뢰 절차를 보여주는 네이티브 확인창을 통과해야 실행합니다. 기존 파일이 없으면 백업도 없습니다. UI는 설정 파일을 직접 쓰지 않으며 자동 설치·기능 활성화·신뢰 변경을 하지 않습니다. 사용자가 Codex `/hooks`에서 정확한 hook 정의를 직접 검토하고 신뢰해야 합니다. Installed 표시는 신뢰 또는 실행 호환성 검증을 의미하지 않습니다.

Hook은 상태 보조 자료일 뿐 사용량 소스가 아닙니다. 선택한 home의 정확한 세션/turn이 로그와 일치할 때만 tool 상태에 반영하며, Stop 등은 완료 후보로 표시하고 Idle을 만들지 않습니다. 설치 파일이 충돌하거나 안전하지 않으면 helper가 거부합니다. 실패·타임아웃 후에는 상태를 다시 확인하고 보존된 백업으로 복구 여부를 판단해야 합니다.

전체 PRD의 출시 완료 상태가 아닙니다. 합계의 범위 제약은 작업 요약에서 안내합니다. 로그인 시 실행은 사용자가 토글할 때만 변경합니다.

**2026-10-17 사용자 요청으로 QA를 재개했습니다.** Core/Collector 자동 테스트 59개가 통과했고 합성 UI fixture UI01–UI36가 통과했습니다. 실제 메뉴바 앱에서 발견한 읽기 전용 하드링크 로그 거부를 수정했으며, private 메타데이터의 단일 링크 제한은 유지합니다. 전체 QA 완료 상태는 아니며 TUI/승인/G0·VoiceOver·장시간 실행·macOS 14 기기, Live tokenizer 동등성과 실제 Hook 설치/신뢰·provider 동작은 미검증입니다. 최신 범위는 [QA 기록](docs/verification/collector.md)을 참고하세요.

자세한 내용: [PRD](docs/Codex_Hub_PRD.md), [관리형 helper 계약](docs/managed-helper.md), [네이티브 구현 기록](docs/verification/native-ui.md).

Live/Hook 계약: [Live estimator](docs/live-estimator.md), [optional hooks](docs/optional-hooks.md), [collector inputs](docs/collector-live-hooks.md).
