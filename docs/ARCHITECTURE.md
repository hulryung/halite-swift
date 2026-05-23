# Architecture

## 정체성

halite-swift는 **두 가지 산출물을 동시에 제공**한다 — 같은 엔진 코어를 공유.

### 1. `HaliteTerminal` (Swift Package, 엔진 라이브러리)

cmux와 `halite.app`이 모두 임포트하는 엔진 코어.

- 출력물: Swift Package (`HaliteTerminal`)
- 진입 타입: `HaliteSession` (모델) + `HaliteTerminalView` (SwiftUI `NSViewRepresentable`)
- 의존: `Metal`, `MetalKit`, `CoreText`, `AppKit`, `QuartzCore`, `CoreVideo`. 외부 의존 0
- 빌드: `swift build` 또는 Xcode의 Swift Package 통합

라이브러리 자체는 윈도우/메뉴/탭/설정 UI를 **갖지 않는다**. 그것들은 호스트(cmux 또는 `halite.app`) 책임.

### 2. `halite.app` (독립 macOS 앱)

Rust halite처럼 자체 .app 번들로 실행 가능. `HaliteTerminal` 라이브러리를 임포트해서 그 위에 자체 UI 셸을 얹는다.

- 출력물: `halite.app` (Xcode app target)
- 책임: 윈도우, 메뉴바, 탭/분할 UI, 설정창, 테마 hot-reload, Sparkle 자동 업데이트, halite-cli 소켓 서버
- 빌드: Xcode 또는 `xcodebuild -scheme halite`
- 배포: `.dmg`로 묶어서 GitHub Releases (Rust halite의 현재 배포 방식과 동등)

### 왜 둘 다 만드는가

- **`HaliteTerminal` 라이브러리만**: cmux 통합은 깔끔하지만, 가벼운 단독 터미널 사용자(halite 현재 사용자)가 잃음
- **`halite.app`만**: 독립 정체성은 유지되지만, cmux와의 임베드 경계가 다시 생김 (옵션 1/2의 문제 재현)
- **둘 다**: 공통 엔진을 한 번 짜고 두 곳에 쓴다. ghostty가 이미 검증한 패턴 (`GhosttyKit.xcframework` + `Ghostty.app`)

엔진은 어느 호스트에서 실행되는지 모른다. 호스트가 `HaliteSession`을 만들고 `HaliteTerminalView`를 자기 뷰 계층에 꽂는다.

## 계층

```
┌─ HaliteTerminalView (SwiftUI NSViewRepresentable) ────── cmux가 사용
│  └─ HaliteSurfaceView (NSView + CAMetalLayer 호스트)
│       ├─ NSTextInputClient                                ── 입력 (IME)
│       ├─ scrollWheel / mouseDown / keyDown                ── 입력
│       └─ CAMetalLayer + CVDisplayLink                     ── 출력
│            └─ Renderer (Metal, persistent atlas)
├─ Terminal (model)
│  ├─ VTParser (state machine)
│  ├─ Grid + Scrollback (ring buffer, contiguous storage)
│  └─ Cursor / Selection / Hyperlinks
├─ PTYHost (off-main thread)
│  ├─ posix_spawn + openpty
│  └─ lock-free ring buffer → Renderer
└─ Config (struct, decoded from cmux-provided dict)
```

## 모듈 분할

### `HaliteTerminal` 라이브러리 (cmux + halite.app 공통)

| 모듈 | 책임 | 추정 LOC |
|---|---|---|
| `HaliteTerminalView` | SwiftUI 진입점 (`NSViewRepresentable`) | <200 |
| `HaliteSurfaceView` | NSView, 이벤트 라우팅, CAMetalLayer 호스팅 | ~1,500 |
| `VTParser` | ANSI/VT/xterm escape sequence state machine | ~3,000 |
| `Grid` | 셀 그리드, scrollback ring buffer, alt screen | ~1,500 |
| `Renderer` | Metal 파이프라인, 글리프 아틀라스, 셰이더 | ~3,000 |
| `Shaper` | CoreText 셰이핑, 리가처, East Asian Wide, NFC 정규화 | ~1,000 |
| `IMEController` | NSTextInputClient 어댑터 | ~500 |
| `PTYHost` | PTY spawn + I/O thread + lock-free queue | ~500 |
| `Selection` | 마우스 선택, 단어/줄 확장, find | ~800 |
| `HaliteConfig` | 폰트/색상/팔레트/스크롤백 옵션 struct | ~300 |
| `HaliteSession` | 위 모든 것을 묶는 외부 API | ~400 |

**라이브러리 합계 약 12,700줄.**

### `halite.app` 셸 (독립 앱 전용)

cmux는 이 코드를 보지 않음. `HaliteTerminal`만 임포트.

| 모듈 | 책임 | 추정 LOC |
|---|---|---|
| `HaliteAppMain` | `@main` 진입점, `NSApplicationDelegate` | ~200 |
| `WindowController` | `NSWindow`, traffic light, blur, chrome | ~600 |
| `TabController` | 탭바, 분할, 드래그 | ~1,200 |
| `SettingsView` | SwiftUI 설정창 (폰트, 테마, 키바인딩) | ~800 |
| `ThemeLoader` | 테마 hot-reload, light/dark 자동 전환 | ~300 |
| `HaliteCLIServer` | `halite-cli` 소켓 프로토콜 호환 서버 | ~600 |
| `UpdateController` | Sparkle 통합 | ~150 |
| `AppMenu` | 메뉴바, 단축키 | ~400 |

**셸 합계 약 4,250줄.**

### 총합

**약 17,000줄.** Rust halite(15~30k)와 비슷한 자릿수. CoreText/AppKit이 자체 폰트 셰이핑/IME/윈도우 코드를 흡수하기 때문에 약간 작아짐.

bonsplit(cmux 측 Swift 분할 UI)를 가져다 쓸 수 있다면 `TabController` LOC가 더 줄어듦. 다만 bonsplit이 cmux와 결합되어 있다면 별도 풀어내야 함.

## 핵심 데이터 흐름

### 출력 (PTY → 화면)

```
PTY fd  ─[I/O thread, blocking read]─►  RawByteRing
                                            │
                                  [parser thread or batched main]
                                            ▼
                                        VTParser
                                            │
                                            ▼ (mutations)
                                          Grid
                                            │
                            [CVDisplayLink callback, vsync-aligned]
                                            ▼
                                        Renderer.draw()
                                            │
                                            ▼
                                       CAMetalLayer
```

**불변식**:
- PTY 읽기는 절대 메인 스레드에서 안 함
- VTParser 적용은 lock 하나로 직렬화. 렌더는 lock 잡고 grid snapshot 만든 뒤 즉시 release
- 매 vsync마다 항상 그리는 게 아니라, **dirty flag** 있을 때만. dirty 없으면 마지막 drawable 그대로

### 입력 (키보드/마우스 → PTY)

```
NSEvent (keyDown / scrollWheel / mouseDown / IME)
   │
   ▼
HaliteSurfaceView (NSView)
   │
   ├─ IME 컴포지션 진행 중? → NSTextInputClient 메서드로 marked text 처리
   │     └─ 확정 시 insertText → bytes → PTY write
   │
   ├─ 키바인딩? → 호스트(cmux) 콜백 호출 후 swallow (PTY로 안 보냄)
   │
   └─ 평문 키/마우스 → VT-encoded bytes → PTY fd write (off-main)
```

## cmux와의 경계

halite-swift가 cmux에게 노출하는 표면 (Swift 그대로, FFI 없음):

```swift
public struct HaliteConfig {
    var fontFamily: String
    var fontSize: CGFloat
    var palette: [Int: NSColor]
    var backgroundColor: NSColor
    var foregroundColor: NSColor
    var scrollbackBytes: Int
    var argv: [String]
    var env: [String: String]
    var cwd: String?
    // ...
}

public final class HaliteSession: ObservableObject {
    public init(config: HaliteConfig)
    public func write(_ bytes: Data)            // 키 입력 외 추가 입력
    public func resize(cols: Int, rows: Int)
    public func scrollback() -> ScrollbackSnapshot
    public func find(_ query: String) -> [FindMatch]
    public func clearSelection()
    public var selection: String? { get }
    public var title: String { get }            // OSC 0/2
    public var workingDirectory: String? { get } // OSC 7
    public var processExited: Bool { get }
    public var exitCode: Int32? { get }

    // 콜백 (cmux가 구독)
    public var onTitleChanged: ((String) -> Void)?
    public var onBell: (() -> Void)?
    public var onExit: ((Int32) -> Void)?
    public var onURLClick: ((URL) -> Void)?
    public var onClipboardWrite: ((String) -> Void)?
}

public struct HaliteTerminalView: NSViewRepresentable {
    public let session: HaliteSession
    public var isActive: Bool
    public var onFocus: (() -> Void)?
    // SwiftUI 사용
}
```

**ghostty의 ~60개 C 함수와 대비**: 일반 Swift API ~15개. void* userdata 레지스트리, 콜백 디스패치, 메모리 매니지먼트가 모두 ARC와 클로저로 자연스럽게 처리되기 때문.

## 무엇을 halite(Rust)에서 가져오는가

코드는 못 가져옴 (언어 다름). **설계 결정**과 **단위 테스트 케이스**는 가져옴.

| halite에서 가치 있는 자산 | halite-swift에서 활용 |
|---|---|
| VT 파서가 다루는 escape sequence 카탈로그 | 동일 케이스에 대한 Swift 테스트 작성 |
| 글리프 아틀라스 페이지 분할 전략 | 동일 아이디어를 Metal 텍스처로 구현 |
| 리가처 매핑 테이블 (`=>` → ⇒ 등) | Swift dictionary로 옮김 |
| 한글 IME 디자인 (NFC 정규화 + Wide cell 정책) | NSTextInputClient 어댑터에 반영 |
| 테마 포맷 / 디폴트 팔레트 | Config struct 디폴트로 |
| `PLAN.md`의 milestone 순서 | halite-swift도 같은 순서로 진행하면 risk 단계적으로 해소 |
| `FEATURES.md` | spec/checklist로 사용 |

## 무엇을 다시 짜는가 (다 다시 짬)

- VT 파서 (Swift)
- Grid / scrollback
- Metal 렌더러 + 셰이더 (.metal 파일)
- 글리프 아틀라스
- IME 어댑터 (이 부분은 Swift에서 훨씬 짧음 — `NSTextInputClient`)
- PTY host (`posix_spawn` + `openpty`)

## 무엇을 짜지 않아도 되는가 (Swift/macOS가 줌)

라이브러리 코어가 안 짜도 되는 것:
- **폰트 셰이핑 엔진** — CoreText가 처리 (HarfBuzz 불필요)
- **NFC 정규화** — Foundation의 `String.precomposedStringWithCanonicalMapping`
- **트랙패드 momentum phase** — `NSEvent.momentumPhase`, `scrollingDeltaY`
- **ProMotion 120Hz vsync** — `CVDisplayLink` + `CAMetalLayer.maximumDrawableCount`
- **자동 색상 스킴 변경** — `NSApp.effectiveAppearance` KVO
- **접근성** — `NSAccessibilityElement` 프로토콜
- **IME 후보 창 위치** — `NSTextInputClient.firstRect(forCharacterRange:)`만 구현하면 시스템이 처리

`halite.app` 셸이 안 짜도 되는 것:
- **윈도우 chrome** — AppKit `NSWindow` + `NSVisualEffectView` 블러
- **메뉴바/단축키 UI** — `NSMenu`
- **설정창 폼** — SwiftUI `Form`, `@AppStorage` 자동 바인딩
- **자동 업데이트 UI** — Sparkle 다이얼로그
- **드래그앤드롭** — `NSPasteboard` + 커스텀 UTI
- **AppleScript dictionary** — 원하면 `.sdef`로 정의

cmux가 호스트일 때 안 짜도 되는 것 (라이브러리만 임포트하므로):
- 위 `halite.app` 셸 항목 전부 — cmux가 이미 가지고 있거나 무관
- **테마 hot-reload** — cmux가 자기 테마 시스템에서 `HaliteConfig` 새로 만들어 `session.updateConfig(_:)` 호출
- **탭/분할** — cmux의 bonsplit이 처리

## 빌드 시스템

- `Package.swift` (SwiftPM). cmux의 `Packages/HaliteTerminal/`에 vendored 또는 git 서브모듈
- Metal 셰이더(`.metal`) 컴파일: SwiftPM 0.5+ 또는 Xcode build phase. 셰이더는 `default.metallib`로 패키지에 임베드
- 테스트: `swift test`. VT 파서, Grid, IME에 unit test. 렌더러는 골든 이미지 비교 (optional)
- CI: GitHub Actions에서 macOS 14+ 러너. cmux가 호스팅하는 CI에 잡으로 추가

## 진행 milestone (제안)

halite의 `PLAN.md`를 참고해 순서 잡음. 각 milestone은 cmux에 통합 가능한 상태로 끝나야 함 (점진적 통합).

- **M1**: 검은 화면 + 'hello world' 출력 (PTY + 최소 파서 + 평문 글리프 렌더)
- **M2**: 256색 + 기본 escape (커서 이동, EL/ED, SGR)
- **M3**: 스크롤백 ring buffer + 마우스 휠 스크롤 (아직 부드럽지 않아도 됨)
- **M4**: **부드러운 스크롤** (sub-pixel offset, momentum) — [SMOOTH-SCROLL.md](SMOOTH-SCROLL.md)
- **M5**: 글리프 아틀라스 + CJK + East Asian Wide
- **M6**: 한글 IME (NSTextInputClient 어댑터)
- **M7**: 리가처
- **M8**: 선택 / 클립보드 / find
- **M9**: 하이퍼링크 OSC 8, 셸 통합 OSC 7/133
- **M10**: cmux에 통합, ghostty 대비 회귀 테스트
- **M11**: ghostty 제거

각 milestone 후 cmux에서 실측 비교 (typing latency, scroll smoothness, memory).

### `halite.app` 셸 milestone (병렬 트랙)

엔진 milestone과 독립적으로 진행 가능. M3 이후 언제든 시작 가능.

- **A1**: `HaliteTerminal` 라이브러리를 사용해 윈도우 1개 + 탭 1개로 `halite.app` 부팅
- **A2**: 탭 다중화 + 분할 (cmux의 bonsplit 차용 또는 자체 구현)
- **A3**: 설정창 + 테마 hot-reload + light/dark 자동 전환
- **A4**: `halite-cli` 소켓 프로토콜 호환 서버 (Rust halite의 외부 도구가 그대로 작동)
- **A5**: Sparkle 자동 업데이트, 코드사인, 노타라이즈, `.dmg` 배포
- **A6**: AppleScript 지원 (선택)

cmux 통합 트랙(M10–M11)과 `halite.app` 트랙(A1–A6)은 **같은 엔진 라이브러리에 동시 의존**한다. 한쪽에서 발견된 버그 수정은 다른 쪽에도 즉시 반영됨.

## 가장 큰 리스크

1. **VT 파서의 long tail** — 잘 알려진 escape sequence는 며칠이면 되지만, 실제 앱(vim, tmux, less, neovim의 TUI 라이브러리)이 의존하는 미묘한 모서리들이 수개월짜리 burndown. ghostty/iTerm2의 테스트 케이스를 빌려와야 함
2. **글리프 아틀라스 동적 갱신 vs 렌더 동기화** — 새 글리프 업로드 중 다른 surface가 같은 atlas를 읽으면 안 됨. fence/triple-buffered atlas 필요
3. **트랙패드 momentum 정확도** — Apple이 가끔 deltaY 단위를 변경. macOS major version별 회귀 가능 (cmux의 macOS 26 사례 참조)
4. **느린 첫 글리프 렌더링** — 첫 사용 시 CoreText 호출이 비쌈. 백그라운드 미리 캐시 워밍 전략 필요
