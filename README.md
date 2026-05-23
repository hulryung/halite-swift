# halite-swift

`~/dev/halite`(Rust + wgpu)의 Swift+Metal 재작성 계획.

**두 가지 산출물을 동시에 제공한다**:

1. **`HaliteTerminal` (Swift Package, 엔진 라이브러리)** — cmux가 임포트해서 ghostty 자리를 대체
2. **`halite.app` (독립 macOS 앱)** — Rust halite처럼 자체 윈도우/탭/설정 UI로 단독 실행

두 산출물이 같은 엔진 코어를 공유하는 구조. ghostty가 `GhosttyKit.xcframework`와 `Ghostty.app`을 동시에 제공하는 것과 같은 패턴.

## 왜 Swift 재작성인가

cmux ↔ halite 통합의 **유지보수 경계가 영원히 사라지는** 유일한 길이기 때문. 동시에 macOS 단독이라는 전제에서 Swift는 독립 .app을 만들 때도 Rust보다 모든 면에서 유리하다 (네이티브 메뉴, IME, AppleScript, Sparkle, NSEvent fidelity).

| 접근 | cmux 변경 | halite 변경 | 통합 경계 | 평생 비용 |
|---|---|---|---|---|
| halite 라이브러리화 (C ABI) | 큼 | 큼 | FFI | 영구 |
| child NSWindow 합성 | 중 | 작음 | window | 영구 |
| **halite-swift (이 프로젝트)** | **거의 없음** | **큼 (재작성)** | **없음** | **0** |
| cmux를 Rust로 재작성 | 모두 | 없음 | 없음 | (4년) |

전제: **macOS 단독**. Linux/Windows 가능성 없음.

## 핵심 가설

1. macOS 단독이면 Swift + Metal + CoreText가 Rust + wgpu보다 **모든 측면에서 우세하거나 동등**
2. halite가 자랑하는 부드러움 — ProMotion 120Hz, sub-pixel scroll, momentum, Hangul IME — 의 절반은 macOS 네이티브 API에서 자동 처리됨 (Rust에선 손수 바인딩해야 했던 부분)
3. 진짜 차별점인 GPU 글리프 아틀라스 / 리가처 / 한글 셰이핑은 어느 언어로 짜도 같은 양의 일

## 문서

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 전체 아키텍처, 모듈 분할, 무엇을 halite에서 가져오고 무엇을 다시 짜는가
- [docs/SMOOTH-SCROLL.md](docs/SMOOTH-SCROLL.md) — 부드러운 스크롤을 Swift+Metal에서 어떻게 보장하는가 (구체 레시피)
- [docs/CMUX-INTEGRATION.md](docs/CMUX-INTEGRATION.md) — cmux 쪽에서 ghostty를 빼고 halite-swift를 끼우는 작업 범위

## 상태

설계 단계. 코드는 아직 없음.

## 출처 자료

- `~/dev/halite/` — Rust 원본. v0.M10.6까지의 milestone log는 `PLAN.md`, 기능 카탈로그는 `FEATURES.md`
- `~/dev/cmux/Sources/Ghostty*.swift` — Swift host가 GPU 터미널을 어떻게 임베드하는지의 참조 구현
- `~/dev/cmux/ghostty/include/ghostty.h` — C ABI 표면의 참조 (이번엔 필요 없지만 API 표면 크기 감 잡는 용도)
