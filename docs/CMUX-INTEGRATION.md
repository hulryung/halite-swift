# cmux 통합 계획

damson를 cmux에 끼우고 ghostty를 제거하는 작업 범위.

## 무엇을 의존하는가

cmux는 **`DamsonTerminal` Swift Package(엔진 라이브러리)만** 의존한다. `halite.app`은 별개 산출물이며 cmux와 무관.

```
~/dev/damson/
├── Package.swift                       ← cmux가 이걸 의존
├── Sources/DamsonTerminal/              ← 엔진 라이브러리 (cmux + halite.app 공통)
└── Apps/halite/                         ← 독립 .app (cmux 무시)
```

cmux 입장에서는 ghostty C 헤더/xcframework가 빠지고, 자리에 Swift 패키지가 들어오는 것뿐. `halite.app`의 존재는 cmux 빌드/런타임에 영향 없음.

## 기본 전략

**점진적**. ghostty를 한 번에 제거하지 않는다. 두 엔진이 공존하는 상태를 거쳐 회귀를 검증한 뒤 ghostty 제거.

1. damson를 cmux의 `Packages/DamsonTerminal/`로 vendored
2. cmux에 `BetaFeaturesSettingsView`의 토글 추가: "Use damson terminal engine"
3. 토글 켜진 surface는 `DamsonTerminalView`로, 꺼진 surface는 기존 `GhosttyTerminalView`로 렌더 — 한 윈도우 안에서 공존 가능
4. 모든 cmux UI 흐름(탭, 분할, 드래그, 검색, 클립보드, find, 색상 변경, 테마 hot-reload)을 damson surface로 회귀 테스트
5. 안정화되면 토글을 기본 켜짐으로
6. 한 사이클 후 ghostty 코드 / 서브모듈 / xcframework 제거

## cmux 쪽에서 사라지는 것

| 자산 | 처분 |
|---|---|
| `ghostty/` 서브모듈 | 제거 |
| `GhosttyKit.xcframework` | 제거 |
| `ghostty.h` (bridging) | 제거 |
| `cmux-Bridging-Header.h`의 ghostty include | 제거 |
| `Sources/Ghostty*.swift` (10 파일, ~17k LOC) | `Sources/Damson*.swift`로 대체. 다만 양은 1/3 ~ 1/4로 줄어듦 (FFI/콜백/userdata 레지스트리가 사라짐) |
| `scripts/setup.sh` 안의 `cd ghostty && zig build ...` | 제거 |
| `CLAUDE.md` 안의 GhosttyKit 빌드 명령 섹션 | damson 빌드 노트로 교체 |
| `docs/ghostty-fork.md` | 보존 (히스토리), 또는 `docs/archive/`로 이동 |

## cmux 쪽에서 새로 생기거나 바뀌는 것

| 자산 | 작업 |
|---|---|
| `Packages/DamsonTerminal/` | damson Swift Package vendored 또는 서브모듈 |
| `Sources/DamsonTerminalView.swift` (신규) | `DamsonSession` 생성/소멸, cmux config → `DamsonConfig` 변환, 콜백을 cmux 모델로 라우팅 |
| `Sources/DamsonConfigBuilder.swift` (신규) | `GhosttyConfig`가 했던 일을 `DamsonConfig`로. 폰트/팔레트/스크롤백/IME 옵션 매핑 |
| `Sources/WorkspaceSurfaceConfig.swift` | ghostty surface config 구조에서 halite session config로 |
| `Sources/Workspace.swift`, `Sources/TabManager.swift` | `TerminalSurface`(ghostty)와 함께 또는 대체하는 `DamsonSurfaceModel` |
| `Sources/Panels/TerminalPanel.swift` | 어느 엔진을 쓰는지 분기 (전환기) 또는 halite로 단일화 (완전 이행 후) |
| `Sources/AppearanceSettings.swift` | ghostty 전용 옵션 제거, halite 옵션으로 (대부분 1:1 매핑) |
| 단축키 시스템 | `ghostty_surface_binding_action` 호출이 사라지고, 키 라우팅을 cmux가 완전히 책임. `KeyboardShortcutSettings`에 영향 없음 |
| `GhosttyCrashReportMetadata` | `DamsonCrashReportMetadata`로 대체. 현재 surface, scrollback size 등 |
| `cmuxTests/` | ghostty 의존 테스트들을 halite 의존으로. 핵심 회귀(typing latency, IME, splits, drag tabs)는 그대로 유지 |

## API 매핑 표

cmux의 ghostty 사용처 → damson 대응:

| ghostty C API | damson Swift API |
|---|---|
| `ghostty_init`, `ghostty_app_new` | (불필요. 첫 `DamsonSession()`이 lazy 초기화) |
| `ghostty_app_tick` | (불필요. `CVDisplayLink`가 자동 tick) |
| `ghostty_app_set_focus` | `DamsonSession.isFocused = true/false` |
| `ghostty_app_update_config` | `DamsonSession.updateConfig(_:)` 또는 새 세션 생성 |
| `ghostty_config_new/free/load_*` | `DamsonConfig` struct (값 타입, ARC가 알아서) |
| `ghostty_config_diagnostics_*` | `DamsonConfig.validate() -> [Diagnostic]` |
| `ghostty_surface_new/free` | `DamsonSession(config:)` / deinit |
| `ghostty_surface_refresh` | `DamsonSession.requestRedraw()` (드물게 필요) |
| `ghostty_surface_set_size` | `DamsonSession.resize(cols:rows:)` |
| `ghostty_surface_set_focus` | `DamsonSession.isFocused` |
| `ghostty_surface_key` | `DamsonSurfaceView.keyDown(with:)` 내부에서 자동 |
| `ghostty_surface_preedit` | `DamsonSurfaceView`가 `NSTextInputClient` 직접 구현 |
| `ghostty_surface_mouse_*` | NSView 마우스 이벤트가 자동 처리 |
| `ghostty_surface_ime_point` | `firstRect(forCharacterRange:)` `NSTextInputClient` 메서드 |
| `ghostty_surface_text` | `DamsonSession.scrollback().fullText()` |
| `ghostty_surface_read_selection` | `DamsonSession.selection` |
| `ghostty_surface_has_selection` | `DamsonSession.selection != nil` |
| `ghostty_surface_clear_selection_compat` | `DamsonSession.clearSelection()` |
| `ghostty_surface_quicklook_word` | `DamsonSession.wordAt(point:)` |
| `ghostty_surface_complete_clipboard_request` | 콜백 `onClipboardRead` 의 completion에 String 반환 |
| `ghostty_surface_binding_action` | (cmux가 키 라우팅 완전 책임. 호출 자체가 사라짐) |
| `ghostty_surface_key_is_binding` | 동상 |
| `ghostty_set_window_background_blur` | cmux가 직접 `NSVisualEffectView`로 처리 |
| `ghostty_surface_process_exited` | `DamsonSession.processExited`, `onExit` 콜백 |
| `ghostty_surface_needs_confirm_quit` | `DamsonSession.hasUnsavedWork` 등 정책 결정만 cmux에서 |

## 콜백 단순화

ghostty C 콜백은 `void* userdata`를 받아 `TerminalSurfaceRegistry`에서 Swift 객체를 역참조하는 패턴이었다. damson에선:

```swift
session.onTitleChanged = { [weak self] title in
    self?.tabModel.title = title
}
```

ARC + 클로저로 끝. `TerminalSurfaceRegistry` 클래스 자체가 불필요해진다.

## 빌드 파이프라인 변경

`scripts/setup.sh`:
```diff
- (cd ghostty && zig build -Demit-xcframework=true ...)
+ (cd Packages/DamsonTerminal && swift build -c release)
```

`scripts/reload.sh`:
- ghostty 변경 시 xcframework 재빌드 트리거가 사라짐
- Swift Package는 Xcode가 자동으로 incremental 빌드
- 결과적으로 reload가 더 빨라짐

CI:
- `gh workflow run test-e2e.yml`은 그대로
- ghostty 빌드 캐시 단계 제거 가능 (Zig 툴체인 의존 제거)

## 회귀 검증 체크리스트

토글 전환 후 다음이 모두 통과해야 ghostty 제거 가능:

- [ ] `cmux DEV.app` 더블 클릭 → 첫 surface가 5초 안에 prompt까지
- [ ] 한글 IME: "안녕하세요" 입력 중 조합 깨짐 없음
- [ ] 한글 IME: 후보 창 위치가 커서 위치와 일치
- [ ] 1MB 텍스트 `cat` 도중 스크롤 (트랙패드) 부드러움
- [ ] vim에서 large file 열고 `j/k` 스크롤 typing latency 동등
- [ ] tmux 안에 nested cmux 안에 nvim 동작
- [ ] 분할 후 양쪽 surface 독립 입력
- [ ] 탭 드래그 재배치 후 surface 유지
- [ ] 윈도우 간 탭 이동 후 PTY/스크롤백 보존
- [ ] 백그라운드 색상 hot-reload (테마 변경)
- [ ] light/dark 자동 전환
- [ ] 클립보드 OSC52
- [ ] 셸 통합 OSC 7 (CWD) 정상
- [ ] find 오버레이 작동 + 결과 하이라이트
- [ ] 마우스 휠 momentum이 ghostty와 비슷한 감
- [ ] ProMotion 120Hz 화면에서 120Hz로 그려짐 (Quartz Debug 확인)
- [ ] Helper 프로세스 / 자식 셸 종료 시 surface 처리 일관
- [ ] AppleScript에서 surface 조작 (cmux의 `AppleScriptSupport.swift` 경유)
- [ ] CLI에서 `cmux send` 동작

## 일정 감

(필자/팀 한 명 기준 mental model. 실제 더 길어질 가능성 높음)

- damson 자체: M1–M9 약 3–5개월
- cmux 통합 (토글 + 표면 코드): 2–3주
- 회귀 검증 + 안정화: 1–2개월
- ghostty 제거 + 정리: 1주

총 약 5–7개월. 한 명이 풀타임이 아니면 그만큼 늘어남.

## 중간 중단 옵션

언제든 다음 상태로 멈출 수 있어야 함:

- damson가 M3까지만 완성되어도 cmux의 토글은 의미가 있음 (간단한 셸 사용은 가능)
- damson가 M9까지 와도 ghostty와 공존 가능. 사용자 선택 옵션
- ghostty 제거는 **마지막**에만, 충분한 dogfood 후

이러면 프로젝트가 중간에 정체되어도 cmux는 손상 없이 ghostty로 계속 운영 가능.
