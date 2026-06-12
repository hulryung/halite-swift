# Hangul IME on macOS — Findings & Solution

## TL;DR

The Korean IME on macOS has two layers of races:

1. **per-switch race**: right after switching to Hangul mode via the Korean/English toggle key, the first keystroke leaks as a raw character without going through `setMarkedText`. **Fixed by registering as a `.app` bundle**.
2. **per-launch race**: even when running as a `.app`, **the user's very first keystroke** right after launch leaks once, while the TSM↔IMK IPC is not yet set up. **Fixed by pre-warming the IPC: feed a synthetic dummy event into the inputContext right after launch**.

damson fixes both layers. Below is the record of how the second race was discovered and solved.

---

## Problem

### Symptom 1 — per-switch race (the one the halite Rust doc covered)

Right after switching from English to Hangul input mode via the toggle key, the first keystroke fails to start composition properly:

```
Intended: ㅎ → ㅏ → ㄴ → "한"
Actual:   ㅎ commits as-is → composition starts from "한" onward
Screen:   "ㅎ한"
```

### Symptom 2 — per-launch race (the one this doc covers)

Registering as a `.app` bundle eliminated symptom 1, but **exactly once right after launching the `.app`**, the user's first Hangul keystroke leaks the same way. All IME switches afterward work fine.

Put differently: `.app` registration fixes the "per-IME-switch IPC race", and the synthetic dummy event fixes the "IPC-not-yet-set-up race at the first keystroke after process start".

### Impact

- Korean users have to correct the first character with BS + retype on every app launch
- Proper macOS terminals like WezTerm / Terminal.app / iTerm2 have neither problem
- We applied the same pattern (.app + warmup) and achieved the same result

---

## Root cause

### The TSM↔IMK IPC model on macOS

The macOS Text Services Manager (TSM) manages the IPC between the IME service and the client process via mach ports.

| Timing | TSM behavior |
|---|---|
| A GUI app (`.app`) registered with LaunchServices launches | Sets up the IPC channel ahead of time at launch |
| A process run as a raw binary | Lazily attempts IPC only when the first input event arrives |
| First input event after a `.app` GUI app launches | (In a minority of environments) IPC not yet fully ready — first event can leak |

The standard behavior is that `.app` registration alone eliminates the second race, but in our macOS environment that wasn't enough — we had to actively wake the IPC with a synthetic dummy event.

### Diagnostic signal

An `IMKCFRunLoopWakeUpReliable` mach-port error is printed to the console exactly once, right before the first jamo — the signature of the IPC being set up lazily at that moment.

---

## Hypothesis testing (summary)

The halite Rust doc (`~/dev/halite/docs/KOREAN-IME.md`) tested all 7 hypotheses and proved `.app` is the only per-switch fix. damson took that conclusion as its starting point, applied it to our environment, and made the new observation that **`.app` alone still leaves the per-launch race**.

What we additionally tried:

| Attempt | Result |
|---|---|
| `customInputContext` (explicitly designating the NSTextInputContext owner) | ❌ No difference from default |
| Explicitly calling `inputContext.activate()` | ❌ activate alone doesn't trigger the IPC |
| Synchronous retry inside `keyDown` — re-dispatching the same event | ❌ IPC doesn't warm up within the same microsecond |
| Async retry + optimistic markedText | ❌ Lossy — our state diverges from IMK's internal state (halite Rust reached the same conclusion) |
| `.app` trampoline (Phase B) | ✅ Fixes per-switch race; per-launch race remains |
| `.app` + feeding one synthetic dummy event into the inputContext in viewDidMoveToWindow | ✅ Fixes both races |

---

## Solution

### Layer 1: `.app` trampoline (`Sources/damson/AppBundleTrampoline.swift`)

When run as a raw binary, it wraps itself in a minimal bundle at `~/Library/Caches/damson/Damson.app`, relaunches via `open -F` (fresh, no saved-state restoration), and the original calls `exit(0)`.

```
~/Library/Caches/damson/Damson.app/
├── Contents/
│   ├── Info.plist    # minimal fields: CFBundleExecutable, CFBundleIdentifier, NSHighResolutionCapable, etc.
│   └── MacOS/
│       └── damson    # fresh binary copy on every launch
```

To disable: set the `DAMSON_NO_TRAMPOLINE=1` environment variable.

### Layer 2: IME warmup (`Sources/DamsonTerminal/DamsonTerminalView.swift`)

In `viewDidMoveToWindow`, after first responder + `inputContext.activate()`, on the next runloop tick a synthetic `keyDown` event (the 'a' character) is fed through `inputContext.handleEvent`. The `insertText` / `doCommand` callbacks fired during this are swallowed (no PTY send) via the `isWarmingUpIME` flag.

Dispatching this dummy event actively wakes the TSM↔IMK IPC, so by the time the user presses their first key, the IPC is already ready.

To disable: to turn off just the warmup, initialize `didWarmupIME = true` (requires a code change — exposing an env var is a follow-up).

---

## Broader impact (macOS ecosystem)

The same race has been reported in other macOS apps:

| Project | Issue | Status |
|---|---|---|
| Alacritty | [#6942](https://github.com/alacritty/alacritty/issues/6942), [#8079](https://github.com/alacritty/alacritty/issues/8079) | Unresolved (2023~) |
| winit | [#3095](https://github.com/rust-windowing/winit/issues/3095) | Unresolved, `DS - appkit` label |
| Electron | [#45002](https://github.com/electron/electron/issues/45002) | "blocked/need-repro" |
| OpenJDK | [JDK-8356652](https://bugs.openjdk.org/browse/JDK-8356652) | Unresolved |
| Apple radar | [FB17460926](https://openradar.appspot.com/FB17460926) | Unresolved |

The macOS terminals that work correctly (Terminal.app, iTerm2, WezTerm, Warp) are **without exception distributed only as `.app` bundles**.

That even a project as large as OpenJDK is blocked by the same mechanism is evidence this can't be solved client-side outside Apple.

---

## Meta lesson

> A pattern the platform strongly recommends may be more than mere convention.

The `.app` bundle is not a macOS aesthetic preference but an **assumption** that entire system components — LaunchServices / TSM / IMK — depend on. Getting GUI features to work 100% correctly while violating that assumption is effectively impossible.

Nor is `.app` registration a silver bullet — in environments where there's no guarantee the IPC is fully warm right after launch, we have to wake it ourselves.

---

## Related files

- `Sources/damson/AppBundleTrampoline.swift` — Layer 1
- `Sources/damson/main.swift` — calls `AppBundleTrampoline.relaunchInAppBundleIfNeeded()` on its first line
- `Sources/DamsonTerminal/DamsonTerminalView.swift` — Layer 2 (`warmupIMEIfNeeded` + the `isWarmingUpIME` flag)

## References

- halite Rust, which did the same work first: `~/dev/halite/docs/KOREAN-IME.md`
- WezTerm macOS install (running the raw binary directly is discouraged): https://wezterm.org/install/macos.html
