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

흐름: 경계 켜기(워치 또는 메뉴) → 10초 유예 → 실제 입력 감지 → 바로 잠금(기본) + 워치 알림 → 본인이 Touch ID·비밀번호로 풀면 경계가 자동으로 꺼지고 그 사실도 알린다.
"만지면 바로 잠금"을 끄면 알림에 붙은 "잠그기" 버튼으로 잠근다.

## 감지 방식

- 풀린 화면: HID 단계 이벤트 탭에서 **보낸 프로세스 PID가 0인 입력만** 실제 입력으로 본다. AI 화면 조작 같은 합성 입력에는 보낸 프로세스 PID가 찍힌다.
  무시한 합성 입력은 프로세스마다 한 번 `synthetic-ignored`로 기록한다.
- 잠긴 화면: 비밀번호 입력란의 보안 입력 때문에 키 입력이 탭에 안 보일 수 있어, 마지막 입력 뒤 경과 시간(HIDIdleTime)이 0으로 돌아가는 것으로 보조한다.
- 쓰지 않는 방식: HIDIdleTime 단독(합성 입력에도 0으로 돌아가 AI 작업 중 오알림), IOHIDManager(내장 트랙패드 움직임을 못 봄).
  근거는 2026-10-22 실측이며 `~/workspace/DECISIONS.md`에 있다.

## 설정과 빌드

```sh
scripts/setup-secrets.sh                 # ~/.config/mac_guard/api_token (600) 생성, 값은 출력 안 함
scripts/build-app.sh                     # dist/MacGuard.app, Apple Development 인증서로 서명
scripts/make-watch-secrets.sh <URL>      # 워치 앱에 맥 주소·토큰 넣기 (git 제외 파일)
cd watch && xcodegen generate            # MacGuardWatch.xcodeproj 생성
```

`~/.config/mac_guard/config.json` (빠진 항목은 기본값):

```json
{
  "port": 8787,
  "lockOnTouch": true,
  "armGraceSeconds": 10,
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

## 상태 (2026-10-22, M0)

확인함:
- 단위 테스트 30개 통과, APNs JWT 서명을 openssl로 교차 검증.
- 시험 모드(`dryRunLock`)로 띄운 맥 앱이 실제 입력에 잠금·알림 판단을 내고, 합성 입력은 무시.
- 워치 앱 시뮬레이터 빌드, 맥 앱 접속·푸시 토큰 등록, 워치 접속 코드와 맥 API 계약.

아직 안 함(사용자 승인·기기 필요):
- 설치한 앱의 입력 모니터링 허용, 실제 잠금(`SACLockScreenImmediate`)과 잠긴 화면 입력 감지 시험.
- 바깥 중계(tailscale funnel 등). 공개 노출 전에 인증 실패 제한과 독립 보안 검토를 먼저 한다.
- APNs 키 발급과 실제 푸시, 실제 워치 설치, 알림 "잠그기" 버튼 동작.
