# 한글 IME on macOS — Findings & Solution

## TL;DR

macOS의 한글 IME에는 두 층의 race가 있다:

1. **per-switch race**: 한영키로 한글 모드 전환 직후 첫 keystroke가 `setMarkedText`를 거치지 않고 raw character로 leak. **`.app` bundle 등록으로 해결**.
2. **per-launch race**: `.app`으로 실행해도 launch 직후 **사용자의 첫 keystroke** 한 번은 TSM↔IMK IPC가 아직 setup되지 않은 상태로 leak. **launch 직후 합성 dummy event를 inputContext로 흘려 IPC pre-warm**으로 해결.

damson는 두 층을 다 잡았다. 아래는 두 번째 race를 어떻게 발견하고 해결했는지의 기록.

---

## 문제

### 증상 1 — per-switch race (halite Rust 문서가 다룬 것)

영문 입력 모드에서 한영키로 한글 입력 모드로 전환한 직후, 첫 키스트로크가 정상적으로 composition을 시작하지 못한다:

```
의도: ㅎ → ㅏ → ㄴ → "한"
실제: ㅎ가 그대로 commit → "한" 이후부터 composition 시작
화면: "ㅎ한"
```

### 증상 2 — per-launch race (이 문서가 다루는 것)

`.app` bundle 등록으로 증상 1은 사라졌으나, **`.app`을 launch한 직후 단 한 번**, 사용자의 첫 한글 keystroke가 동일하게 leak된다. 그 후 IME 전환은 모두 정상.

다른 표현: `.app` 등록은 "IME 전환별 IPC race"를 잡고, 합성 dummy event는 "프로세스 시작 후 첫 keystroke 시점의 IPC 미설치 race"를 잡는다.

### 영향

- 한국어 사용자가 매 앱 실행마다 첫 글자를 BS+재입력으로 보정
- WezTerm / Terminal.app / iTerm2 같은 정식 macOS 터미널에는 둘 다 없음
- 우리도 동일 패턴 (.app + warmup) 적용해서 동일 결과 달성

---

## Root cause

### macOS의 TSM↔IMK IPC 모델

macOS Text Services Manager(TSM)는 IME service와 client process 사이의 IPC를 mach port로 관리.

| 시점 | TSM 동작 |
|---|---|
| LaunchServices에 등록된 GUI 앱(`.app`)이 launch | launch 시점에 IPC channel을 미리 set up |
| raw binary로 실행된 process | 첫 input event 도착 시점에야 lazy로 IPC 시도 |
| `.app` GUI 앱이 launch된 후 첫 input event | (소수 환경에서) IPC가 아직 fully ready 아닌 상태 — 첫 event leak 가능 |

`.app` 등록만으로 두 번째 race가 사라지는 게 표준 동작이지만, 우리 macOS 환경에서는 그것만으로는 부족했고 합성 dummy event로 IPC를 actively 깨워야 했다.

### 진단 signal

콘솔에 `IMKCFRunLoopWakeUpReliable` mach-port 에러가 첫 자모 직전에 한 번 찍힌다 — IPC가 lazy하게 set up되는 그 순간의 신호.

---

## 가설 검증 (요약)

halite Rust 문서 (`~/dev/halite/docs/KOREAN-IME.md`)가 7가지 가설을 다 검증해서 `.app`이 유일한 per-switch 해법임을 입증했다. damson는 그 결론을 출발점으로 삼아 우리 환경에 적용하면서, **`.app`만으로는 per-launch race가 남는다**는 새 관찰을 얻었다.

우리가 추가로 시도한 것:

| 시도 | 결과 |
|---|---|
| `customInputContext` (NSTextInputContext 명시 owner 지정) | ❌ default와 차이 없음 |
| `inputContext.activate()` 명시 호출 | ❌ activate만으로는 IPC 트리거 안 됨 |
| `keyDown` 안에서 동기 retry — 같은 event 재dispatch | ❌ 같은 microsecond 안에선 IPC가 warm-up 안 됨 |
| 비동기 retry + optimistic markedText | ❌ IMK 내부 state와 우리 state가 어긋나 lossy (halite Rust도 같은 결론) |
| `.app` trampoline (Phase B) | ✅ per-switch race 해결, per-launch race는 남음 |
| `.app` + viewDidMoveToWindow에서 합성 dummy event를 inputContext로 한 번 흘림 | ✅ 두 race 모두 해결 |

---

## 해법

### Layer 1: `.app` trampoline (`Sources/halite/AppBundleTrampoline.swift`)

raw binary로 실행되면 자기 자신을 `~/Library/Caches/halite/Damson.app` 안에 minimal bundle로 wrap한 뒤 `open -F` (fresh, saved-state 복원 안 함)로 relaunch하고 원본은 `exit(0)`.

```
~/Library/Caches/halite/Damson.app/
├── Contents/
│   ├── Info.plist    # CFBundleExecutable, CFBundleIdentifier, NSHighResolutionCapable 등 최소 필드
│   └── MacOS/
│       └── halite    # 매 launch마다 새 binary 복사
```

비활성화: `HALITE_NO_TRAMPOLINE=1` 환경변수.

### Layer 2: IME warmup (`Sources/DamsonTerminal/DamsonTerminalView.swift`)

`viewDidMoveToWindow`에서 first responder + `inputContext.activate()` 후, 다음 runloop tick에 합성 `keyDown` event ('a' character)를 `inputContext.handleEvent`로 흘림. 그 동안 콜백되는 `insertText` / `doCommand`는 `isWarmingUpIME` 플래그로 PTY 전송 swallow.

이 dummy event의 dispatch가 TSM↔IMK IPC를 actively 깨워서, 사용자가 첫 키를 누를 때 IPC가 이미 ready 상태.

비활성화: warmup만 끄려면 `didWarmupIME = true`로 초기화 (코드 변경 필요 — env var 노출은 후속).

---

## 광범위한 영향 (macOS 생태계)

같은 race가 다른 macOS 앱들에서도 보고됨:

| 프로젝트 | 이슈 | 상태 |
|---|---|---|
| Alacritty | [#6942](https://github.com/alacritty/alacritty/issues/6942), [#8079](https://github.com/alacritty/alacritty/issues/8079) | 미해결 (2023~) |
| winit | [#3095](https://github.com/rust-windowing/winit/issues/3095) | 미해결, `DS - appkit` 라벨 |
| Electron | [#45002](https://github.com/electron/electron/issues/45002) | "blocked/need-repro" |
| OpenJDK | [JDK-8356652](https://bugs.openjdk.org/browse/JDK-8356652) | 미해결 |
| Apple radar | [FB17460926](https://openradar.appspot.com/FB17460926) | 미해결 |

정상 동작하는 macOS 터미널 (Terminal.app, iTerm2, WezTerm, Warp)은 **예외 없이 `.app` bundle로만 배포**.

OpenJDK 같은 대형 프로젝트도 같은 메커니즘으로 막혀있어, Apple 외부에서 client-side로는 풀 수 없다는 방증.

---

## 메타 교훈

> 플랫폼이 강하게 권하는 패턴은 그냥 convention이 아닐 수 있다.

`.app` bundle은 macOS의 미적 선호가 아니라 LaunchServices / TSM / IMK 같은 시스템 컴포넌트 전체가 의존하는 **가정**. 그 가정에서 벗어난 채로 GUI 기능을 100% 정상 동작시키는 건 사실상 불가능.

또한 `.app` 등록도 silver bullet은 아니다 — launch 직후 IPC가 fully warm 되어 있다는 보장이 없는 환경에서는 우리가 직접 깨워줘야 한다.

---

## 관련 파일

- `Sources/halite/AppBundleTrampoline.swift` — Layer 1
- `Sources/halite/main.swift` — `AppBundleTrampoline.relaunchInAppBundleIfNeeded()` 첫 줄 호출
- `Sources/DamsonTerminal/DamsonTerminalView.swift` — Layer 2 (`warmupIMEIfNeeded` + `isWarmingUpIME` 플래그)

## 참고

- halite Rust 같은 작업을 먼저 한 사례: `~/dev/halite/docs/KOREAN-IME.md`
- WezTerm macOS install (raw binary 직접 실행 비권장): https://wezterm.org/install/macos.html
