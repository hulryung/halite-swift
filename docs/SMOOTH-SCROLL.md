# Smooth Scrolling (Swift + Metal)

One of the biggest motivations for building halite in Rust+wgpu was "smooth scrolling". This document is a concrete recipe for guaranteeing **equal or better** smoothness in Swift+Metal.

## Core thesis

Smoothness is a product of **render architecture**, not language. Swift or Rust, break the rules below and both fail; follow them and both are equally smooth.

Given a macOS-only premise, Swift actually has the advantage in places — momentum phase, ProMotion vsync, and NSEvent fidelity come for free.

## The 7 ingredients of smoothness

| Ingredient | Implementation |
|---|---|
| 1. GPU-side scroll offset | The grid doesn't move. Only the vertex shader uniform `float yOffset` changes |
| 2. Sub-pixel precision | Offset in pixel or 0.5-pixel units. No snapping to row boundaries |
| 3. Display-synced render | vsync callbacks via `CVDisplayLink` |
| 4. Off-main PTY I/O | dedicated thread + lock-free ring buffer |
| 5. Persistent glyph atlas | Create the `MTLTexture` once, incremental additions only |
| 6. Full-fidelity momentum | Integrate `NSEvent.scrollingDeltaY` + `momentumPhase` directly |
| 7. Rubber-band edges | Spring simulation on hitting the edge (~50 lines) |

## CAMetalLayer setup

```swift
let layer = CAMetalLayer()
layer.device = MTLCreateSystemDefaultDevice()
layer.pixelFormat = .bgra8Unorm                    // or .bgra8Unorm_srgb
layer.framebufferOnly = true
layer.maximumDrawableCount = 3                     // triple buffer
layer.displaySyncEnabled = true                    // vsync on
layer.presentsWithTransaction = false              // async present
layer.contentsScale = window?.backingScaleFactor ?? 2.0
layer.needsDisplayOnBoundsChange = false           // we control this ourselves
```

On a ProMotion 120Hz display, `CVDisplayLink` automatically calls back at 120Hz. `maximumDrawableCount = 3` is essential for GPU pipelining.

## CVDisplayLink loop

```swift
private var displayLink: CVDisplayLink?

func startDisplayLink() {
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
    CVDisplayLinkSetOutputCallback(displayLink!, { _, _, _, _, _, context in
        let view = Unmanaged<DamsonSurfaceView>.fromOpaque(context!).takeUnretainedValue()
        view.drawIfDirty()                          // draw only after checking the dirty flag
        return kCVReturnSuccess
    }, Unmanaged.passUnretained(self).toOpaque())
    CVDisplayLinkStart(displayLink!)
}

func drawIfDirty() {
    guard gridDirty || scrollAnimating else { return }
    DispatchQueue.main.async { self.render() }      // or a dedicated render queue
}
```

When the screen changes (external ↔ built-in), rebind with `CVDisplayLinkSetCurrentCGDisplay`.

## Scroll offset handling

The key: **never re-lay-out the grid on scroll.** Change a single shader uniform.

```swift
struct RenderUniforms {
    var viewportSize: SIMD2<Float>
    var cellSize: SIMD2<Float>
    var scrollYPixels: Float           // ← varying this one pixel at a time is what looks smooth
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

`scrollYPixels` doesn't need to be an integer pixel value. A value like `123.4` is naturally smooth.

## NSEvent.scrollWheel handling

Trackpads provide sub-pixel deltas + momentum phase. You **must use both** to match the smoothness of halite's Rust implementation.

```swift
override func scrollWheel(with event: NSEvent) {
    let dy: CGFloat
    if event.hasPreciseScrollingDeltas {
        dy = event.scrollingDeltaY              // sub-pixel
    } else {
        dy = event.scrollingDeltaY * cellHeight // regular mouse (line units)
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

`ScrollController` manages:

- `currentOffset: CGFloat` (sub-pixel)
- `velocity: CGFloat` (estimated when the user phase ends)
- `momentumIntegrating: Bool`
- `rubberBand: SpringState?` (only when hitting an edge)

After the user lifts their fingers, integrating the momentum events macOS sends — as-is — gives you the system-native momentum feel. **Do not write your own momentum simulation** — it will diverge from the system.

## Why momentum was poor in macOS Rust

Rust-side libraries like `winit` often flatten or lose `NSEvent`'s `momentumPhase`. Part of the effort halite would have spent handling this itself simply **goes away** in Swift: you receive the `NSEvent` object directly and read phase/delta straight off it.

## Scrollback data structure

```swift
final class Scrollback {
    private let storage: UnsafeMutableBufferPointer<Cell>  // fixed capacity
    private var head: Int                                  // ring buffer head
    private var count: Int

    func rows(visibleRange: Range<Int>) -> UnsafeBufferPointer<Cell> {
        // contiguous slice (draw twice on wrap)
    }
}
```

Rules:
- `Array<Cell>` is **forbidden** (COW, ARC traffic, indirect)
- `UnsafeMutableBufferPointer` + explicit capacity
- A single cell is a small struct (`UInt32 char + UInt32 attr` = 8B). 10k lines × 200 cols × 8B = 16MB — OK
- If a large scrollback is needed (100M cells = 800MB), disk-mapping by page is a follow-up milestone

## Lock design

```
[PTY thread]          parser thread          render thread (CVDisplayLink)
     │                       │                          │
     ▼                       ▼                          ▼
RawByteRing  ──read──►   VTParser  ──mutate──►   Grid (under gridLock)
                                                        ▲
                                                snapshot read (briefly hold lock)
```

`gridLock` is an `os_unfair_lock` (Swift's `OSAllocatedUnfairLock`). Held for under 30μs only.

Or, more aggressively: a **double-buffered grid** — the parser writes to the back buffer, render reads the front, and they swap just before each vsync. Lock-free.

## Anti-patterns that commonly break smoothness

- ❌ Hosting a `CAMetalLayer` inside an `NSScrollView` → AppKit adds its own scroll latency
- ❌ Using SwiftUI `ScrollView` → same problem, but worse
- ❌ Calling `view.needsDisplay = true` / `setNeedsDisplay()` on every PTY chunk
- ❌ Reallocating `MTLBuffer` every frame
- ❌ CoreText shaping every frame (makes the glyph atlas cache pointless)
- ❌ Using `NSAttributedString` (memory blow-up, shaping enters the hot loop)
- ❌ Using Swift `Array.append` / `Dictionary` in the parser hot loop
- ❌ Hopping to the main queue on every PTY data arrival
- ❌ Logging / `print` in the hot path — `os_log` is expensive too

## How to verify

1. **Instruments Time Profiler** — do the render queue + parser queue finish within vsync
2. **Instruments Metal System Trace** — drawable acquisition latency, encoder cost
3. **Pixel-perfect smoothness** — screen-capture video with a 240fps camera (or Quartz Debug)
4. **Synthetic burst test** — scroll while running `yes` or `cat`-ing a 100MB log; measure typing latency
5. **Side-by-side with ghostty** — compare against cmux's ghostty, same machine, same workload

## Target numbers

- Idle: 0% GPU, almost no main-thread wakeups
- Active scroll: within 16.6ms on a 60Hz display, 8.3ms on 120Hz (median, p99 < 1 frame budget)
- Typing latency (keystroke → glyph on screen): equal to cmux's current ghostty or within ±1 frame
- Memory: < 64MB for a 10k-line scrollback (atlas + grid + Metal buffers)
