# Tab & Pane Animations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add subtle, fast motion to tab and pane lifecycle interactions — create, switch, close, split — so the terminal feels fluid instead of instant/jarring, while keeping the disabled path byte-identical to today and never reflowing a live NSTextView/NSScrollView surface.

**Architecture:** Approach A — appearing content (new tab/pane) is pinned at its final frame and animated purely visually via `layer.transform` + `opacity` (zero reflow); torn-down content (closing tab/pane, the outgoing tab on switch) is captured as a bitmap **snapshot** overlay that animates out after the live view is gone; the existing/sibling pane resize **snaps** in one reflow (not animated — imperceptible at 0.16s). All motion is **0.16s easeOut**. Gated by a Settings toggle (`halite.animations`, default ON) **AND** macOS **Reduce Motion** (Reduce Motion always wins). A shared `Motion` helper centralizes the gate, timing, snapshot, overlay, and animation-group plumbing.

**Tech Stack:** Swift, AppKit, Core Animation / NSAnimationContext, SwiftPM.

---

## File Structure

| File | Created/Modified | Responsibility | Touched by |
|---|---|---|---|
| `Sources/DamsonTerminal/Motion.swift` | **Created** | Shared stateless motion helper: `enabled` gate (toggle AND not Reduce Motion), test-only pure `isEnabled(...)`, `duration` (0.16), `timing` (easeOut), `snapshot(of:)`, `overlay(image:frame:in:)`, `run(_:done:)`. Lives in the DamsonTerminal **library** (not the `halite` executable) so the gate is unit-testable. | Task 1 |
| `Sources/DamsonTerminal/DamsonConfig.swift` | **Modified** | Adds `public var animations: Bool` (default `true`), mirrored on `cursorBlink`. | Task 1 |
| `Sources/halite/SettingsView.swift` | **Modified** | Adds the `@AppStorage("halite.animations")` toggle in the Cursor section, its `.onChange`, **and** the `fromUserDefaults()` read in the `extension DamsonConfig` that lives in this same file (`object(forKey:) as? Bool ?? true`). | Task 1 |
| `Tests/DamsonTerminalTests/MotionTests.swift` | **Created** | Gating truth-table + `snapshot(of:)` non-nil/nil + timing-constant tests. The only automated coverage feasible (executable targets are untestable). | Task 1 (created); Task 7 (re-run only) |
| `Tests/DamsonTerminalTests/DamsonTerminalTests.swift` | **Modified** | One added assertion in `testConfigDefaults` for the new `animations` default. | Task 1 |
| `Sources/halite/CompactWindowController.swift` | **Modified** | Tab-lifecycle animations: `TabTransition` enum; `selectTab(_:transition:)` create + switch branches; `addTab`/`addNewTab` create; `closeTab` snapshot-overlay close; `contentContainer` made layer-backed. | Task 2 (create), Task 4 (close), Task 6 (switch) |
| `Sources/halite/PaneTreeView.swift` | **Modified** | Pane-lifecycle animations: `PaneAnimation` + `ClosingEdge` enums; `rebuild(animation:)`; `findWrapper(for:in:)`; `animateSplitIn(newLeaf:direction:)`; `split(direction:)` and `closeActive()` gating + capture. | Task 3 (split), Task 5 (close) |

No new files or production-code changes in Task 7 (pure QA pass).

---

## Task 1: Motion core + settings plumbing (no behavior change)

Establishes the shared `Motion` helper, the `DamsonConfig.animations` field, the `SettingsView` toggle, and the gating unit tests. **No interaction is animated yet** — nothing reads `Motion.enabled` after this task. The toggle persists and the gate is correct, but it has **no visible effect until Task 2** wires callers. That no-op is expected, not a bug.

**Files:**

- **Create** `Sources/DamsonTerminal/Motion.swift` — the shared motion helper (`enabled` gate, `duration`, `timing`, `snapshot(of:)`, `overlay(...)`, `run(...)`, plus a test-only pure `isEnabled(...)`).
  - **Deviation note:** the approved design (§Architecture, spec lines 46/48) says `Sources/halite/Motion.swift`. Placed in the **DamsonTerminal library** instead because the `halite` executable is not unit-testable (Package.swift test targets depend only on DamsonTerminal/DamsonControl, never on the executable — confirmed Package.swift lines 62–71), and Testing (spec lines 116–120) requires automated coverage of `Motion.enabled` + `snapshot(of:)`. The **public API and all call sites are identical** — callers already `import DamsonTerminal`, so they write `Motion.enabled` exactly as the spec shows. This is a justified deviation, not a bug; the public API is byte-for-byte what the spec prescribes.
- **Modify** `Sources/DamsonTerminal/DamsonConfig.swift` — add `public var animations: Bool` (after `cursorBlink`, line 28), the init parameter (after `cursorBlink: Bool = false,` at line 49) and the assignment (after `self.cursorBlink = cursorBlink` at line 61).
- **Modify** `Sources/halite/SettingsView.swift` — this single file requires **two** edits: (1) in the SwiftUI `DamsonSettingsView` struct, add `@AppStorage("halite.animations")` (new line 15, after the `cursorBlink` declaration at line 14), a `Toggle("Animations", ...)` in the Cursor section (new line after line 99), and an `.onChange` (new line after line 123); (2) in the `extension DamsonConfig { static func fromUserDefaults() ... }` that lives **in the same file** (lines 210–247), add the read right after the `cursorBlink` read (line 229).
- **Create** `Tests/DamsonTerminalTests/MotionTests.swift` — gating truth table + snapshot tests.
- **Modify** `Tests/DamsonTerminalTests/DamsonTerminalTests.swift` — add one assertion to `testConfigDefaults` (after the `XCTAssertFalse(config.argv.isEmpty)` line at line 18) for the new field's default.

---

- [ ] **Step 1: Create `Motion.swift` in the DamsonTerminal library.**

Create `Sources/DamsonTerminal/Motion.swift` with this exact content:

```swift
import AppKit

/// 탭/페인 생성·전환·닫기·분할에 공통으로 쓰는 모션 헬퍼.
/// 상태 없는 정적 멤버만 — 인스턴스 없음.
///
/// 위치 메모: 디자인 스펙은 `Sources/halite/Motion.swift`라고 적었지만,
/// halite 실행 타깃은 단위 테스트가 불가능하다(Package.swift의 test 타깃은
/// DamsonTerminal/DamsonControl 라이브러리에만 의존). 스펙 Testing 절이
/// `enabled` 진리표와 `snapshot(of:)` 자동 커버리지를 요구하므로
/// 테스트 가능한 DamsonTerminal 라이브러리에 둔다. 호출 측 코드는 동일하다
/// (호출자들은 이미 `import DamsonTerminal`).
public enum Motion {

    /// 모든 라이프사이클 애니메이션의 지속 시간. 0.16s — 기존 스크롤 스냅/벨 플래시와 동일한 감각.
    public static let duration: TimeInterval = 0.16

    /// 모든 애니메이션의 타이밍 곡선. easeOut — 스크롤 스냅/벨 플래시와 동일.
    public static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }

    /// 마스터 게이트. 각 애니메이션 진입점에서 매번 LIVE로 읽는다(캐시 금지).
    /// 사용자 토글이 켜져 있고 AND macOS Reduce Motion이 꺼져 있을 때만 true.
    /// Reduce Motion은 토글과 무관하게 항상 우선(애니메이션 차단)한다.
    /// 키가 없으면 기본값은 true(애니메이션 ON).
    public static var enabled: Bool {
        let toggle = (UserDefaults.standard.object(forKey: "halite.animations") as? Bool) ?? true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return isEnabled(toggledOn: toggle, reduceMotionEnabled: reduceMotion)
    }

    /// 순수 게이트 함수 — 명시적 파라미터만 받고 전역 I/O가 없어 단위 테스트가 쉽다.
    /// `enabled`가 UserDefaults/NSWorkspace를 읽어 이 함수에 위임한다.
    /// 테스트 전용 seam: 프로덕션 코드에서 직접 호출하지 말 것(대신 `enabled` 사용).
    static func isEnabled(toggledOn: Bool, reduceMotionEnabled: Bool) -> Bool {
        toggledOn && !reduceMotionEnabled
    }

    /// 뷰의 현재 렌더링을 비트맵으로 스냅샷. 사라지는/철거되는 콘텐츠
    /// (닫히는 탭·페인, 전환 시 나가는 탭)에 쓴다. NSTextView/NSScrollView 내용까지 잡힌다.
    /// 0 크기 뷰이거나 캐싱 실패 시 nil — 호출자는 nil이면 즉시(instant) 경로로 폴백해야 한다.
    public static func snapshot(of view: NSView) -> NSImage? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        view.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }

    /// `host.layer` 위에 자기완결적인 이미지 기반 CALayer를 `frame`(host 좌표계)에 얹고
    /// 그 레이어를 반환한다. 호출자가 직접 애니메이트 후 제거한다.
    /// host는 layer-backed여야 한다(모든 페인 컨테이너는 이미 그렇다).
    public static func overlay(image: NSImage, frame: NSRect, in host: NSView) -> CALayer {
        host.wantsLayer = true
        let layer = CALayer()
        layer.frame = frame
        layer.contents = image
        layer.contentsGravity = .resize
        // Retina에서 또렷하게.
        layer.contentsScale = host.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        layer.zPosition = 100
        host.layer?.addSublayer(layer)
        return layer
    }

    /// 0.16s / easeOut NSAnimationContext 그룹 1회 실행.
    /// `allowsImplicitAnimation = true` 를 켜므로, `body` 안에서 (백킹 레이어 포함)
    /// 레이어 속성을 직접 대입해도 암시적으로 애니메이트된다 — 탭 생성/페인 닫기가
    /// 이 계약에 의존한다(이게 빠지면 스냅된다). `.animator()` 변경에도 동일하게 동작.
    /// `done`은 완료 시 호출된다(오버레이 제거/상태 복원 용).
    public static func run(_ body: () -> Void, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = timing
            ctx.allowsImplicitAnimation = true
            body()
        }, completionHandler: done)
    }
}
```

**Why `allowsImplicitAnimation = true` matters (the load-bearing contract):** with it on, a bare assignment to a layer property inside `body` — e.g. `layer.opacity = 1` or `layer.transform = CATransform3DIdentity` — is implicitly animated over `duration`/`timing` instead of snapping. Tasks 2 (tab create) and 5 (pane close) rely on this: they mutate `layer.opacity`/`layer.transform`/`overlay.position` inside `Motion.run` and expect them to animate. If a manual run shows content snapping instead of animating, this flag is the first thing to check. (Tasks 4 and 6 use explicit `CABasicAnimation` instead — see those tasks for why.)

- [ ] **Step 2: Add the `animations` field to `DamsonConfig`.**

In `Sources/DamsonTerminal/DamsonConfig.swift`, add the stored property right after `cursorBlink` (line 28):

```swift
    public var cursorBlink: Bool
    /// 탭/페인 라이프사이클 모션을 켤지. 기본 ON. macOS Reduce Motion은 이와 무관하게 항상 우선.
    public var animations: Bool
```

Add the init parameter immediately after `cursorBlink: Bool = false,` in the init signature (line 49):

```swift
        cursorBlink: Bool = false,
        animations: Bool = true,
```

Add the assignment immediately after `self.cursorBlink = cursorBlink` in the init body (line 61):

```swift
        self.cursorBlink = cursorBlink
        self.animations = animations
```

- [ ] **Step 3: Add the Settings toggle + the `fromUserDefaults()` read (both live in `SettingsView.swift`).**

This step edits **two distinct pieces of `Sources/halite/SettingsView.swift`**: the SwiftUI `DamsonSettingsView` struct (the `@AppStorage`/`Toggle`/`.onChange`), and the `extension DamsonConfig` (the `fromUserDefaults()` factory) that lives in the **same file** at lines 210–247. Do not relocate the factory — the File Structure table already accounts for both edits being in this one file.

**(a)** Add the `@AppStorage` as a new line 15, immediately after the `cursorBlink` declaration at line 14:

```swift
    @AppStorage("halite.cursorBlink") private var cursorBlink: Bool = false
    @AppStorage("halite.animations") private var animations: Bool = true
```

**(b)** Add the `Toggle` in the `Section("Cursor")` block, on a new line right after `Toggle("Blink", isOn: $cursorBlink)` at line 99:

```swift
                Toggle("Blink", isOn: $cursorBlink)
                Toggle("Animations", isOn: $animations)
```

**(c)** Add the `.onChange` on a new line right after the `cursorBlink` one at line 123:

```swift
        .onChange(of: cursorBlink) { _ in postChanged() }
        .onChange(of: animations) { _ in postChanged() }
```

**(d)** In the `extension DamsonConfig`'s `fromUserDefaults()` (in this same file), add the read right after the `cursorBlink` read at line 229. **Use `object(forKey:) as? Bool ?? true`, NOT `d.bool(forKey:)`** — `animations` defaults to **true**, and `d.bool(forKey:)` returns `false` for an absent key, which would make the default OFF (the opposite of the spec):

```swift
        config.cursorBlink = d.bool(forKey: "halite.cursorBlink")
        config.animations = d.object(forKey: "halite.animations") as? Bool ?? true
```

- [ ] **Step 4: Create the gating + snapshot unit tests.**

Create `Tests/DamsonTerminalTests/MotionTests.swift` with this exact content:

```swift
import XCTest
import AppKit
@testable import DamsonTerminal

final class MotionTests: XCTestCase {

    // MARK: enabled gate truth table (pure function — no UserDefaults/NSWorkspace mocking)

    func testEnabledWhenToggleOnAndReduceMotionOff() {
        XCTAssertTrue(Motion.isEnabled(toggledOn: true, reduceMotionEnabled: false))
    }

    func testDisabledWhenToggleOff() {
        XCTAssertFalse(Motion.isEnabled(toggledOn: false, reduceMotionEnabled: false))
    }

    func testReduceMotionWinsOverToggleOn() {
        // Reduce Motion이 토글보다 우선해 모션을 막아야 한다.
        XCTAssertFalse(Motion.isEnabled(toggledOn: true, reduceMotionEnabled: true))
    }

    func testDisabledWhenBothOff() {
        XCTAssertFalse(Motion.isEnabled(toggledOn: false, reduceMotionEnabled: true))
    }

    // MARK: snapshot

    func testSnapshotReturnsImageForSizedView() {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        view.wantsLayer = true
        XCTAssertNotNil(Motion.snapshot(of: view))
    }

    func testSnapshotReturnsNilForZeroSizeView() {
        let view = NSView(frame: .zero)
        XCTAssertNil(Motion.snapshot(of: view))
    }

    // MARK: timing constants

    func testTimingConstants() {
        XCTAssertEqual(Motion.duration, 0.16, accuracy: 0.0001)
    }
}
```

- [ ] **Step 5: Add the field-default assertion to the existing config test.**

In `Tests/DamsonTerminalTests/DamsonTerminalTests.swift`, inside `testConfigDefaults()`, add one line after the last assertion (the `XCTAssertFalse(config.argv.isEmpty)` at line 18) to verify the new field defaults to `true`:

```swift
        XCTAssertFalse(config.argv.isEmpty)
        XCTAssertTrue(config.animations)
```

- [ ] **Step 6: Build and run the tests; confirm expected output.**

Run from `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`:

```bash
swift build
```

Expected: `Build complete!` with no errors or warnings about `Motion`/`animations`.

```bash
swift test --filter MotionTests
```

Expected: 7 tests, all passing — ends with `Test Suite 'MotionTests' passed` and `Executed 7 tests, with 0 failures`.

```bash
swift test --filter DamsonTerminalTests
```

Expected: the full DamsonTerminal target passes, including the updated `testConfigDefaults` (now asserting `config.animations == true`) — `Executed N tests, with 0 failures` (N is the prior count + the new MotionTests).

- [ ] **Step 7: Manual smoke check of the toggle (optional but quick).**

```bash
HALITE_NO_TRAMPOLINE=1 .build/debug/halite
```

Open Settings (Cmd+,) → Cursor section → confirm the new **Animations** toggle appears, defaults **ON**, and persists across relaunch. No animation behavior changes yet (expected — callers are wired in Task 2). Quit with `Cmd+Q` (or `killall halite`).

- [ ] **Step 8: Commit.**

```bash
git add Sources/DamsonTerminal/Motion.swift Sources/DamsonTerminal/DamsonConfig.swift Sources/halite/SettingsView.swift Tests/DamsonTerminalTests/MotionTests.swift Tests/DamsonTerminalTests/DamsonTerminalTests.swift
git commit -m "Motion core + animations setting (no behavior change)

Add shared Motion helper (enabled gate honoring halite.animations + macOS
Reduce Motion, duration 0.16/easeOut, snapshot/overlay/run with
allowsImplicitAnimation) in DamsonTerminal so the gate is unit-testable. Add
DamsonConfig.animations (default true) and a Settings toggle mirroring
cursorBlink. No interaction reads Motion.enabled yet; toggle persists with no
visible effect until callers are wired."
```

**Verification before claiming done:** `swift build` succeeds, `swift test --filter DamsonTerminalTests` reports 0 failures, and the new toggle appears in Settings. Motion is unused by production code at this point — that is the intended end state of Task 1.

---

## Task 2: Tab create — new PaneTreeView content fades + scales in

Animate the **tab-create** interaction: when a brand-new tab's `PaneTreeView` is shown, its backing layer fades in (`opacity` 0→1) and scales up (`transform` 0.98→1.0) over 0.16s easeOut. All other `selectTab` paths (keyboard nav, tab-bar click, close-show-next, session restore) stay instant and byte-identical to today.

Depends on **Task 1** (`Sources/DamsonTerminal/Motion.swift` with `Motion.enabled`, `Motion.run`, `Motion.duration`, `Motion.timing`; `Motion.run` enables `allowsImplicitAnimation`, which this task's bare `layer.opacity`/`layer.transform` mutations rely on). This task adds NO new imports — `CompactWindowController.swift` already has `import AppKit` and `import DamsonTerminal`, so `Motion.*` and `CATransform3D*` resolve.

**Why `Motion.run` (implicit animation) here, vs. explicit `CABasicAnimation` for tab close (Task 4):** tab-create animates the **backing layer of an NSView** (`tree.layer`), which `Motion.run`'s `allowsImplicitAnimation` drives directly when you assign `layer.opacity`/`layer.transform`. Tab close (Task 4) animates a **free-standing detached `CALayer`** (a snapshot overlay with no NSView, hence no `.animator()` proxy), so it uses an explicit `CABasicAnimation` instead. The two patterns differ because the layer types differ; both source duration/timing from `Motion`.

**Files:**
- Modify: `Sources/halite/CompactWindowController.swift`
  - Add `enum TabTransition` (new, near top of file, immediately after the `Tab` struct's closing brace at line 16) — define **all three cases** now (`.none`, `.create`, `.switch(fromIndex:)`) so Task 6 only *uses* it and never redeclares it (unused enum cases produce no warning).
  - `selectTab(_ index: Int)` → `selectTab(_ index: Int, transition: TabTransition = .none)` (line 171); add an unconditional reset block + a create-animation branch after constraints/first-responder/`refreshTabBar()` are done.
  - `addTab(tree: PaneTreeView)` → `addTab(tree: PaneTreeView, transition: TabTransition = .none)` (line 147); forward `transition` into its `selectTab(tabs.count - 1)` call (line 167).
  - `addNewTab()` (lines 139-144) → pass `.create` into `addTab` (line 142).
  - Restore loop (line 65) and all other `selectTab` callers (68, 103, 222, 265, 271, 279) keep the default `.none` — no edits to those lines in this task.
- Test: **None automated.** `selectTab` lives in the `halite` executable target, which no SwiftPM test target depends on (Package.swift: `DamsonTerminalTests`→`DamsonTerminal`, `DamsonControlTests`→`DamsonControl` only), so it cannot be unit-tested. Verification for this task is `swift build` + manual run + manual disabled-path check (Steps 5–6). Do NOT add a `selectTab` test to `MotionTests.swift` — it will not compile.

---

- [ ] **Step 1 — Add the `TabTransition` enum.**

  Open `Sources/halite/CompactWindowController.swift`. Insert the enum **immediately after the closing brace of the `private struct Tab { … }` block** (the brace at line 16), so it sits adjacent to the other tab-related declarations. Define **all three cases** now (Tasks 4 and 6 reuse this same declaration without redefining it; the `.switch(fromIndex:)` case is unused until Task 6, and unused enum cases produce no warning).

  The full merged result — the `Tab` struct closing, then the `TabTransition` enum opening on the next line, then the existing `tabs`/`currentIndex` properties — reads:

  ```swift
      private struct Tab {
          let tree: PaneTreeView
          var titleSub: AnyCancellable
      }

      /// Animation intent threaded through `selectTab` / `addTab`. `.none` = instant
      /// (today's behavior; restore, keyboard nav, tab-bar click, close-show-next).
      /// `.create` = a brand-new tab's content fades + scales in (Task 2).
      /// `.switch(fromIndex:)` = the tab-switch crossfade/slide (Task 6); carries the
      /// index we came **from** so the slide direction follows the index sign.
      private enum TabTransition {
          case none
          case create
          case `switch`(fromIndex: Int)
      }
      private var tabs: [Tab] = []
      private(set) var currentIndex: Int = 0
  ```

  (`switch` is a Swift keyword, so the case name is backtick-escaped: `` `switch` ``. At call sites it is written `.switch(fromIndex:)` with no backticks — the leading `.` disambiguates it.)

- [ ] **Step 2 — Thread `transition` through `addTab` and `addNewTab`.**

  Change the `addTab` signature to accept a defaulted `transition` and forward it into its `selectTab` call. Replace the signature line:

  ```swift
      private func addTab(tree: PaneTreeView) {
  ```

  with:

  ```swift
      private func addTab(tree: PaneTreeView, transition: TabTransition = .none) {
  ```

  Then replace the `selectTab(tabs.count - 1)` call inside `addTab`:

  ```swift
          tabs.append(Tab(tree: tree, titleSub: titleSub))
          selectTab(tabs.count - 1)
          refreshTabBar()
  ```

  with:

  ```swift
          tabs.append(Tab(tree: tree, titleSub: titleSub))
          selectTab(tabs.count - 1, transition: transition)
          refreshTabBar()
  ```

  Now make `addNewTab()` request the create animation. Replace its body:

  ```swift
      @discardableResult
      func addNewTab() -> DamsonSession {
          let session = DamsonSession(config: DamsonConfig.fromUserDefaults())
          addTab(tree: PaneTreeView(rootSession: session))
          return session
      }
  ```

  with:

  ```swift
      @discardableResult
      func addNewTab() -> DamsonSession {
          let session = DamsonSession(config: DamsonConfig.fromUserDefaults())
          addTab(tree: PaneTreeView(rootSession: session), transition: .create)
          return session
      }
  ```

  Do NOT touch the restore loop (`addTab(tree: PaneTreeView(restoredRoot: root))`) — it keeps the default `.none`, so restored tabs appear instantly on launch.

- [ ] **Step 3 — Add the `transition` parameter + create-animation branch to `selectTab`.**

  Replace the signature line:

  ```swift
      func selectTab(_ index: Int) {
  ```

  with:

  ```swift
      func selectTab(_ index: Int, transition: TabTransition = .none) {
  ```

  Then, inside `selectTab`, after the first-responder / title / `refreshTabBar()` block, append the animation logic. Replace the current tail of the method:

  ```swift
          if case .leaf(_, let surface) = tree.activeLeaf.kind {
              window?.makeFirstResponder(surface)
          }
          if let firstSession = tree.root.leaves().first?.session {
              let title = firstSession.title
              window?.title = title.isEmpty ? "halite" : title
          }
          refreshTabBar()
      }
  ```

  with:

  ```swift
          if case .leaf(_, let surface) = tree.activeLeaf.kind {
              window?.makeFirstResponder(surface)
          }
          if let firstSession = tree.root.leaves().first?.session {
              let title = firstSession.title
              window?.title = title.isEmpty ? "halite" : title
          }
          refreshTabBar()

          // The incoming tree may carry a leftover from-state if a prior create
          // animation on this same view was superseded. Reset to the final visual
          // state unconditionally; the `.create` branch below re-applies the
          // from-state. Keeps the non-animated path identical to today.
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          tree.layer?.opacity = 1
          tree.layer?.transform = CATransform3DIdentity
          CATransaction.commit()

          if case .create = transition, Motion.enabled {
              animateTabCreate(tree)
          }
      }

      /// Tab-create motion (Task 2): the new tab's content fades + scales in.
      /// `opacity` 0→1 and `transform` 0.98→1.0 over `Motion.duration` easeOut.
      /// The tree already holds its final frame (constraints active); the transform
      /// is purely visual → zero surface reflow.
      private func animateTabCreate(_ tree: PaneTreeView) {
          // Final frame must exist before we read layer.bounds for the
          // center-composed scale; force a layout pass first.
          contentContainer.layoutSubtreeIfNeeded()
          guard let layer = tree.layer,
                layer.bounds.width > 0, layer.bounds.height > 0 else {
              // Zero-size (e.g. first tab before the window is shown) — skip motion.
              // This is NORMAL and CORRECT: the unconditional reset block above already
              // set the tree to opacity 1 / identity transform, so the tab ends at its
              // final visual state — just without an animation. Not a bug.
              return
          }

          // Center-composed scale: correct for ANY layer anchorPoint (a layer-backed
          // NSView's anchorPoint is not reliably 0.5,0.5; a plain MakeScale would
          // drift toward a corner instead of popping from the center).
          let s: CGFloat = 0.98
          let w = layer.bounds.width
          let h = layer.bounds.height
          let ap = layer.anchorPoint
          let v = CGPoint(x: w * (0.5 - ap.x), y: h * (0.5 - ap.y))
          let fromTransform = CATransform3DConcat(
              CATransform3DConcat(
                  CATransform3DMakeTranslation(-v.x, -v.y, 0),
                  CATransform3DMakeScale(s, s, 1)
              ),
              CATransform3DMakeTranslation(v.x, v.y, 0)
          )

          // Instantly set the FROM-state (no implicit animation here).
          CATransaction.begin()
          CATransaction.setDisableActions(true)
          layer.opacity = 0
          layer.transform = fromTransform
          CATransaction.commit()

          // Animate TO the final state inside the shared 0.16s easeOut group.
          // Motion.run sets allowsImplicitAnimation = true, so these bare layer
          // assignments animate implicitly (see Task 1 Step 1's contract note).
          Motion.run({
              layer.opacity = 1
              layer.transform = CATransform3DIdentity
          }, done: {
              // Guarantee the resting state even if the run was interrupted.
              CATransaction.begin()
              CATransaction.setDisableActions(true)
              layer.opacity = 1
              layer.transform = CATransform3DIdentity
              CATransaction.commit()
          })
      }
  ```

  Notes baked in:
  - `Motion.enabled` is checked at the call site (in `selectTab`) — when `false`, `animateTabCreate` is never called and the tree stays at its just-reset opaque/identity state. Disabled path = today's behavior, reached synchronously.
  - The unconditional reset block above the `.create` check protects against a superseded create animation leaving a tab dim/scaled when the user rapidly switches tabs (rapid `Cmd+T` then nav).
  - The from-state is set under `CATransaction.setDisableActions(true)` so it snaps and does not itself animate.
  - The zero-size guard is normal and correct (first tab before the window is shown): the tree ends at its final opaque/identity state, just without an animation.
  - `Motion.run` (Task 1) opens an `NSAnimationContext` group with `allowsImplicitAnimation = true`; the bare `layer.opacity` / `layer.transform` assignments inside `body` are therefore implicitly animated. That flag is the load-bearing contract — if Step 6 shows content snapping instead of animating, confirm Task 1's `Motion.run` still sets it.

- [ ] **Step 4 — Build.**

  ```bash
  swift build
  ```

  Expected: `Build complete!` with no errors and no new warnings. (The `.switch(fromIndex:)` enum case is intentionally unused this task and does not warn.)

- [ ] **Step 5 — Manual verification: animation ON (the create motion).**

  ```bash
  killall halite 2>/dev/null; HALITE_NO_TRAMPOLINE=1 .build/debug/halite
  ```

  Then, in the running app:
  1. The first tab opens at launch — it may appear instantly (zero-size guard before the window is shown) or with a faint pop; either is acceptable.
  2. Press `Cmd+T` to create a new tab. **Look for:** the new tab's terminal content fades in (starts faint) and scales up very slightly (from ~98% to 100%) over a brief ~0.16s, settling crisp at full frame. It must be subtle — a gentle pop, not a zoom.
  3. Type immediately after `Cmd+T` (before the motion finishes). **Confirm:** keystrokes land in the new tab — first responder is set before the animation, so typing works mid-animation.
  4. Spam `Cmd+T` several times fast, then click around / use `Cmd+Shift+]` to switch tabs. **Confirm:** no tab is left dimmed or shrunk; every tab you land on is fully opaque at full frame (the unconditional reset + `done` handler guarantee this).

  Leave the app running for Step 6, or `killall halite` and relaunch.

- [ ] **Step 6 — Manual verification: animation OFF (disabled-path end-state unchanged).**

  Disable motion via macOS Reduce Motion (honored regardless of the settings toggle): System Settings → Accessibility → Display → **Reduce motion = ON**. Then relaunch:

  ```bash
  killall halite 2>/dev/null; HALITE_NO_TRAMPOLINE=1 .build/debug/halite
  ```

  Press `Cmd+T`. **Assert the create end-state is byte-identical to today:**
  - The new tab's content appears **instantly** at full frame — no fade, no scale, no overlay or transform left behind.
  - The active surface is first responder (type immediately — keystrokes land).
  - The window title updates to the new tab's title.
  - The tab bar shows the new tab selected.

  All reached synchronously. Then re-test the settings toggle path: turn Reduce Motion back **OFF**, open halite Settings, toggle **Animations OFF**, and press `Cmd+T` — content must again appear instantly (toggle gates `Motion.enabled` too). Restore Reduce Motion to your normal preference and re-enable the Animations toggle when done.

  ```bash
  killall halite
  ```

- [ ] **Step 7 — Commit.**

  ```bash
  git add Sources/halite/CompactWindowController.swift
  git commit -m "Tab create animation: new tab content fades + scales in

Thread a TabTransition intent through addTab/selectTab. addNewTab passes
.create so a brand-new PaneTreeView fades (opacity 0->1) and scales
(transform 0.98->1.0) in over Motion.duration easeOut. Restore, keyboard
nav, tab-bar click, and close-show-next keep the default .none and stay
instant. Gated by Motion.enabled (settings toggle AND Reduce Motion);
disabled path is byte-identical to prior behavior."
  ```

  Expected: one commit on the current feature branch touching only `Sources/halite/CompactWindowController.swift`.

---

## Task 3: Pane split — new pane opens from the divider (transform + opacity)

When the user splits a pane (`Cmd+D` horizontal / `Cmd+Shift+D` vertical), the existing pane snaps to its half-frame in a single reflow (unchanged behavior), and the **new** pane's `PaneLeafWrapper` — already pinned at its final half-frame — animates in: its `layer.transform` starts translated a small nudge *toward the divider* and settles to identity while `opacity` goes 0→1. The result reads as "the new pane opens from the split line." This is a pure visual layer animation on the new wrapper — **zero reflow** of any live surface (Approach A).

Gating: `split(direction:)` reads `Motion.enabled` LIVE. When `false` (toggle off OR macOS Reduce Motion on), it calls `rebuild(animation: .none)` — byte-for-byte the current instant code path. Pane split is live-transform only (no snapshot), so the only gate is `Motion.enabled`; there is no snapshot-nil fallback to consider for this interaction.

**Depends on:** Task 1 (`Motion` in the DamsonTerminal library — `Motion.enabled`, `Motion.duration`, `Motion.timing`) and Task 2 (tab-create animation; establishes the live-transform pattern). `PaneTreeView.swift` already has `import AppKit` and `import DamsonTerminal` (lines 1–2), so `Motion.x` resolves with **no new imports**.

**Files:**
- Modify `Sources/halite/PaneTreeView.swift`
  - Add a `PaneAnimation` enum **nested `private` inside `PaneTreeView`** (so Task 5 can extend it in the same place with no access-modifier drift). Task 3 defines cases `.none` and `.split(newLeaf:)`; Task 5 will extend it with a `.close(...)` case and add a `ClosingEdge` enum.
  - Change `split(direction:)` (currently ends `rebuild()` at line 68) to gate on `Motion.enabled` and pass `.split(newLeaf:)` into `rebuild`.
  - Change `rebuild()` (currently lines 148–156) to `rebuild(animation: PaneAnimation = .none)` and dispatch to the split animation after the subviews are rebuilt.
  - Add two private helpers to `PaneTreeView`: `findWrapper(for:in:)` (locate the new wrapper post-rebuild by `leaf === newLeaf`) and `animateSplitIn(newLeaf:direction:)` (force layout, run the transform+opacity animation). Place them in a new `// MARK: - Split/Close animation helpers` region, right after `addSubviewsForNode` ends (after line 188, before the `// MARK: - Border 색 갱신` comment at line 190). **These two helpers are defined here once; Task 5 reuses them by name from this same marked region and does NOT re-declare them.**
  - `PaneLeafWrapper` (lines 212–240) already sets `wantsLayer = true` in `init` (line 223), so `wrapper.layer` is non-nil — no change needed there.
- Test: No automated test for this task. Pane-split motion is visual/timing and is verified **manually** per the design spec (§Testing, "Motion is visual/timing — verified manually"). The gating truth-table (`Motion.isEnabled`) is already covered by `Tests/DamsonTerminalTests/MotionTests.swift` from Task 1. This task adds a precise manual-verification step plus an assertion that the disabled path's final view hierarchy is unchanged.

---

- [ ] **Step 1 — Add the `PaneAnimation` enum (nested, private).**

  Open `Sources/halite/PaneTreeView.swift`. Inside the `PaneTreeView` class body, near the top (right after the `onAllPanesClosed` property at line 16, before the first `init`), insert:

  ```swift
      /// Pane lifecycle animation intent threaded through `rebuild`. `.none` is the
      /// instant/legacy path; `.split` animates the newly-created pane in from the
      /// divider edge. (`.close` is added in Task 5 — do not add it here.)
      private enum PaneAnimation {
          case none
          /// After rebuild, find the wrapper whose leaf === `newLeaf` and animate it in.
          case split(newLeaf: PaneNode)
      }
  ```

  Why nested + `private`: `PaneAnimation` is only used inside `PaneTreeView`, and Task 5 extends it here too — nesting it `private` fixes the location/modifier once so the two tasks never disagree. Why a tree-node payload and not a frame: the wrapper's final half-frame isn't known until the post-rebuild layout pass (`SplitContainer.layout()` computes it). Carrying the `newLeaf` reference lets `rebuild` find the freshly-built wrapper by identity (`wrapper.leaf === newLeaf`) after layout settles.

- [ ] **Step 2 — Gate `split(direction:)` and thread the intent into `rebuild`.**

  Replace the body's final two statements of `split(direction:)`. The current method ends with:

  ```swift
          activeLeaf = newLeaf
          rebuild()
  ```

  Replace those two lines with:

  ```swift
          activeLeaf = newLeaf
          // Animate the new pane in only when motion is enabled (live transform,
          // no snapshot → the only gate is Motion.enabled). Otherwise the instant
          // path (rebuild(animation: .none)) — identical end state to today.
          rebuild(animation: Motion.enabled ? .split(newLeaf: newLeaf) : .none)
  ```

  Everything above `activeLeaf = newLeaf` (the guard, session creation, `oldLeafCopy`, the `activeLeaf.kind = .split(...)` mutation) is unchanged — the new pane is always `second` in the split, exactly as today.

- [ ] **Step 3 — Make `rebuild` accept the animation intent and dispatch after rebuild.**

  Replace the entire current `rebuild()` method (lines 148–156):

  ```swift
      private func rebuild() {
          for sub in subviews { sub.removeFromSuperview() }
          addSubviewsForNode(root, into: self)
          updateBorderColors()
          if case .leaf(_, let surface) = activeLeaf.kind {
              window?.makeFirstResponder(surface)
          }
          needsLayout = true
      }
  ```

  with:

  ```swift
      private func rebuild(animation: PaneAnimation = .none) {
          for sub in subviews { sub.removeFromSuperview() }
          addSubviewsForNode(root, into: self)
          updateBorderColors()
          if case .leaf(_, let surface) = activeLeaf.kind {
              window?.makeFirstResponder(surface)
          }
          needsLayout = true

          // Animate the appearing pane AFTER the new hierarchy + first responder
          // are in their final state (focus/typing already works mid-animation).
          switch animation {
          case .none:
              break
          case .split(let newLeaf):
              // Determine which axis to nudge along from the new leaf's parent split.
              guard let parent = newLeaf.parent,
                    case .split(let dir, _, _, _) = parent.kind
              else { break }
              animateSplitIn(newLeaf: newLeaf, direction: dir)
          }
      }
  ```

  The default `animation: .none` keeps every existing caller (the two `init`s, `closeActive()`) compiling and behaving exactly as before — they invoke `rebuild()` with no argument and hit the `.none` path. (Task 5 extends this `switch` with a `.close` case.)

- [ ] **Step 4 — Add the wrapper finder + the split-in animation helpers.**

  Insert the following two private methods into `PaneTreeView`, in a new `// MARK: - Split/Close animation helpers` region, right after `addSubviewsForNode(_:into:)` ends (after line 188, before the `// MARK: - Border 색 갱신` comment at line 190). **These are the canonical definitions in a region Task 5 references by name — Task 5 calls them and must not re-declare them.**

  ```swift
      // MARK: - Split/Close animation helpers

      /// Recursively find the `PaneLeafWrapper` whose `leaf` is identical (===) to
      /// `target`. Walks the freshly-rebuilt subtree; returns nil if not found.
      /// Used by both the split-in (Task 3) and close (Task 5) animations.
      private func findWrapper(for target: PaneNode, in view: NSView) -> PaneLeafWrapper? {
          if let w = view as? PaneLeafWrapper, w.leaf === target {
              return w
          }
          for sub in view.subviews {
              if let found = findWrapper(for: target, in: sub) { return found }
          }
          return nil
      }

      /// Animate the new pane "opening from the split line": its wrapper is already
      /// at the final half-frame, so we animate the wrapper's `layer.transform` from
      /// a small nudge toward the divider back to identity, plus opacity 0→1.
      /// Pure visual layer animation — the live surface is never resized (no reflow).
      private func animateSplitIn(newLeaf: PaneNode, direction: SplitDirection) {
          // The wrapper's final half-frame is computed by SplitContainer.layout(),
          // which only runs during a layout pass. Force it now so wrapper.bounds is
          // final before we read it.
          layoutSubtreeIfNeeded()

          guard let wrapper = findWrapper(for: newLeaf, in: self),
                let layer = wrapper.layer,
                wrapper.bounds.width > 0, wrapper.bounds.height > 0
          else { return }

          // Small "nudge", not a full traverse, to keep the motion subtle.
          // The new pane is always `second`: right of the divider (horizontal) or
          // below it (vertical). All views here are non-flipped (y grows upward),
          // matching SplitContainer.layout()'s bottom-up coordinate comments.
          let fromTransform: CATransform3D
          switch direction {
          case .horizontal:
              // New pane sits to the RIGHT of the divider → start nudged LEFT
              // (toward the divider, -x) and settle right into place.
              let dx = -min(24, wrapper.bounds.width * 0.06)
              fromTransform = CATransform3DMakeTranslation(dx, 0, 0)
          case .vertical:
              // New pane sits BELOW the divider (lower y in bottom-up coords) →
              // start nudged UP toward the divider (+y) and settle down into place.
              let dy = min(24, wrapper.bounds.height * 0.06)
              fromTransform = CATransform3DMakeTranslation(0, dy, 0)
          }

          // Set the final state on the MODEL layer first, then add explicit
          // "from → identity" animations (same idiom as the bell-flash
          // CABasicAnimation in DamsonTerminalView). The model values are at their
          // final identity/1.0 state BEFORE add(), so when the animation finishes
          // (or is removed) the layer rests where it already is. Driven by
          // Motion.duration / Motion.timing only.
          layer.transform = CATransform3DIdentity
          layer.opacity = 1.0

          let move = CABasicAnimation(keyPath: "transform")
          move.fromValue = NSValue(caTransform3D: fromTransform)
          move.toValue = NSValue(caTransform3D: CATransform3DIdentity)

          let fade = CABasicAnimation(keyPath: "opacity")
          fade.fromValue = 0.0
          fade.toValue = 1.0

          let group = CAAnimationGroup()
          group.animations = [move, fade]
          group.duration = Motion.duration
          group.timingFunction = Motion.timing
          // No removal/cleanup needed: animations are non-additive and the layer's
          // model values are already at their final identity/1.0 state, so when the
          // animation finishes the wrapper simply rests where it already is. Safe
          // under rapid splits — a later rebuild() nukes & rebuilds the subtree,
          // discarding any in-flight animation with its (removed) wrapper.
          layer.add(group, forKey: "halite.split-in")
      }
  ```

  Notes that make this correct and self-contained:
  - `PaneLeafWrapper` and `SplitContainer` are `private` to this file, which is exactly why `findWrapper` must live here on `PaneTreeView` (it can see `PaneLeafWrapper`). The existing `moveFocus` (lines 110–115) already walks for `PaneLeafWrapper` the same way — this mirrors that pattern.
  - `layoutSubtreeIfNeeded()` is required because `rebuild()` only sets `needsLayout = true`; without forcing layout, `wrapper.bounds` would still be `container.bounds` from `addSubviewsForNode` (the full pre-split size), not the half-frame, and the nudge would be computed off the wrong dimension.
  - The transform animates the **wrapper's** layer, which contains the surface; the surface itself is never re-framed, so no SIGWINCH / reflow fires during the animation.
  - **Why set the model value BEFORE `add()`:** a `CABasicAnimation` only animates the *presentation* layer; when it completes (or is removed), the layer snaps to its **model** value. Committing `layer.transform = identity` / `layer.opacity = 1` before adding the animation guarantees the wrapper rests at the correct final state.

- [ ] **Step 5 — Build. Expected: clean build.**

  Run from `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`:

  ```bash
  swift build
  ```

  Expected result: `Build complete!` with no errors or warnings. If `Motion` is "cannot find in scope," Task 1 (Motion.swift in the DamsonTerminal library) is not yet in place — that is a prerequisite, not a Task 3 bug.

- [ ] **Step 6 — Run the unit tests. Expected: existing Motion gating tests still green.**

  ```bash
  swift test --filter DamsonTerminalTests
  ```

  Expected result: all tests pass, including `MotionTests` from Task 1 (the `Motion.isEnabled` truth table). Task 3 adds no new automated tests (pane-split motion is visual), so the count is unchanged from Task 2. This step confirms Task 3 did not regress the library or the gating logic.

- [ ] **Step 7 — MANUAL verification: animation ON (the happy path).**

  Build then launch the app directly (bypassing the IME trampoline for dev iteration):

  ```bash
  swift build && HALITE_NO_TRAMPOLINE=1 .build/debug/halite
  ```

  In the running app, with the default settings (Animations toggle ON, macOS Reduce Motion OFF — verify in System Settings → Accessibility → Display → "Reduce motion" is OFF):
  1. Press `Cmd+D` (horizontal split). **Look for:** the new pane on the **right** appears to slide in a few points from the divider (leftward origin) while fading from transparent to opaque over ~0.16s; the left (existing) pane snaps to half-width in one step with no continuous resize/flicker. The terminal shell in the existing pane does not visibly reflow/redraw repeatedly.
  2. Press `Cmd+Shift+D` (vertical split). **Look for:** the new pane **below** the divider slides in a few points downward (from the divider) + fades in; the top pane snaps to half-height.
  3. Type immediately after a split. **Look for:** keystrokes land in the new (active) pane during/right after the animation — focus is on the final pane, not delayed by the animation.
  4. Spam `Cmd+D` / `Cmd+Shift+D` rapidly several times. **Look for:** no stuck/translucent/offset panes left behind; every pane ends at full opacity and correct position. (Each `rebuild` nukes & rebuilds the subtree, discarding in-flight animations on removed wrappers.)

- [ ] **Step 8 — MANUAL verification: animation OFF → disabled path is identical to today.**

  Quit the app (`Cmd+Q`). Disable animations one of two ways, then relaunch and split:

  - **Via the in-app toggle** (added in Task 1): open Settings, turn the **Animations** toggle OFF, then split. OR
  - **Via macOS Reduce Motion** (proves Reduce Motion wins regardless of the toggle): System Settings → Accessibility → Display → turn **"Reduce motion" ON**, relaunch the app, then split.

  ```bash
  swift build && HALITE_NO_TRAMPOLINE=1 .build/debug/halite
  ```

  **Assert the disabled end-state is unchanged from current `main`:**
  1. Press `Cmd+D` and `Cmd+Shift+D`. **Look for:** the new pane appears **instantly** at its final half-frame — no slide, no fade, no transform. This is the `rebuild(animation: .none)` path, which is the exact pre-Task-3 code.
  2. The split geometry (divider position, 1pt active border on the new pane, surface inset) is byte-for-byte what `main` produces — both panes are full-opacity and correctly sized immediately.
  3. Typing goes to the new active pane immediately, same as before.
  4. Re-enable animations / turn Reduce Motion back OFF afterward so later tasks verify against the default-ON state.

- [ ] **Step 9 — Commit.**

  From `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`:

  ```bash
  git add Sources/halite/PaneTreeView.swift
  git commit -m "Pane split: animate new pane opening from the divider

New pane wrapper sits at its final half-frame and animates layer.transform
(nudged from the divider edge -> identity) + opacity 0->1 over Motion.duration
/easeOut. Existing pane snaps in one reflow (Approach A — no live-surface
resize). Gated on Motion.enabled; disabled path is the unchanged instant
rebuild(animation: .none)."
  ```

  (Per repo convention, commit only when the user asks; this step is the natural stopping point for Task 3. `Sources/halite/PaneTree.swift` is unchanged — do not stage it.)

---

## Task 4: Tab close — snapshot overlay slides down + fades out

This task animates **tab close** (clicking the X on a tab in the tab bar). When the **currently-visible** tab is closed, we snapshot its content, drop a self-removing overlay on top, swap the underlying tree to the next tab live (instant), then slide the overlay **down** (~6% of its height) while fading it out, then remove it. The next tab is visible underneath the whole time, so the motion reads as "the closed tab falls away to reveal the next one".

Only the **content area** animates (per spec scope) — the tab-bar button itself is removed instantly by `refreshTabBar()`, which is out of scope.

**Depends on:** Task 1 (`Motion` core — `Motion.enabled`, `Motion.snapshot(of:)`, `Motion.overlay(image:frame:in:)`, `Motion.duration`, `Motion.timing`) and Task 2 (which introduced the `TabTransition` enum + the `selectTab(_:transition:)` signature).
**Independent of:** Task 2's `.create`/Task 6's `.switch` behavior — this task calls `selectTab(currentIndex)` with the **default `.none`** transition (the next tab is shown instantly; only the snapshot moves), so it does not depend on, and must not pass, a `.switch`/`.create` transition.

**Why an explicit `CABasicAnimation` (not `Motion.run`):** `Motion.overlay` returns a **detached** `CALayer` added via `host.layer?.addSublayer(...)` (it is *not* an NSView's backing layer, so it has no `.animator()` proxy). For a free-standing sublayer the robust, in-house idiom is an explicit `CABasicAnimation` — exactly what `DamsonTerminalView.handleBell()` (lines 283–301) already does for its flash overlay. We reuse that idiom here, but source the duration/timing from `Motion.duration` / `Motion.timing` (never hardcoded `0.16` / `.easeOut` at the call site). `Motion.run` (implicit animation via `allowsImplicitAnimation`) remains the right tool for the *view*-backing-layer tasks (tab create/switch live layer); it is intentionally not used for this detached-layer slide. This architectural split — implicit animation for view-backing layers, explicit `CABasicAnimation` for detached overlay layers — is consistent across the whole plan.

**Files:**
- Modify: `Sources/halite/CompactWindowController.swift`
  - `setupViews()` (lines 110–112): add `contentContainer.wantsLayer = true` so the overlay's host is already layer-backed (avoids a first-time backing-switch hiccup mid-close).
  - `closeTab(_:)` (lines 212–223): capture+overlay the closing tab content **before** teardown, gate on visibility, animate the overlay out **after** `selectTab`.
- Test: none. `CompactWindowController` lives in the `halite` **executable** target, which has no test target (Package.swift lines 62–71; same reason `Motion` lives in `DamsonTerminal` — see Task 1's placement note). The non-visual gate logic is covered by `MotionTests` (Task 1); this task's behavior is **visual/timing**, verified manually per the spec's Testing section.

---

- [ ] **Step 1: Make `contentContainer` layer-backed in `setupViews()`**

The overlay host must be layer-backed before we drop a sublayer into it. `Motion.overlay` sets `wantsLayer = true` on demand, but flipping the backing on for the first time *during* the close can hiccup; set it up front. Its only child (the `PaneTreeView` tree) is already layer-backed, so there is no text-antialiasing regression.

In `Sources/halite/CompactWindowController.swift`, in `setupViews()`, find the `contentContainer` creation block (currently lines 110–112):

```swift
        // 세션 surface가 들어가는 컨테이너 — 탭 바 아래 채움.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(contentContainer)
```

Add `wantsLayer` right after the `translatesAutoresizingMaskIntoConstraints` line:

```swift
        // 세션 surface가 들어가는 컨테이너 — 탭 바 아래 채움.
        contentContainer = NSView()
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        // 탭 닫기 애니메이션 오버레이(스냅샷 레이어)의 호스트 — 미리 layer-backed로.
        contentContainer.wantsLayer = true
        contentView.addSubview(contentContainer)
```

- [ ] **Step 2: Build to confirm the layer-backing change compiles**

Run: `swift build`
Expected: `Build complete!` with no errors or warnings from the change. (Behavior unchanged so far — `contentContainer` is simply layer-backed now; nothing animates yet.)

- [ ] **Step 3: Replace `closeTab(_:)` with the snapshot-overlay close animation**

In `Sources/halite/CompactWindowController.swift`, replace the entire `closeTab(_:)` method (currently lines 212–223):

```swift
    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }
        tabs[index].tree.root.terminateAll()
        tabs.remove(at: index)

        if tabs.isEmpty {
            window?.performClose(nil)
            return
        }
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        selectTab(currentIndex)
    }
```

with:

```swift
    func closeTab(_ index: Int) {
        guard index >= 0, index < tabs.count else { return }

        // 닫는 탭이 "현재 보이는" 탭이고, 닫은 뒤에도 탭이 남고, 애니메이션이 켜졌고,
        // 스냅샷이 떠질 때만 모션. 그 외(백그라운드 탭 닫기 / 마지막 탭 / 스냅샷 실패 /
        // Reduce Motion / 토글 off)는 기존 즉시 경로 그대로.
        //
        // tabs.count > 1 가드는 remove(at:) "이전"에 검사한다 — 즉 다음 탭이 존재함을 보장.
        // remove(at:) 후 tabs.isEmpty면 그 경로는 여기서 끝(윈도우 종료, 정리할 오버레이 없음).
        // 그렇지 않으면 오버레이 정리 + 다음 탭 선택이 이어진다.
        //
        // 오버레이는 teardown 이전에, 아직 살아있는 닫히는 트리 위에 픽셀 동일하게 올린다.
        // 그래야 selectTab으로 다음 트리를 즉시 교체해도 깜빡임 없이 오버레이가 위를 덮는다.
        var overlay: CALayer?
        if Motion.enabled,
           index == currentIndex,
           tabs.count > 1,
           let image = Motion.snapshot(of: tabs[index].tree) {
            overlay = Motion.overlay(
                image: image,
                frame: contentContainer.bounds,
                in: contentContainer
            )
        }

        tabs[index].tree.root.terminateAll()
        tabs.remove(at: index)

        if tabs.isEmpty {
            // 마지막 탭이 닫힘 — 윈도우 종료(스코프 밖). 위 가드(tabs.count > 1)로 여기엔
            // 오버레이가 절대 만들어지지 않으므로 정리할 것이 없다.
            window?.performClose(nil)
            return
        }
        if currentIndex >= tabs.count { currentIndex = tabs.count - 1 }
        // 다음 탭을 즉시(.none) 라이브로 보여줌. 오버레이가 그 위에서 슬라이드/페이드.
        selectTab(currentIndex)

        guard let overlay else { return }
        // 닫히는 콘텐츠 스냅샷: 아래로(~6% 높이) 미끄러지며 페이드아웃 → 제거.
        // 비-flipped 좌표계라 "아래"는 -y. 분리된 CALayer이므로 (뷰의 .animator()가
        // 없으므로) bell-flash와 동일한 명시적 CABasicAnimation 관용구를 쓴다.
        let dy = overlay.bounds.height * 0.06
        let fromPos = overlay.position
        let toPos = CGPoint(x: fromPos.x, y: fromPos.y - dy)

        let slide = CABasicAnimation(keyPath: "position")
        slide.fromValue = NSValue(point: fromPos)
        slide.toValue = NSValue(point: toPos)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1.0
        fade.toValue = 0.0

        let group = CAAnimationGroup()
        group.animations = [slide, fade]
        group.duration = Motion.duration
        group.timingFunction = Motion.timing
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards

        // 최종 상태를 모델 레이어에도 반영(애니메이션 add 후에 모델값을 최종으로 둬서
        // 애니메이션 종료/제거 시 레이어가 최종 위치/투명도에서 쉰다). 곧 done에서 제거되므로
        // 남은 모델 상태는 무의미하지만, 일관성을 위해 명시.
        overlay.position = toPos
        overlay.opacity = 0
        overlay.add(group, forKey: "tabClose")

        // 애니메이션 후 오버레이 제거. 각 close는 자기 오버레이만 캡처하므로
        // (self를 캡처하지 않음) 빠른 연속 닫기에도 공유 상태 없이 안전.
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.duration) {
            overlay.removeFromSuperlayer()
        }
    }
```

Key correctness points baked in:
- **`index == currentIndex` gate.** `closeTab` is reachable for *any* tab — the tab-bar X button calls `onTabClosed(idx) → closeTab(idx)` for **background** tabs too. A background tab's tree is not in the view hierarchy (stale/zero frame); snapshotting it and sliding it over the visible tab would be a bug. So we animate only when closing the visible tab.
- **`tabs.count > 1` checked before removal.** We check `tabs.count > 1` *before* `remove(at:)` so we know a next tab will exist for the live display. Closing the last tab calls `window?.performClose(nil)` (window close — out of scope); the guard guarantees no overlay is ever created on that path, so nothing is orphaned. After `remove(at:)`, if `tabs.isEmpty`, the path ends (window close, no overlay to clean up). Otherwise, overlay cleanup and next-tab selection proceed.
- **Overlay dropped before `terminateAll()`/`remove`.** The snapshot sits pixel-identical on the still-live closing tree (no flicker); then `selectTab` swaps the underlying tree to the next tab instantly, and the overlay (`zPosition = 100` from `Motion.overlay`) stays on top and slides away to reveal the live next tab. This ordering is the only one that does not flash the new tab in first.
- **`selectTab(currentIndex)` uses the default `.none` transition** — the next tab is instant; only the snapshot moves. Do not pass a `.switch` transition here.
- **Model value set after `add()`.** A `CABasicAnimation` animates only the presentation; on completion/removal the layer snaps to its model value. Setting `position`/`opacity` to the end state after adding the animation keeps the layer resting correctly (moot here since `done` removes it, but consistent with the plan's idiom).
- **No `[weak self]`.** The cleanup closure captures only the local `overlay`, not `self`, so there is no retain cycle and each close owns its own overlay — rapid X-clicks are safe with no shared state.
- **Timing from `Motion`.** `group.duration = Motion.duration` and `group.timingFunction = Motion.timing` — no hardcoded `0.16` / `.easeOut`.

- [ ] **Step 4: Build the whole package**

Run: `swift build`
Expected: `Build complete!` with no errors. (Confirms `Motion.enabled`, `Motion.snapshot(of:)`, and `Motion.overlay(image:frame:in:)` resolve from the `halite` executable via the existing `import DamsonTerminal`, and that `closeTab` still type-checks.)

- [ ] **Step 5: Run the full test suite (confirm nothing regressed)**

Run: `swift test`
Expected: All suites pass (the Task 1 `MotionTests` plus the pre-existing `DamsonTerminalTests` / `DamsonControlTests`), ending with `Test Suite 'All tests' passed`. No tests are added in this task (executable target is untestable); this run only confirms no regression.

- [ ] **Step 6: MANUAL verification — animated path**

Run the app:

```bash
killall halite 2>/dev/null; HALITE_NO_TRAMPOLINE=1 .build/debug/halite
```

(The `HALITE_NO_TRAMPOLINE=1` env var bypasses the IME-prewarming `.app` trampoline for dev iteration; it does not affect animation behavior.)

Then, with **Settings → Animations ON** (default) and **macOS Reduce Motion OFF**:

1. Press **Cmd+T** twice so there are **3 tabs**. Type a distinct command in each (e.g. `echo one`, `echo two`, `echo three`) so the tabs' content is visually distinguishable.
2. Select a middle tab so it is the **current/visible** tab. Click the **X** on that **current** tab in the tab bar.
   - **Expect:** the closed tab's content **slides down ~6% of its height and fades out** over ~0.16s; the **next tab's live content is visible underneath** the whole time and remains in place (it does **not** itself animate). The motion eases out (decelerates), not linear. No flicker of the new tab appearing first.
3. Click the **X** on a **non-current (background)** tab.
   - **Expect:** the content area does **NOT** animate at all — the visible tab stays put and the background tab simply disappears from the tab bar. (This verifies the `index == currentIndex` gate.)
4. Spam-close: open several tabs and click X rapidly on the current tab repeatedly.
   - **Expect:** each close animates independently; no stray/lingering overlay rectangle is left on screen after the dust settles; the final visible tab is correct and typeable.
5. With one tab left, click its X (or Cmd+W on its last pane).
   - **Expect:** the window closes (no overlay artifact, no crash) — the last-tab/`performClose` path is unchanged.

> Note: **Cmd+W is a pane close** (`performCloseTab → tree.closeActive()`), *not* a tab close — that path is Task 5. Use the tab-bar **X** to exercise tab close here.

- [ ] **Step 7: MANUAL verification — disabled path is byte-identical to today**

Assert the instant path is unchanged in **both** ways the gate can be off:

1. **Settings toggle off:** open **Settings**, turn **Animations OFF**. With 2–3 tabs open, click the **X** on the current tab.
   - **Expect:** the next tab appears **instantly** with **no overlay, no slide, no fade** — exactly today's behavior. End state: the next tab is visible and first-responder (typing works immediately).
2. **macOS Reduce Motion:** turn Animations back **ON** in Settings, then enable **System Settings → Accessibility → Display → Reduce motion**. Close the current tab via its **X**.
   - **Expect:** still **instant** (Reduce Motion overrides the toggle, per `Motion.enabled`).
3. In both cases also confirm **no `CALayer` overlay lingers** in `contentContainer` (the content area is clean; the next tab fills it edge-to-edge) and the window-close path (last tab) is unaffected.

(Restore Reduce Motion to your normal setting afterward.)

- [ ] **Step 8: Commit**

```bash
git add Sources/halite/CompactWindowController.swift
git commit -m "feat(anim): animate tab close (snapshot slides down + fades)

Close the visible tab by snapshotting its content into a self-removing
overlay (Motion.overlay), swapping the next tab in live (instant, default
.none transition), then sliding the snapshot down ~6% + fading it out over
0.16s easeOut before removing it. Gated on Motion.enabled, closing the
*current* tab (index == currentIndex), and tabs.count > 1 — background-tab
close, last-tab/window-close, snapshot failure, toggle-off and Reduce Motion
all keep the unchanged instant path. contentContainer is now layer-backed up
front to host the overlay. Uses an explicit CABasicAnimation (the bell-flash
idiom) because the overlay is a detached CALayer with no .animator() proxy;
duration/timing come from Motion.duration / Motion.timing."
```

---

## Task 5: Pane close — snapshot the closing pane and slide it out toward its outer edge

Animate **pane close** (`closeActive()`, triggered by `Cmd+W` on a non-last pane). Per the design (spec line 87): snapshot the closing pane **before** the session is terminated and the tree is mutated; the sibling **snaps** to full size underneath (one reflow, not animated); a bitmap **overlay** of the closed pane sits at its old frame and animates — sliding a small nudge toward the closing pane's **outer edge** (≈ 0.06× of the relevant dimension) while fading `α 1→0` — then removes itself on completion. All motion is `Motion.duration` / `Motion.timing` (0.16s easeOut).

**Dependency note (Task 3 scaffold):** Task 3 (pane split) introduced the `private enum PaneAnimation` (nested in `PaneTreeView`) with cases `.none` and `.split(newLeaf:)`, changed `rebuild()` to `rebuild(animation: PaneAnimation = .none)`, and added the `findWrapper(for:in:)` and `animateSplitIn(newLeaf:direction:)` helpers (in the `// MARK: - Split/Close animation helpers` region). This task **extends** that enum with a `.close` case, adds a `ClosingEdge` enum (nested `private` in `PaneTreeView`, next to `PaneAnimation`), and adds the close branch inside `rebuild(animation:)`. **`findWrapper(for:in:)` and `animateSplitIn(...)` already exist from Task 3 — reuse them; do NOT re-declare either.**

> **Executing tasks in order:** Task 3 already declared the full `PaneAnimation` enum with `.none` and `.split`. In Step 1 below you ONLY add the `case close(...)` line plus the new `ClosingEdge` enum — do NOT re-show or re-declare the `.none` / `.split` cases (a duplicate case is a compile error). The Step 1 snippet is deliberately scoped to just the additions.

**Gating contract (unchanged from Task 1):** `closeActive()` reads `Motion.enabled` first. When `false`, it runs the **exact** instant path that exists today (`rebuild()` with no animation) — same final view hierarchy and first-responder, no overlay. If `Motion.snapshot(of:)` returns `nil` (zero-size wrapper), it also falls back to the instant path. The closing pane's `PaneLeafWrapper` is `private` to `PaneTreeView.swift`, so the snapshot/frame capture and the wrapper-finding helper live inside that file where the type is reachable.

**Coordinate note:** `PaneTreeView` (`self`) is **non-flipped** (y up) — confirmed by the `moveFocus` comment at `PaneTreeView.swift:131` ("self는 non-flipped(y up)"). So sliding a pane toward the **bottom** outer edge is `-y`; toward the **top** is `+y`. The overlay layer's `frame` is in `self`'s coordinate space (we convert the wrapper's bounds to `self`).

**Edge derivation:** In `closeActive()` the closing pane is `activeLeaf`; its `parent` is a `.split(direction, first, second, ratio)`. Per `SplitContainer.layout()` (`PaneTreeView.swift:265-293`): for `.horizontal`, `first` = left / `second` = right; for `.vertical`, `first` = top / `second` = bottom. The **outer edge** is the edge facing away from the divider (the sibling grows from the divider toward the closing pane), so:
- horizontal + first  → slide **left**  (`.left`)
- horizontal + second → slide **right** (`.right`)
- vertical   + first  → slide **up**    (`.top`)
- vertical   + second → slide **down**  (`.bottom`)

**Rapid nested-rebuild safety:** the close overlay is added as a **sublayer of `self.layer`** (via `Motion.overlay`), NOT as one of `self`'s `subviews`. `rebuild()`'s teardown loop only iterates `subviews` and calls `removeFromSuperview()` — it never touches sublayers. So a nested/rapid `rebuild()` (e.g. closing a split to promote a sub-split) does not strand or prematurely remove an in-flight close overlay: each overlay self-removes solely via its own `Motion.run` `done` handler. The captured `snapshot`/`closingFrame` are by-value at capture time, and the wrapper is found *before* mutation, so a later rebuild cannot invalidate them. Each close animates its own distinct snapshot layer independently.

**Files:**
- Modify: `Sources/halite/PaneTreeView.swift`
  - Extend `PaneAnimation` (add `.close` case) and add `private enum ClosingEdge` nested in `PaneTreeView` next to `PaneAnimation`; rewrite `rebuild(animation:)` to handle the close branch (full body shown).
  - `closeActive()` (`:71-95`): capture snapshot + frame + edge before mutation, pass into `rebuild(animation:)`.
  - Reuse the existing `findWrapper(for:in:)` and `animateSplitIn(newLeaf:direction:)` from Task 3 (no new declarations).
- Test: No new unit test — pane-close is visual/timing and is verified **manually** (project norm; design line 116). The non-visual guarantee (disabled path reaches the same final hierarchy synchronously) is asserted in the manual step below. Existing `swift test` must still pass.

---

- [ ] **Step 1: Extend `PaneAnimation` with a `.close` case and add `ClosingEdge` (additions only — do NOT redeclare `.none`/`.split`)**

In `Sources/halite/PaneTreeView.swift`, find the `private enum PaneAnimation` introduced by Task 3 (nested inside `PaneTreeView`). Make exactly two additions, leaving the existing `.none` / `.split(newLeaf:)` cases untouched:

**(1)** Add a single `.close` case to the existing `PaneAnimation` enum (the result has all three cases — `.none` and `.split` are from Task 3, only `.close` is new here):

```swift
        // (Task 3 declared `.none` and `.split(newLeaf:)`. Add ONLY this line.)
        case close(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge)
```

**(2)** Add a brand-new `ClosingEdge` enum directly beside `PaneAnimation` (also nested `private`):

```swift
    /// 닫히는 pane이 슬라이드해 사라질 방향(바깥 edge). self는 non-flipped(y up).
    private enum ClosingEdge {
        case left, right, top, bottom

        /// `width`/`height`(가로/세로 길이)에 0.06을 곱한 nudge 만큼의 (dx, dy) translation.
        /// self가 y-up이므로 bottom은 -y, top은 +y.
        func offset(forWidth width: CGFloat, height: CGFloat) -> CGSize {
            let nudgeX = width * 0.06
            let nudgeY = height * 0.06
            switch self {
            case .left:   return CGSize(width: -nudgeX, height: 0)
            case .right:  return CGSize(width:  nudgeX, height: 0)
            case .top:    return CGSize(width: 0, height:  nudgeY)
            case .bottom: return CGSize(width: 0, height: -nudgeY)
            }
        }
    }
```

For reference only (do NOT paste this whole block — it would re-declare Task 3's cases), the merged `PaneAnimation` enum will read as below after your single `case close(...)` addition:

```swift
    private enum PaneAnimation {
        case none                               // (from Task 3 — do not re-add)
        case split(newLeaf: PaneNode)           // (from Task 3 — do not re-add)
        case close(snapshot: NSImage, closingFrame: NSRect, edge: ClosingEdge)  // ← add this line only
    }
```

- [ ] **Step 2: Confirm the `findWrapper(for:in:)` helper exists (from Task 3) — do NOT re-add it**

Pane close locates the closing pane's `PaneLeafWrapper` with the **same** `findWrapper(for:in:)` helper that Task 3 added to `PaneTreeView` (in the `// MARK: - Split/Close animation helpers` region). Verify it is present:

```swift
    private func findWrapper(for target: PaneNode, in view: NSView) -> PaneLeafWrapper? {
        if let w = view as? PaneLeafWrapper, w.leaf === target {
            return w
        }
        for sub in view.subviews {
            if let found = findWrapper(for: target, in: sub) { return found }
        }
        return nil
    }
```

If it is missing (e.g. tasks executed out of order), add it from Task 3 Step 4. Do **not** add a second copy — a duplicate declaration will not compile.

- [ ] **Step 3: Capture snapshot + frame + edge in `closeActive()` before tree mutation**

Rewrite `closeActive()` (`:71-95`). The snapshot, the closing wrapper's frame (converted to `self`), and the slide edge are all computed **before** `s.terminate()` and the tree mutation, because after mutation the wrapper and its content are torn down. The animation intent is then handed to `rebuild(animation:)`. When `Motion.enabled` is `false` or the snapshot is `nil`, `animation` stays `.none` and the behavior is identical to today.

Replace the whole method with:

```swift
    func closeActive() {
        guard case .leaf = activeLeaf.kind else { return }

        // --- 애니메이션 의도 계산 (트리 변경 전에). 비활성/스냅샷 실패 시 .none로 즉시 경로. ---
        var animation: PaneAnimation = .none
        if Motion.enabled,
           let parent = activeLeaf.parent,
           case .split(let dir, let first, _, _) = parent.kind,
           let wrapper = findWrapper(for: activeLeaf, in: self),
           let snap = Motion.snapshot(of: wrapper) {
            let closingFrame = wrapper.convert(wrapper.bounds, to: self)
            let isFirst = (first === activeLeaf)
            let edge: ClosingEdge
            switch dir {
            case .horizontal: edge = isFirst ? .left : .right   // first=좌, second=우
            case .vertical:   edge = isFirst ? .top  : .bottom  // first=위, second=아래
            }
            animation = .close(snapshot: snap, closingFrame: closingFrame, edge: edge)
        }

        // session terminate.
        if case .leaf(let s, _) = activeLeaf.kind {
            s.terminate()
        }
        // 부모의 다른 child가 그 부모 자리로 promote.
        guard let parent = activeLeaf.parent,
              case .split(_, let first, let second, _) = parent.kind
        else {
            // root leaf 닫은 경우 — 전체 종료.
            onAllPanesClosed?()
            return
        }
        let sibling = (first === activeLeaf) ? second : first
        parent.kind = sibling.kind
        // sibling이 split이었으면 그 자식들의 parent를 갱신.
        if case .split(_, let a, let b, _) = parent.kind {
            a.parent = parent
            b.parent = parent
        }
        // 새 active를 promote된 sub-tree의 첫 leaf로 설정.
        activeLeaf = firstLeaf(of: parent)
        rebuild(animation: animation)
    }
```

Notes:
- The `parent` / `case .split(...)` is read **twice** intentionally: once in the pre-mutation animation block (to derive `dir`/`first`/`edge`), once in the existing guard that drives the promotion. This keeps the existing teardown logic byte-for-byte and only prepends the capture.
- `Motion.snapshot(of: wrapper)` snapshots the **wrapper** (it contains the surface inset by 1pt), so the overlay matches what the user saw, border included.

- [ ] **Step 4: Handle the `.close` branch inside `rebuild(animation:)`**

Rewrite `rebuild(animation:)` so its full body handles `.none`, `.split`, and the new `.close`. The common teardown/rebuild (the original `rebuild()` body) runs first for every case — the live view hierarchy is rebuilt to its **final** state synchronously (sibling already snapped to full), then the overlay animates **on top** and removes itself. The instant path (`.none`) is unchanged from Task 3. **The `.split` branch keeps Task 3's exact 2-arg dispatch (`animateSplitIn(newLeaf:direction:)`) — derive `dir` from the new leaf's parent split.**

Replace the `rebuild(animation:)` method with:

```swift
    private func rebuild(animation: PaneAnimation = .none) {
        for sub in subviews { sub.removeFromSuperview() }
        addSubviewsForNode(root, into: self)
        updateBorderColors()
        if case .leaf(_, let surface) = activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        needsLayout = true
        // 라이브 계층은 위에서 최종 상태로 재구성됨 (sibling이 full로 snap). 이제 의도별 오버레이 처리.
        switch animation {
        case .none:
            break

        case .split(let newLeaf):
            // (Task 3) 새 pane이 divider edge에서 밀어내려 나타나는 모션 — 부모 split에서
            // 방향 도출 후 2-arg 호출.
            guard let parent = newLeaf.parent,
                  case .split(let dir, _, _, _) = parent.kind
            else { break }
            animateSplitIn(newLeaf: newLeaf, direction: dir)

        case .close(let snapshot, let closingFrame, let edge):
            // 닫힌 pane 스냅샷을 옛 frame에 올리고, 바깥 edge로 nudge + fade out 후 제거.
            // 라이브 계층(sibling full)은 그 아래에서 이미 최종 상태.
            // 오버레이는 self.layer의 sublayer라 위의 subviews teardown이 건드리지 않음 →
            // 빠른/중첩 rebuild에도 stranding 없이 done에서만 제거됨.
            layoutSubtreeIfNeeded()
            let overlay = Motion.overlay(image: snapshot, frame: closingFrame, in: self)
            let off = edge.offset(forWidth: closingFrame.width, height: closingFrame.height)
            Motion.run({
                overlay.opacity = 0
                overlay.position = CGPoint(
                    x: overlay.position.x + off.width,
                    y: overlay.position.y + off.height
                )
            }, done: {
                overlay.removeFromSuperlayer()
            })
        }
    }
```

Notes:
- `Motion.overlay(image:frame:in:)` (from Task 1) drops a self-contained image-backed `CALayer` at `closingFrame` in `self`'s layer (above the live content) and returns it.
- Mutating `overlay.opacity` / `overlay.position` inside `Motion.run` animates implicitly — `Motion.run` sets `allowsImplicitAnimation = true`, and the overlay is a detached layer (not a view's backing layer) so it animates its own properties under the group's duration/timing. `done` removes it, so no stray overlay lingers.
- `layoutSubtreeIfNeeded()` forces the freshly-added subviews to lay out so the live sibling is at full size **before** the overlay starts — the snap is complete on frame 0 of the animation.
- The `.split` branch matches Task 3's helper signature exactly (`animateSplitIn(newLeaf:direction:)`); do not introduce a 1-arg variant.
- The overlay is a **sublayer of `self.layer`**, so `rebuild()`'s `subviews` teardown never removes it; it self-removes only in the `done` handler — which is why rapid/nested closes don't strand it (see the "Rapid nested-rebuild safety" note above).

- [ ] **Step 5: Build**

Run from `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`:

```bash
swift build
```

Expected: `Build complete!` with no errors or warnings. (Compiles the new `.close` case, `ClosingEdge`, the rewritten `closeActive()`, and the merged `.close`/`.split` branches in `rebuild(animation:)` — reusing the Task-3 `findWrapper` and `animateSplitIn`.)

- [ ] **Step 6: Run the full test suite — confirm no regression**

```bash
swift test
```

Expected: all suites green, ending in `Test Suite 'All tests' passed` with 0 failures (the `MotionTests` from Task 1 plus the existing `DamsonTerminalTests` / `DamsonControlTests`). Pane-close itself has no unit test (visual/timing); this run proves the change did not break compilation or existing behavior.

- [ ] **Step 7: MANUAL verification — animation ON path**

```bash
swift build && HALITE_NO_TRAMPOLINE=1 .build/debug/halite
```

In the running app (default settings → `halite.animations` absent ⇒ ON):
1. Press `Cmd+D` to split the active pane **horizontally** (side-by-side). Type a distinguishing command (e.g. `echo RIGHT`) in the new (right) pane so it is visually identifiable.
2. With the **right** pane active, press `Cmd+W`.
   - Expect: a snapshot of the right pane **nudges to the right** (~6% of its width) and **fades out** over ~0.16s, while the **left** pane is already at full width underneath. No flicker, no leftover image, focus lands in the left pane (you can type immediately).
3. Repeat with the **left** pane active (close it): the snapshot should nudge **left** and fade.
4. Now split **vertically** (`Cmd+Shift+D`, stacked top/bottom). Close the **bottom** pane (`Cmd+W`): the snapshot nudges **down** and fades. Close a **top** pane: it nudges **up** and fades.
5. **Rapid spam:** split a few times, then hold/repeat `Cmd+W` quickly. Expect: each close animates independently and leaves **no stray overlay** — the window settles to a single full pane with no ghost images. (Overlays self-remove in `done`; each targets a distinct snapshot layer; nested rebuilds never strand them.)
6. Confirm the final pane is interactive (type in it) immediately after the last close.

- [ ] **Step 8: MANUAL verification — animation DISABLED path is unchanged**

Disable motion two independent ways and confirm pane-close is **instant** with an **identical final state** (same surviving pane, same focus, no overlay):

A. **Settings toggle off:** open Settings (`Cmd+,`), turn **Animations** OFF (added in Task 1), close Settings. Split (`Cmd+D`) then close (`Cmd+W`) the active pane. Expect: the closed pane disappears **instantly** (no slide, no fade), the sibling is full-size, focus is in the surviving pane. This is the exact pre-animation behavior.

B. **macOS Reduce Motion:** re-enable the Animations toggle, then turn on System Settings → Accessibility → Display → **Reduce motion**. Repeat split + close. Expect: **instant** close again (Reduce Motion wins over the toggle, per `Motion.enabled`). Turn Reduce Motion back off when done.

In both A and B the end-state must match the animated path's end-state exactly (same tree, same surviving pane, same first-responder) — only the transition differs. If any overlay lingers or the surviving pane is wrong, the gating/fallback is broken; revisit Steps 3-4.

- [ ] **Step 9: Commit**

```bash
git add Sources/halite/PaneTreeView.swift
git commit -m "feat(anim): animate pane close — snapshot slides out to outer edge

Snapshot the closing pane's wrapper before terminate()/tree mutation, let the
sibling snap to full size underneath, then nudge the snapshot overlay toward the
pane's outer edge (~6% of the dimension) + fade out over 0.16s easeOut, removing
it on completion. Edge derived from the pane's first/second position and parent
split direction. Reuses the Task-3 findWrapper/animateSplitIn helpers. Gated by
Motion.enabled (toggle AND not Reduce Motion) and a non-nil snapshot; the
disabled/fallback path runs the unchanged instant rebuild."
```

---

## Task 6: Tab switch — snapshot outgoing tab + crossfade/slide to incoming live tab

This task animates **switching between two existing tabs** (tab-bar click, `Cmd+Shift+[` / `Cmd+Shift+]`, `Ctrl+Tab`, `Cmd+1..9`). Per the spec's "Tab switch" row: snapshot the outgoing tab into an overlay, show the incoming tab **live at its final frame** underneath, then slide **both** horizontally by a small delta (~24pt, direction from the index sign — moving to a higher index slides left, lower slides right) while crossfading (snapshot α 1→0, live α 0→1).

**Slide-direction correctness (index order == visual order):** `reorderTab` (`CompactWindowController.swift:193-210`) physically reorders the `tabs` array and adjusts `currentIndex` to follow the moved tab, and the content area shows exactly one tab at a time. So the array index always equals the tab-bar visual position, and `currentIndex` is the visual position of the active tab. The index-sign slide is therefore correct even after drag-to-reorder — there is no spatial/index divergence to worry about.

**Builds on:** Task 2 (tab create), which already introduced the `TabTransition` enum with **all three cases** (`.none`, `.create`, `.switch(fromIndex:)`), the `selectTab(_ index: Int, transition: TabTransition = .none)` signature, the unconditional reset block, and the `.create` animation branch. This task **adds** the `.switch(fromIndex:)` animation branch and routes the four switch call sites through it. **The enum is NOT redeclared here** — it already has the `.switch` case from Task 2. Task 2's `.none`/`.create` handling (the reset block + the `if case .create ...` check) is untouched. It also relies on the `Motion` helper from Task 1 (`Motion.enabled`, `Motion.snapshot`, `Motion.overlay`, `Motion.duration`, `Motion.timing`, `Motion.run`).

**Technique note (why explicit `CABasicAnimation`, not `.animator()`):** the outgoing overlay is a bare `CALayer` (from `Motion.overlay`) — bare layers are not driven by `NSView.animator()`, so we animate them with explicit `CABasicAnimation`, exactly the proven bell-flash idiom (`DamsonTerminalView.swift:291`). The incoming `PaneTreeView` is pinned by Auto Layout constraints (`CompactWindowController.swift:177-182`); we must **not** animate its frame (that would fight constraints and resize the live surface → SIGWINCH reflow storm, the very thing Approach A avoids). Instead we animate its **layer's** `transform` + `opacity` — purely visual, zero reflow — also via explicit `CABasicAnimation`, with the initial values committed action-free (`CATransaction.setDisableActions(true)`). `PaneTreeView` is layer-backed (`wantsLayer = true`, `PaneTreeView.swift:23`), so `tree.layer` is non-nil. A single `Motion.run` group provides one completion handler that removes the overlay and restores the live layer to identity.

**Files:**
- Modify: `Sources/halite/CompactWindowController.swift`
  - `selectTab(_:transition:)`: capture the outgoing snapshot **before** the `removeFromSuperview()` loop, then run the switch animation **after** constraints + first responder are set and `refreshTabBar()` and the reset block have run.
  - new private method `animateTabSwitch(...)` inserted directly after `selectTab` (before `reorderTab`)
  - `tabBar.onTabSelected` callback (line 103) → pass `.switch(fromIndex:)`
  - `selectNextTab(_:)` (263-266), `selectPreviousTab(_:)` (269-272), `selectTabByNumber(_:)` (275-280) → pass `.switch(fromIndex:)`
  - **No change to the `TabTransition` enum** (Task 2 already defined all three cases).
- Test: `Tests/DamsonTerminalTests/MotionTests.swift` — no change required (switch logic is visual; the disabled-path correctness is asserted manually per the spec, see Step 6). The gating truth-table + snapshot tests from Task 1 already cover `Motion`. No new automated test is feasible for the crossfade itself (visual/timing — the project's norm, design §Testing).

---

- [ ] **Step 1: Confirm the `.switch(fromIndex:)` case exists on `TabTransition` (from Task 2) — do NOT redefine the enum**

The `TabTransition` enum was introduced in Task 2 (Step 1) immediately above `selectTab`, with all three cases already present:

```swift
    private enum TabTransition {
        case none
        case create
        case `switch`(fromIndex: Int)
    }
```

Verify it is there. (`switch` is a Swift keyword, so the case name is backtick-escaped: `` `switch` ``. At the call site it is written `.switch(fromIndex:)` with no backticks — the leading `.` disambiguates it.) If, for some out-of-order execution, the `.switch` case is missing, add only that case — do not redeclare the whole enum.

- [ ] **Step 2: Implement the switch branch in `selectTab(_:transition:)`**

Replace the body of `selectTab(_ index: Int, transition: TabTransition = .none)` so it captures the outgoing snapshot **before** tearing down the old view (the `for t in tabs { ... removeFromSuperview() }` loop) and runs the slide + crossfade **after** the incoming tree is constrained and first responder is set. The `.none` and `.create` branches established in Task 2 are preserved verbatim (the unconditional reset block + the `if case .create ...` check); only the new `.switch` capture + dispatch is added. The **complete** method (Task 2's body with the two switch-specific additions) is:

```swift
    func selectTab(_ index: Int, transition: TabTransition = .none) {
        guard index >= 0, index < tabs.count else { return }

        // Capture the outgoing tab's pixels BEFORE removeFromSuperview() tears it down.
        // Only for a real switch between two distinct, animation-enabled tabs.
        var switchOverlay: (image: NSImage, frame: NSRect, fromIndex: Int)?
        if case .switch(let fromIndex) = transition,
           Motion.enabled,
           fromIndex >= 0, fromIndex < tabs.count, fromIndex != index {
            let outgoing = tabs[fromIndex].tree
            // Only snapshot if that tree is actually the one on screen right now, and the
            // capture succeeds (zero-size → nil → instant path, spec §Snapshot fidelity).
            if outgoing.superview === contentContainer,
               let image = Motion.snapshot(of: outgoing) {
                // outgoing.frame is in contentContainer's coordinates — exactly where the
                // overlay must sit.
                switchOverlay = (image, outgoing.frame, fromIndex)
            }
        }

        currentIndex = index
        for t in tabs { t.tree.removeFromSuperview() }
        let tree = tabs[index].tree
        contentContainer.addSubview(tree)
        NSLayoutConstraint.activate([
            tree.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            tree.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            tree.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            tree.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
        ])
        if case .leaf(_, let surface) = tree.activeLeaf.kind {
            window?.makeFirstResponder(surface)
        }
        if let firstSession = tree.root.leaves().first?.session {
            let title = firstSession.title
            window?.title = title.isEmpty ? "halite" : title
        }
        refreshTabBar()

        // The incoming tree may carry a leftover from-state if a prior create/switch
        // animation on this same view was superseded. Reset to the final visual state
        // unconditionally; the branches below re-apply a from-state if they animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tree.layer?.opacity = 1
        tree.layer?.transform = CATransform3DIdentity
        CATransaction.commit()

        if case .create = transition, Motion.enabled {
            animateTabCreate(tree)
        }

        // Run the switch animation only if we captured a snapshot above. Otherwise this is
        // the instant path (disabled / create / first show / nil-snapshot) — identical to today.
        if let ov = switchOverlay {
            animateTabSwitch(incoming: tree, overlayImage: ov.image,
                             overlayFrame: ov.frame, fromIndex: ov.fromIndex, toIndex: index)
        }
    }
```

> Merge note: this is the **same** `selectTab` body produced by Task 2 (the unconditional reset block + the `.create` branch), with two additions: the `switchOverlay` capture at the top (before the `removeFromSuperview()` loop) and the `if let ov = switchOverlay { ... }` dispatch at the bottom. Keep Task 2's reset + `.create` lines exactly as shown above; the only new lines are the `switchOverlay` capture and the final `if let ov` block.

Notes baked into the code above:
- `switchOverlay` is non-nil **only** when `transition == .switch`, `Motion.enabled` is true, the from/to indices are valid & distinct, the outgoing tree is actually the one currently parented in `contentContainer`, and `Motion.snapshot` succeeded. Any failure (toggle off, Reduce Motion, zero-size, same tab) leaves it `nil` → the instant path runs, end state identical to today.
- The snapshot is taken **before** `removeFromSuperview()`, as the spec demands — capturing after teardown would yield a blank image.
- First responder + window title + `currentIndex` are set to the **final** state synchronously — typing works mid-animation; the animation is layer-only.

- [ ] **Step 3: Add the `animateTabSwitch(...)` private helper**

Add this method to `CompactWindowController`, placed directly after `selectTab` and before `reorderTab`. It runs the two coordinated explicit `CABasicAnimation`s inside one `Motion.run` group so a single completion handler cleans up:

```swift
    /// Tab-switch motion: the outgoing tab (a bitmap overlay) and the incoming live tab both
    /// slide horizontally by a small delta while crossfading. Direction follows the index sign:
    /// moving to a higher index slides content left (new tab enters from the right), lower
    /// slides right. Layer-only — never touches frames — so the live surface never reflows.
    /// (Index order == visual order, even after drag-reorder; see Task 6 preamble.)
    private func animateTabSwitch(incoming tree: PaneTreeView, overlayImage: NSImage,
                                  overlayFrame: NSRect, fromIndex: Int, toIndex: Int) {
        guard let incomingLayer = tree.layer else { return }  // layer-backed; should not be nil
        // Ensure constraints have produced the final frame before we read/animate it.
        contentContainer.layoutSubtreeIfNeeded()

        // Slide delta: ~24pt. Higher target index → content moves left (negative x).
        let delta: CGFloat = 24
        let dir: CGFloat = (toIndex > fromIndex) ? -1 : 1
        let slide = delta * dir

        // Outgoing overlay sits exactly where the old tree was; it slides `slide` and fades out.
        let overlay = Motion.overlay(image: overlayImage, frame: overlayFrame, in: contentContainer)

        // Incoming live layer starts offset the OPPOSITE way (so it converges to identity) and
        // transparent. Commit the start state with actions disabled so it doesn't pre-animate.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        incomingLayer.opacity = 0
        incomingLayer.transform = CATransform3DMakeTranslation(-slide, 0, 0)
        CATransaction.commit()

        // One NSAnimationContext group → one completion handler. The explicit CABasicAnimations
        // below carry the visual motion; we set the model (final) values AFTER add() so the
        // layers rest at their end state when the animations complete (a CABasicAnimation only
        // animates the presentation layer; on completion the layer snaps to its model value).
        Motion.run({
            // --- outgoing overlay: slide + fade out ---
            let oSlide = CABasicAnimation(keyPath: "transform.translation.x")
            oSlide.fromValue = 0
            oSlide.toValue = slide
            oSlide.duration = Motion.duration
            oSlide.timingFunction = Motion.timing
            let oFade = CABasicAnimation(keyPath: "opacity")
            oFade.fromValue = 1.0
            oFade.toValue = 0.0
            oFade.duration = Motion.duration
            oFade.timingFunction = Motion.timing
            overlay.opacity = 0  // model value at end
            overlay.transform = CATransform3DMakeTranslation(slide, 0, 0)
            overlay.add(oSlide, forKey: "switchSlide")
            overlay.add(oFade, forKey: "switchFade")

            // --- incoming live layer: slide to identity + fade in ---
            let iSlide = CABasicAnimation(keyPath: "transform.translation.x")
            iSlide.fromValue = -slide
            iSlide.toValue = 0
            iSlide.duration = Motion.duration
            iSlide.timingFunction = Motion.timing
            let iFade = CABasicAnimation(keyPath: "opacity")
            iFade.fromValue = 0.0
            iFade.toValue = 1.0
            iFade.duration = Motion.duration
            iFade.timingFunction = Motion.timing
            incomingLayer.opacity = 1            // model value at end (identity)
            incomingLayer.transform = CATransform3DIdentity
            incomingLayer.add(iSlide, forKey: "switchSlide")
            incomingLayer.add(iFade, forKey: "switchFade")
        }, done: { [weak tree] in
            // Remove the overlay and hard-restore the live layer to identity, regardless of
            // whether a newer switch superseded this one (each animation targets its own
            // overlay; cleanup is idempotent and safe).
            overlay.removeFromSuperlayer()
            if let layer = tree?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.opacity = 1
                layer.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        })
    }
```

Why the model values are set inside the group (after `add()`): a `CABasicAnimation` only animates the *presentation* layer; when it completes (or is removed) the layer snaps to its **model** value. Setting `opacity`/`transform` to the end state guarantees the layer rests correctly. The overlay is then removed in `done` so its leftover model state is moot.

- [ ] **Step 4: Route the four switch call sites through `.switch(fromIndex:)`**

The create path (`addTab`/`addNewTab`), close path (`closeTab`), and restore-init must **keep** their existing transitions (Task 2 set create to `.create`; close/restore stay `.none`) — do **not** change them here. Only the genuine "pick another existing tab" entry points become `.switch`. Capture the current index as `fromIndex` before the index changes.

`tabBar.onTabSelected` callback (line 103) — change `self?.selectTab(idx)` to pass the switch transition:

```swift
        tabBar.onTabSelected = { [weak self] idx in
            guard let self = self else { return }
            self.selectTab(idx, transition: .switch(fromIndex: self.currentIndex))
        }
```

`selectNextTab(_:)` (263-266) — capture `from` before the index advances:

```swift
    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex + 1) % tabs.count, transition: .switch(fromIndex: from))
    }
```

`selectPreviousTab(_:)` (269-272) — capture `from` before the index changes:

```swift
    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        let from = currentIndex
        selectTab((currentIndex - 1 + tabs.count) % tabs.count, transition: .switch(fromIndex: from))
    }
```

`selectTabByNumber(_:)` (275-280) — pass the current index as `fromIndex`:

```swift
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let n = item.tag
        let idx = (n == 9) ? tabs.count - 1 : n - 1
        if idx >= 0 && idx < tabs.count {
            selectTab(idx, transition: .switch(fromIndex: currentIndex))
        }
    }
```

(The `selectTab` guard already no-ops on an out-of-range index, and the `fromIndex != index` check in Step 2 means re-selecting the current tab via `Cmd+<currentNumber>` falls through to the instant path with no stray overlay — correct.)

- [ ] **Step 5: Build the package**

Run (from `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`):

```bash
swift build
```

Expected: `Build complete!` with no errors or warnings. This compiles the new `.switch` dispatch, `animateTabSwitch`, and the four re-routed call sites against the `Motion` API from Task 1 and the `TabTransition` enum from Task 2.

- [ ] **Step 6: Run the full test suite — assert the disabled path is unchanged**

Run:

```bash
swift test
```

Expected: all suites green, ending `Test Suite 'All tests' passed` with 0 failures (the Task-1 `MotionTests` plus the existing `DamsonTerminalTests` / `DamsonControlTests`). This is the **disabled-path / non-visual regression guard**: switch logic is layer-only and never alters the final view hierarchy, first responder, `currentIndex`, or window title, so no existing test changes behavior. (There is no automated test for the crossfade itself — visual/timing, verified manually in Step 7 per design §Testing.)

- [ ] **Step 7: MANUAL verification — animation ON**

Run the app directly (bypass the IME trampoline for dev iteration):

```bash
killall halite 2>/dev/null; swift build && HALITE_NO_TRAMPOLINE=1 .build/debug/halite
```

In the running app:
1. `Cmd+T` three or four times to create several tabs (each with a visible shell prompt; type `ls` in a couple so the content differs between tabs).
2. Click tab 3 in the tab bar, then click tab 1. **Look for:** when moving to a **higher** index (1→3) the content slides **left** (~24pt) as the new tab fades in from the right and the old tab fades out to the left; moving to a **lower** index (3→1) slides **right**. The motion is a subtle ~0.16s nudge + crossfade, not a full-width swipe. No flicker, no blank frame, no left-over ghost of the previous tab.
3. Press `Cmd+Shift+]` / `Cmd+Shift+[` (and `Ctrl+Tab`) to cycle — same slide/crossfade, direction following the move.
4. Press `Cmd+1`, `Cmd+2`, … — same animation; pressing the **current** tab's number does nothing (no animation, no overlay).
5. **Typing works mid-animation:** click tab 2, immediately type `echo hi` while it animates — the keystrokes land in tab 2's shell (first responder is set synchronously).
6. **Rapid spam:** mash `Cmd+Shift+]` rapidly across all tabs. **Look for:** no stray/stuck overlay images, no permanently-dimmed or offset tab — every overlay self-removes; the final tab rests crisp at full opacity and identity transform.

- [ ] **Step 8: MANUAL verification — animation OFF (disabled-path end-state unchanged)**

Disable motion two independent ways and confirm switching is **instant and pixel-correct**:

1. **Settings toggle:** open Settings (`Cmd+,`), turn **Animations** OFF (the toggle added in Task 1). Switch tabs via click, `Cmd+Shift+]`, and `Cmd+1..9`. **Look for:** the new tab appears **instantly** at full opacity — no slide, no fade, no overlay — identical to pre-animation `halite`. Turn the toggle back ON; switching animates again (live, no relaunch).
2. **macOS Reduce Motion:** System Settings → Accessibility → Display → **Reduce motion** ON (leave the Settings toggle ON to prove Reduce Motion wins). Switch tabs. **Look for:** instant, no animation. Turn Reduce Motion OFF → animation returns.

In both disabled cases the **end state must equal the enabled-case end state**: correct tab visible, its active pane is first responder (type immediately — keystrokes land), correct window title, `currentIndex` updated, and **no overlay layer lingering** in `contentContainer` (the disabled path never calls `Motion.overlay`).

- [ ] **Step 9: Commit**

```bash
git add Sources/halite/CompactWindowController.swift
git commit -m "feat(anim): tab switch — snapshot outgoing + crossfade/slide to live incoming

Animate tab switching via TabTransition.switch(fromIndex:): snapshot the
outgoing tab into an overlay, show the incoming tab live at its final frame,
then slide both ~24pt horizontally (direction from the index sign) while
crossfading (overlay alpha 1->0, live alpha 0->1) over Motion.duration easeOut.
Layer-only (transform+opacity) so the live surface never reflows; one
Motion.run group cleans up the overlay and restores the live layer to identity.
Route tab-bar click, next/prev, and Cmd+1..9 through .switch. Gated by
Motion.enabled (toggle AND not Reduce Motion); when disabled or snapshot fails,
the existing instant selectTab path runs unchanged."
```

---

## Task 7: Final manual-QA pass + gating-test re-run

This is the closing task. By now Tasks 1–6 have shipped: `Motion` core + `halite.animations` toggle + Reduce-Motion gate **and** the `MotionTests` gating tests (Task 1), tab create (Task 2), pane split (Task 3), tab close (Task 4), pane close (Task 5), and tab switch (Task 6). Task 7 adds **no new production code**. It (a) re-runs the only feasible automated gates as a regression check, and (b) performs the manual QA the spec mandates for visual/timing behavior — including the assertion that both disable paths (Settings toggle off, and macOS Reduce Motion on) produce instant motion with an **end state identical to today's instant code**.

**Prerequisite:** all of Tasks 1–6 must have their commits on the feature branch before Task 7 begins. Task 7 verifies the integrated whole; it cannot check anything if any earlier task's changes are unbuilt or uncommitted. Confirm with `git log --oneline` that the six task commits are present before starting.

**Why the disabled-path end-state check is manual, not an XCTest:** the spec (design doc line 119) wants an automated test that `selectTab`/`rebuild` reach the correct final view hierarchy + first-responder synchronously when animations are disabled. That is **not writable as an XCTest**: `CompactWindowController.selectTab(_:)` and `PaneTreeView.rebuild(animation:)` both live in the `halite` **executable** target, and (Package.swift lines 62–71) the test targets depend only on `DamsonTerminal`/`DamsonControl` — SwiftPM cannot `@testable import` an executable. So the *pure* `Motion` gating logic is covered by `MotionTests` (created in Task 1, re-run in Step 1), and the disabled-path end-state of `selectTab`/`rebuild` is verified **manually** in Steps 5 and 6 below.

**Files:**
- Create: _none_ (pure QA task — no new source or test files).
- Modify: _none_ (no production code change; if QA uncovers a regression, fix it under the relevant earlier task, not here).
- Test: `Tests/DamsonTerminalTests/MotionTests.swift` — **re-run only** as a regression gate (created in Task 1; Task 7 adds no new cases).

All commands run from `/Users/dkkang/dev/damson/.claude/worktrees/tab-pane-animation`.

---

- [ ] **Step 1 — Re-run the automated gating tests (regression check).**

  Confirm the `Motion.enabled` truth table and `snapshot(of:)` non-nil/nil cases from Task 1 still pass after all integration work:
  ```bash
  swift test --filter MotionTests
  ```
  Expected result: the suite runs and reports **0 failures** (e.g. `Test Suite 'MotionTests' passed`, "Executed N tests, with 0 failures"). These cover the only logic SwiftPM can unit-test: `Motion.isEnabled(toggledOn:reduceMotionEnabled:)` for all four toggle×Reduce-Motion combinations, plus `Motion.snapshot(of:)` returning non-nil for a sized `NSView` and nil for a zero-size one.

  Note: `swift test DamsonTerminalTests.MotionTests` is invalid syntax — always use `--filter`. To run the whole library suite instead: `swift test --filter DamsonTerminalTests` (expected: 0 failures).

- [ ] **Step 2 — Clean build of the app.**

  ```bash
  swift build
  ```
  Expected result: `Build complete!` with no errors or warnings introduced by the animation work.

- [ ] **Step 3 — Launch the app for manual QA.**

  Bypass the IME trampoline so the freshly built binary runs directly:
  ```bash
  killall halite 2>/dev/null; HALITE_NO_TRAMPOLINE=1 .build/debug/halite
  ```
  Expected result: one window opens with a single tab and a live shell prompt. Leave it running for Steps 4–6. (`killall halite` first clears any stale instance so you are testing the new binary.)

- [ ] **Step 4 — Manually verify all 5 interactions are smooth (animations ON, Reduce Motion OFF).**

  First confirm motion is enabled: open Settings (`Cmd+,`), ensure **Animations** (under the Cursor section, next to "Blink") is **checked**, and confirm macOS System Settings → Accessibility → Display → **Reduce motion** is **OFF**. Close Settings.

  Perform each interaction and confirm the described ~0.16s easeOut motion. Each line also states the **instant-path end state** so you can confirm motion only changes the *transition*, never the final layout:

  1. **Tab create — `Cmd+T`** (Task 2): new tab's `PaneTreeView` content fades in (opacity 0→1) and scales 0.98→1.0. End state (same as instant): new tab full-size, selected, focused, shell prompt live.
  2. **Tab switch — `Cmd+Shift+]` then `Cmd+Shift+[`** (Task 6): outgoing tab (snapshot) and incoming live tab nudge horizontally (~24pt, direction follows index sign) while crossfading (snapshot α 1→0, live α 0→1). End state: target tab shown full-frame, no ghost. Instant counterpart: a hard cut to the target tab.
  3. **Pane split — `Cmd+D` (horizontal) and `Cmd+Shift+D` (vertical)** (Task 3): the **new** pane's `PaneLeafWrapper` opens from the divider edge (transform translated from that edge → identity) + opacity 0→1; the **existing** pane snaps to its half-frame in one reflow (not animated, per spec). End state: two panes at 50/50 with the divider, new pane focused. Instant counterpart: both halves appear at once.
  4. **Pane close — split first with `Cmd+D`, then `Cmd+W`** (Task 5): the closing pane's bitmap snapshot slides toward its outer edge (~6% of the dimension) + fades out, while the sibling snaps to full size underneath, then the overlay is removed. End state: sibling fills the tab, focused. Instant counterpart: sibling fills instantly with no overlay. (Cmd+W routes to `performCloseTab` → `closeActive()` only when the tab has 2+ panes — hence the split first.)
  5. **Tab close — on a single-pane tab, click the tab-bar X** (Task 4): the closing tab's content snapshot slides **down** (~6% of height) + fades; the next tab is already shown live at full frame underneath; overlay removed on completion. End state: next tab full-frame and focused. Instant counterpart: hard cut to the next tab. (On the *last* remaining pane of the *last* tab, Cmd+W cascades to closing the window — expected; don't mistake it for a missing animation.)

  Pass criteria: each motion is visible, fast, and ends in the layout described above with **no** residual semi-transparent overlay sitting on top of the live content.

- [ ] **Step 5 — Manually verify typing works mid-animation, and rapid spam leaves no stray overlays.**

  - **Typing mid-animation (falsifiable focus check):** press `Cmd+T` and immediately begin typing during the ~0.16s fade-in (e.g. type `echo hi`). Every character must land in the **new** tab's surface — `window.makeFirstResponder(surface)` is set synchronously to the final state before the animation, so focus is never on a transient/overlay view. Pass: the full string appears at the new pane's prompt.
  - **Rapid spam (overlay-cleanup check), in this order to avoid nuking the window mid-test:**
    1. Burst `Cmd+T` five times → multiple tabs created.
    2. Burst `Cmd+D` several times in the current tab → multiple splits.
    3. Burst `Cmd+W` several times → panes/tabs close (stop before the window would close).

    After each burst settles (~0.2s), assert: **no** ghost/semi-transparent snapshot overlay remains on top of the live content (every `Motion.overlay` layer self-removes in its `Motion.run` completion handler or `asyncAfter` cleanup), and clicking/typing lands in the correct, currently-active surface. Pass: the live view is clean and interactive after every burst; superseding an in-flight animation never strands an overlay.

- [ ] **Step 6 — Manually verify BOTH disable paths produce instant motion with an identical end state.**

  This step also serves as the manual stand-in for the spec's disabled-path end-state assertion on `selectTab`/`rebuild` (which, per the task preamble, cannot be an XCTest because those methods live in the `halite` executable target).

  - **Path A — Settings toggle OFF:** open Settings (`Cmd+,`), **uncheck Animations**, close Settings. (`@AppStorage("halite.animations")` writes `UserDefaults.standard` synchronously; `Motion.enabled` reads it live at each entry point, so no relaunch is needed.) Repeat all 5 interactions from Step 4. Pass: every interaction is **instant** (hard cut, no fade/scale/slide, no overlay) and the **end state is identical** to the animated end states listed in Step 4 — same final tab/pane layout, same selected tab, same focused surface.

  - **Path B — Reduce Motion wins regardless of the toggle:** re-check **Animations** in Settings (toggle back ON), then enable macOS System Settings → Accessibility → Display → **Reduce motion**. Repeat all 5 interactions. Pass: still **instant** with the **same identical end state** as Step 4 — proving `Motion.enabled` ANDs the toggle with `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` so Reduce Motion overrides the ON toggle.

  After both paths pass, restore your normal settings (Animations ON, Reduce motion OFF) if you want to re-confirm motion returns. Then quit and clean up:
  ```bash
  killall halite
  ```
  Expected result: the app exits; no lingering `halite` process.

- [ ] **Step 7 — Final gate + sign-off (no code change to commit).**

  Re-run the automated gate one last time to confirm nothing regressed during QA:
  ```bash
  swift test --filter MotionTests
  ```
  Expected result: 0 failures.

  Task 7 introduces **no production or test code** of its own — it is a verification pass. If every check in Steps 1–6 passed, there is nothing to commit for this task (the animation code was committed under Tasks 1–6); record QA sign-off in the PR description instead. If QA *did* surface a regression, fix it under the originating earlier task and re-run Steps 1–6, rather than committing a fix under Task 7. Only if you intentionally added a new automated `MotionTests` case while here would you commit it:
  ```bash
  git add Tests/DamsonTerminalTests/MotionTests.swift && git commit -m "test(motion): add gating case found during final QA"
  ```
  (Skip this commit if no test was added — the normal case for a pure-QA task.)