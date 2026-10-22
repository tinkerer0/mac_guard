# 맥 지킴이 (mac_guard)

맥북을 켜 둔 채 자리를 비웠을 때 누가 키보드·트랙패드를 만지면 애플워치로 알리고 잠금 화면을 띄운다.
잠금은 맥을 끄거나 재우지 않고 비밀번호 화면만 띄우므로(⌃⌘Q와 같음), 터미널 에이전트·빌드·다운로드는 계속 돈다.
멈추는 것은 화면을 보고 조작하는 작업(computer-use)뿐이다.

## 구성

| 부분 | 위치 | 하는 일 |
| --- | --- | --- |
| 맥 앱 | `Sources/MacGuard` | 메뉴 막대 앱. 실제 입력 감지, 잠금, 127.0.0.1 HTTP API, 워치로 푸시 |
| 핵심 로직 | `Sources/GuardCore` | 경계 판단(`GuardEngine`), HTTP 파서·API, APNs JWT·요청, 설정. 단위 테스트 대상 |
| 워치 앱 | `watch/` (xcodegen) | 경계 켜기/끄기, 만지면 바로 잠금 설정, 지금 잠그기, 알림의 "잠그기" 버튼 |

흐름: 경계 켜기(워치 또는 메뉴) → 5초 유예 → 실제 입력 감지 → 바로 잠금(기본) + 워치 알림 → 본인이 Touch ID·비밀번호로 풀면 경계가 자동으로 꺼지고 그 사실도 알린다.
"만지면 바로 잠금"을 끄면 알림에 붙은 "잠그기" 버튼으로 잠근다.

## 감지 방식

- 풀린 화면: HID 단계 이벤트 탭에서 **보낸 프로세스 PID가 0인 입력만** 실제 입력으로 본다. AI 화면 조작 같은 합성 입력에는 보낸 프로세스 PID가 찍힌다.
  무시한 합성 입력은 프로세스마다 한 번 `synthetic-ignored`로 기록한다.
- 잠긴 화면: 비밀번호 입력란의 보안 입력 때문에 키 입력이 탭에 안 보일 수 있어, 마지막 입력 뒤 경과 시간(HIDIdleTime)이 0으로 돌아가는 것으로 보조한다.
- 쓰지 않는 방식: HIDIdleTime 단독(합성 입력에도 0으로 돌아가 AI 작업 중 오알림), IOHIDManager(내장 트랙패드 움직임을 못 봄).
  근거는 2026-10-22 실측이며 `~/workspace/DECISIONS.md`에 있다.

## 설정과 빌드

```sh
scripts/build-app.sh                     # dist/MacGuard.app, Apple Development 인증서로 서명
scripts/install.sh                       # /Applications 설치 + 로그인 항목(비정상 종료 때만 재시작), 토큰·기본 설정 생성
scripts/install.sh --uninstall           # 로그인 항목만 지움(앱·설정·기록은 남김)
scripts/make-watch-secrets.sh <URL>      # 워치 앱에 맥 주소·토큰 넣기 (git 제외 파일)
cd watch && xcodegen generate            # MacGuardWatch.xcodeproj 생성
```

처음 켤 때 입력 모니터링 허용 창이 뜬다. 허용하면 앱을 다시 켜지 않아도 2초 안에 감시가 붙는다.
"종료 후 다시 열기"로 다시 켜지면 로그인 항목 밖에서 돌게 되므로, 그 뒤 `scripts/install.sh`를 한 번 더 실행하면 로그인 항목 관리로 돌아온다.

`~/.config/mac_guard/config.json` (빠진 항목은 기본값):

```json
{
  "port": 8787,
  "lockOnTouch": true,
  "armGraceSeconds": 5,
  "alertCooldownSeconds": 30,
  "apns": {
    "teamID": "Y35NBHS9WU",
    "keyID": "<APNs 키 ID>",
    "keyFile": "~/.config/mac_guard/AuthKey_<키 ID>.p8",
    "topic": "com.jinwoo.macguard.watch",
    "environment": "sandbox"
  }
}
```

입력 모니터링 허용은 서명 신원에 묶인다. 임시 서명(`codesign -s -`)은 빌드할 때마다 허용이 풀려서 개발 인증서로 서명한다.

## API (127.0.0.1만, `Authorization: Bearer <토큰>`)

`GET /v1/status`, `POST /v1/arm {"lockOnTouch"?}`, `POST /v1/disarm`, `POST /v1/settings {"lockOnTouch"}`, `POST /v1/lock`, `POST /v1/watch-token {"token","environment"?}`.
토큰이 틀리면 경로가 있는지도 알려 주지 않고 401을 준다. 바깥에서 오는 요청은 중계(예: tailscale funnel)가 이 주소로 넘겨준다.

## 시스템 설정과 부하

- 앱이 바꾸는 것: 잠금 화면(비밀번호 창)과 자기 파일(`~/.config/mac_guard`, `~/Library/Logs/MacGuard`)뿐이다.
  전원·잠자기·화면 꺼짐·화면 보호기·Lid Mode 설정은 읽지도 바꾸지도 않고, 잠자기를 막는 assertion도 만들지 않는다.
  화면을 끄는 `pmset displaysleepnow`는 쓰지 않는다.
- 입력 탭은 경계 중에만 켠다. 잠긴 화면 보조 감지 타이머(0.5초)도 경계 중이면서 잠긴 동안에만 돈다.
- 2026-10-22 측정(MacBook Air, macOS 26.6.2): 경계 꺼짐 상태 CPU 0.00%(가짜 입력 1628건을 넣어도 0.00%),
  경계 중 입력이 쏟아질 때 1.9%, 메모리 약 43MB. 잠금 시험 포함 42초 동안 누적 CPU 0.12초.
- 기록은 1MB를 넘으면 `.1`로 넘기고, 토큰이 틀린 요청은 1분에 한 줄만 남긴다. 동시 연결은 16개까지.

## 상태 (2026-10-22)

확인함:
- 단위 테스트 32개 통과, APNs JWT 서명을 openssl로 교차 검증.
- 실제 입력은 잡고 AI 화면 조작 같은 합성 입력은 무시(시험 모드 기록).
- 설치한 앱(로그인 항목)에서 실제 터치 → `SACLockScreenImmediate` 잠금 → 1초 안에 잠김 확인 → Touch ID로 풀자 경계 자동 해제.
  시험 앞뒤 전원·잠자기·잠금 설정 35줄이 같았고(다른 프로그램의 잠자기 방지 목록 표시만 달라짐), 그 시간대 시스템 잠자기 기록은 0건.
- 다시 빌드·설치해도 입력 모니터링 허용이 유지됨(개발 인증서 서명).
- 워치 앱 시뮬레이터 빌드, 맥 앱 접속·푸시 토큰 등록, 워치 접속 코드와 맥 API 계약.

아직 안 함:
- 잠긴 화면에서의 입력 감지(유휴 시간 보조) — 시험 때 바로 풀어 확인 못 함.
- 바깥 중계(tailscale funnel). 독립 보안 검토(Codex) 결과를 반영한 뒤 켠다.
- APNs 키 발급과 실제 푸시, 실제 워치 설치, 알림 "잠그기" 버튼 동작.
