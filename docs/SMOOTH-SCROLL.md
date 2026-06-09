# 부드러운 스크롤 (Swift + Metal)

halite를 Rust+wgpu로 만든 가장 큰 동기 중 하나가 "부드러운 스크롤". 이 문서는 Swift+Metal에서 **동등 또는 더 나은** 부드러움을 보장하기 위한 구체 레시피.

## 핵심 명제

부드러움은 언어가 아니라 **렌더 아키텍처**의 결과다. Swift든 Rust든 다음 규칙을 지키지 않으면 둘 다 망하고, 지키면 둘 다 똑같이 매끄럽다.

macOS 단독 전제에서 Swift는 오히려 유리한 자리가 있다 — momentum phase, ProMotion vsync, NSEvent fidelity가 자동.

## 부드러움의 7가지 구성요소

| 요소 | 구현 |
|---|---|
| 1. GPU-side scroll offset | grid는 안 움직임. vertex shader uniform `float yOffset`만 변경 |
| 2. Sub-pixel precision | 픽셀 또는 0.5픽셀 단위 offset. 행 경계 스냅 금지 |
| 3. Display-synced render | `CVDisplayLink`로 vsync 콜백 |
| 4. Off-main PTY I/O | dedicated thread + lock-free ring buffer |
| 5. Persistent glyph atlas | `MTLTexture` 한 번 생성, incremental 추가만 |
| 6. Full-fidelity momentum | `NSEvent.scrollingDeltaY` + `momentumPhase` 직접 통합 |
| 7. Rubber-band edges | 끝 도달 시 spring 시뮬레이션 (~50줄) |

## CAMetalLayer 설정

```swift
let layer = CAMetalLayer()
layer.device = MTLCreateSystemDefaultDevice()
layer.pixelFormat = .bgra8Unorm                    // 또는 .bgra8Unorm_srgb
layer.framebufferOnly = true
layer.maximumDrawableCount = 3                     // triple buffer
layer.displaySyncEnabled = true                    // vsync on
layer.presentsWithTransaction = false              // 비동기 present
layer.contentsScale = window?.backingScaleFactor ?? 2.0
layer.needsDisplayOnBoundsChange = false           // 우리가 직접 통제
```

ProMotion 120Hz 화면이면 `CVDisplayLink`가 자동으로 120Hz로 콜백한다. `maximumDrawableCount = 3`은 GPU pipelining에 필수.

## CVDisplayLink 루프

```swift
private var displayLink: CVDisplayLink?

func startDisplayLink() {
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
    CVDisplayLinkSetOutputCallback(displayLink!, { _, _, _, _, _, context in
        let view = Unmanaged<DamsonSurfaceView>.fromOpaque(context!).takeUnretainedValue()
        view.drawIfDirty()                          // dirty flag 검사 후만 그림
        return kCVReturnSuccess
    }, Unmanaged.passUnretained(self).toOpaque())
    CVDisplayLinkStart(displayLink!)
}

func drawIfDirty() {
    guard gridDirty || scrollAnimating else { return }
    DispatchQueue.main.async { self.render() }      // 또는 dedicated render queue
}
```

스크린이 바뀌면(외장↔내장) `CVDisplayLinkSetCurrentCGDisplay`로 재바인딩 필요.

## Scroll offset 처리

핵심: **scroll 변경 시 grid를 재배치하지 않는다.** 셰이더 uniform 하나만 바꾼다.

```swift
struct RenderUniforms {
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var scrollYPixels: Float           // ← 이게 한 픽셀씩 변하면 부드럽게 보임
    var atlasSize: SIMD2<Float>
}
```

Vertex shader:

```metal
vertex VertexOut cell_vertex(
    constant CellInstance* cells [[buffer(0)]],
    constant RenderUniforms& u    [[buffer(1)]],
    uint vid [[vertex_id]],
    uint iid [[instance_id]]
) {
    Cell cell = cells[iid];
    float2 cellOrigin = float2(cell.col * u.cellSize.x,
                               cell.row * u.cellSize.y - u.scrollYPixels);
    // ...
}
```

`scrollYPixels`는 정수 픽셀일 필요 없음. `123.4` 같은 값도 자연스럽게 부드러움.

## NSEvent.scrollWheel 처리

트랙패드는 sub-pixel delta + momentum phase를 준다. **둘 다 활용해야** halite의 Rust 부드러움과 동등해진다.

```swift
override func scrollWheel(with event: NSEvent) {
    let dy: CGFloat
    if event.hasPreciseScrollingDeltas {
        dy = event.scrollingDeltaY              // sub-pixel
    } else {
        dy = event.scrollingDeltaY * cellHeight // 일반 마우스 (line 단위)
    }

    let isMomentum = event.momentumPhase != []
    let isUserDriven = event.phase != []

    scrollController.input(
        deltaPixels: dy,
        phase: event.phase,
        momentumPhase: event.momentumPhase,
        timestamp: event.timestamp
    )
}
```

`ScrollController`는 다음을 관리:

- `currentOffset: CGFloat` (sub-pixel)
- `velocity: CGFloat` (사용자 phase 끝났을 때 추정)
- `momentumIntegrating: Bool`
- `rubberBand: SpringState?` (끝 닿았을 때만)

사용자가 손을 뗀 후 macOS가 보내는 momentum 이벤트를 그대로 적분하면 시스템 네이티브 momentum 감(感)이 나온다. **자체 momentum 시뮬레이션을 짜면 안 된다** — 시스템과 어긋난다.

## Momentum이 macOS Rust에서 안 좋았던 이유

Rust 진영의 `winit` 같은 라이브러리는 `NSEvent`의 `momentumPhase`를 종종 평탄화하거나 손실한다. halite가 자체로 처리하려고 들였을 노력의 일부는 Swift로 가면 **자동으로** 풀린다. `NSEvent` 객체 자체를 그대로 받아 phase/delta를 직접 읽기 때문.

## 스크롤백 자료구조

```swift
final class Scrollback {
    private let storage: UnsafeMutableBufferPointer<Cell>  // 고정 capacity
    private var head: Int                                  // ring buffer head
    private var count: Int

    func rows(visibleRange: Range<Int>) -> UnsafeBufferPointer<Cell> {
        // contiguous slice (wrap 시 두 번 그리기)
    }
}
```

규칙:
- `Array<Cell>` 사용 **금지** (COW, ARC traffic, indirect)
- `UnsafeMutableBufferPointer` + 명시적 capacity
- 셀 한 개는 작은 struct (`UInt32 char + UInt32 attr` = 8B). 1만 줄 × 200 cols × 8B = 16MB — OK
- 큰 스크롤백(1억 셀 = 800MB)이 필요하면 page 단위로 디스크 매핑하는 후속 milestone

## Lock 디자인

```
[PTY thread]          parser thread          render thread (CVDisplayLink)
     │                       │                          │
     ▼                       ▼                          ▼
RawByteRing  ──read──►   VTParser  ──mutate──►   Grid (under gridLock)
                                                        ▲
                                                snapshot read (briefly hold lock)
```

`gridLock`은 `os_unfair_lock` (Swift의 `OSAllocatedUnfairLock`). 30μs 미만으로만 잡음.

또는 더 공격적: **double-buffered grid** — parser는 back buffer에 쓰고, render는 front 읽고, 매 vsync 직전 swap. Lock-free.

## 자주 부드러움을 깨는 안티패턴

- ❌ `NSScrollView` 안에 `CAMetalLayer` 호스트 → AppKit이 자체 스크롤 레이턴시 추가
- ❌ SwiftUI `ScrollView` 사용 → 같은 문제 + 더 심함
- ❌ `view.needsDisplay = true` / `setNeedsDisplay()` 매 PTY chunk마다 호출
- ❌ 매 프레임 `MTLBuffer` 재할당
- ❌ 매 프레임 CoreText 셰이핑 (glyph atlas 캐시가 무의미해짐)
- ❌ `NSAttributedString` 사용 (메모리 폭증, 셰이핑이 hot loop 진입)
- ❌ Swift `Array.append` / `Dictionary` 를 parser hot loop에서 사용
- ❌ PTY 데이터 도착마다 메인 큐로 hop
- ❌ Logging / `print` 를 hot path에서 — `os_log`도 비쌈

## 검증 방법

1. **Instruments Time Profiler** — render queue + parser queue 가 vsync 안에 끝나는지
2. **Instruments Metal System Trace** — drawable acquisition latency, encoder cost
3. **Pixel-perfect smoothness** — 화면 캡처 비디오를 240fps 카메라로 (or Quartz Debug)
4. **Synthetic burst test** — `yes` 또는 100MB log를 `cat`하면서 scroll. typing latency 측정
5. **ghostty와 동시 측정** — 같은 머신 같은 작업으로 cmux의 ghostty 대비 비교

## 목표 수치

- Idle: 0% GPU, 메인 스레드 wakeup 거의 없음
- Active scroll: 60Hz 화면에서 16.6ms 안, 120Hz에서 8.3ms 안 (median, p99 < 1 frame budget)
- Typing latency (keystroke → glyph on screen): cmux의 현재 ghostty와 동등 또는 ±1 frame 내
- Memory: 1만 줄 스크롤백 기준 < 64MB (atlas + grid + Metal buffers)
