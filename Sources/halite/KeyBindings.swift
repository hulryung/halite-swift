import AppKit
import HaliteTerminal

// MARK: - KeyChord — a single modifier+key combination

/// A keyboard shortcut: a set of modifier flags plus one key (a printable
/// character or a named special key). Layout-aware matching via
/// `charactersIgnoringModifiers` for printable keys, keyCode for special keys.
struct KeyChord: Codable, Equatable {
    /// Raw value of the device-independent modifier subset [⌘⇧⌥⌃].
    var mods: UInt
    var key: Key

    enum Key: Codable, Equatable {
        case char(String)        // unshifted base char; letters lowercased
        case special(Special)    // arrows / function row / etc. — matched by keyCode
    }

    enum Special: String, Codable, CaseIterable {
        case left, right, up, down, home, end, pageUp, pageDown
        case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
        case escape, tab, space, enter, delete

        var keyCode: UInt16 {
            switch self {
            case .left: return 123; case .right: return 124
            case .down: return 125; case .up: return 126
            case .home: return 115; case .end: return 119
            case .pageUp: return 116; case .pageDown: return 121
            case .f1: return 122; case .f2: return 120; case .f3: return 99
            case .f4: return 118; case .f5: return 96; case .f6: return 97
            case .f7: return 98; case .f8: return 100; case .f9: return 101
            case .f10: return 109; case .f11: return 103; case .f12: return 111
            case .escape: return 53; case .tab: return 48; case .space: return 49
            case .enter: return 36; case .delete: return 51
            }
        }

        init?(keyCode: UInt16) {
            guard let m = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
            self = m
        }

        /// The character AppKit wants in `NSMenuItem.keyEquivalent` for this key.
        var menuKeyEquivalent: String {
            func fk(_ k: Int) -> String { String(UnicodeScalar(k)!) }
            switch self {
            case .left: return fk(NSLeftArrowFunctionKey)
            case .right: return fk(NSRightArrowFunctionKey)
            case .up: return fk(NSUpArrowFunctionKey)
            case .down: return fk(NSDownArrowFunctionKey)
            case .home: return fk(NSHomeFunctionKey)
            case .end: return fk(NSEndFunctionKey)
            case .pageUp: return fk(NSPageUpFunctionKey)
            case .pageDown: return fk(NSPageDownFunctionKey)
            case .f1: return fk(NSF1FunctionKey); case .f2: return fk(NSF2FunctionKey)
            case .f3: return fk(NSF3FunctionKey); case .f4: return fk(NSF4FunctionKey)
            case .f5: return fk(NSF5FunctionKey); case .f6: return fk(NSF6FunctionKey)
            case .f7: return fk(NSF7FunctionKey); case .f8: return fk(NSF8FunctionKey)
            case .f9: return fk(NSF9FunctionKey); case .f10: return fk(NSF10FunctionKey)
            case .f11: return fk(NSF11FunctionKey); case .f12: return fk(NSF12FunctionKey)
            case .escape: return "\u{1b}"; case .tab: return "\t"
            case .space: return " "; case .enter: return "\r"
            case .delete: return "\u{08}"
            }
        }

        var display: String {
            switch self {
            case .left: return "←"; case .right: return "→"
            case .up: return "↑"; case .down: return "↓"
            case .home: return "↖"; case .end: return "↘"
            case .pageUp: return "⇞"; case .pageDown: return "⇟"
            case .escape: return "⎋"; case .tab: return "⇥"
            case .space: return "Space"; case .enter: return "↩"
            case .delete: return "⌫"
            default: return rawValue.uppercased()   // F1…F12
            }
        }
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: mods) }

    // MARK: matching

    /// US-layout map from a shifted glyph back to its unshifted base, so a chord
    /// stored as "]" matches an event whose `charactersIgnoringModifiers` is "}".
    static let unshiftUS: [String: String] = [
        "}": "]", "{": "[", ")": "0", "!": "1", "@": "2", "#": "3", "$": "4",
        "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ":": ";", "\"": "'",
        "<": ",", ">": ".", "?": "/", "+": "=", "_": "-", "~": "`", "|": "\\",
    ]

    private static let matchMask: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    func matches(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(Self.matchMask).rawValue == mods else { return false }
        switch key {
        case .special(let s):
            return event.keyCode == s.keyCode
        case .char(let c):
            guard let raw = event.charactersIgnoringModifiers, !raw.isEmpty else { return false }
            if raw.lowercased() == c { return true }
            if modifierFlags.contains(.shift), let un = Self.unshiftUS[raw], un == c { return true }
            return false
        }
    }

    /// Build a chord from a recorded key event. Returns nil for bare keys (no
    /// ⌘/⌥/⌃ modifier) — we don't let users capture plain letters that the PTY needs.
    static func from(event: NSEvent) -> KeyChord? {
        let m = event.modifierFlags.intersection(matchMask)
        guard m.contains(.command) || m.contains(.control) || m.contains(.option) else { return nil }
        if let special = Special(keyCode: event.keyCode) {
            return KeyChord(mods: m.rawValue, key: .special(special))
        }
        guard let raw = event.charactersIgnoringModifiers, let first = raw.first else { return nil }
        var base = String(first).lowercased()
        if m.contains(.shift), let un = unshiftUS[String(first)] { base = un }
        return KeyChord(mods: m.rawValue, key: .char(base))
    }

    // MARK: menu + display

    var menuKeyEquivalent: String {
        switch key {
        case .char(let c): return c
        case .special(let s): return s.menuKeyEquivalent
        }
    }

    /// "⌃⌥⇧⌘D" form for the Settings UI and menu rendering.
    var display: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        switch key {
        case .char(let c): s += c.uppercased()
        case .special(let sp): s += sp.display
        }
        return s
    }

    // Convenience constructors for defaults.
    static func c(_ ch: String, _ f: NSEvent.ModifierFlags) -> KeyChord {
        KeyChord(mods: f.rawValue, key: .char(ch))
    }
    static func s(_ sp: Special, _ f: NSEvent.ModifierFlags) -> KeyChord {
        KeyChord(mods: f.rawValue, key: .special(sp))
    }
}

// MARK: - AppAction — the rebindable command catalogue

/// One rebindable command. `id` is the stable persistence key; `menuSelector`
/// (when present) is how the menu dispatches it. View-level actions
/// (`viewAction != nil`) are dispatched by `HaliteSurfaceView`'s key hook instead.
struct AppAction {
    enum ID: String, CaseIterable {
        case settings, newWindow, newTab, closeTab, closeWindow
        case copy, paste, find, findNext, findPrevious
        case zoomIn, zoomOut, resetZoom, toggleFullScreen
        case splitHorizontally, splitVertically
        case focusPaneLeft, focusPaneRight, focusPaneDown, focusPaneUp
        case swapPaneLeft, swapPaneRight, swapPaneDown, swapPaneUp
        case nextTab, previousTab, jumpPreviousPrompt, jumpNextPrompt, quit
    }

    /// View-level actions handled inside `HaliteSurfaceView` (NSMenu can't reliably
    /// match shifted punctuation / arrows, and prompt-jump isn't a responder action).
    enum ViewAction {
        case nextTab, previousTab, jumpPreviousPrompt, jumpNextPrompt, closeTab, quit
    }

    let id: ID
    let title: String
    let category: String
    let defaultChord: KeyChord
    let viewAction: ViewAction?

    static let all: [AppAction] = {
        let cmd: NSEvent.ModifierFlags = [.command]
        let cmdShift: NSEvent.ModifierFlags = [.command, .shift]
        let cmdOpt: NSEvent.ModifierFlags = [.command, .option]
        let cmdCtrl: NSEvent.ModifierFlags = [.command, .control]
        func a(_ id: ID, _ title: String, _ cat: String, _ chord: KeyChord,
               view: ViewAction? = nil) -> AppAction {
            AppAction(id: id, title: title, category: cat, defaultChord: chord, viewAction: view)
        }
        return [
            a(.settings, "Settings…", "Application", .c(",", cmd)),
            a(.quit, "Quit halite", "Application", .c("q", cmd), view: .quit),

            a(.newWindow, "New Window", "File", .c("n", cmd)),
            a(.newTab, "New Tab", "File", .c("t", cmd)),
            a(.closeTab, "Close Tab", "File", .c("w", cmd), view: .closeTab),
            a(.closeWindow, "Close Window", "File", .c("w", cmdShift)),

            a(.copy, "Copy", "Edit", .c("c", cmd)),
            a(.paste, "Paste", "Edit", .c("v", cmd)),
            a(.find, "Find…", "Edit", .c("f", cmd)),
            a(.findNext, "Find Next", "Edit", .c("g", cmd)),
            a(.findPrevious, "Find Previous", "Edit", .c("g", cmdShift)),

            a(.zoomIn, "Zoom In", "View", .c("=", cmd)),
            a(.zoomOut, "Zoom Out", "View", .c("-", cmd)),
            a(.resetZoom, "Actual Size", "View", .c("0", cmd)),
            a(.jumpPreviousPrompt, "Jump to Previous Prompt", "View", .s(.up, cmd), view: .jumpPreviousPrompt),
            a(.jumpNextPrompt, "Jump to Next Prompt", "View", .s(.down, cmd), view: .jumpNextPrompt),
            a(.toggleFullScreen, "Toggle Full Screen", "View", .c("f", cmdCtrl)),

            a(.splitHorizontally, "Split Horizontally", "Split", .c("d", cmd)),
            a(.splitVertically, "Split Vertically", "Split", .c("d", cmdShift)),
            a(.focusPaneLeft, "Focus Pane Left", "Split", .s(.left, cmdOpt)),
            a(.focusPaneRight, "Focus Pane Right", "Split", .s(.right, cmdOpt)),
            a(.focusPaneDown, "Focus Pane Down", "Split", .s(.down, cmdOpt)),
            a(.focusPaneUp, "Focus Pane Up", "Split", .s(.up, cmdOpt)),
            a(.swapPaneLeft, "Swap Pane Left", "Split", .s(.left, cmdShift)),
            a(.swapPaneRight, "Swap Pane Right", "Split", .s(.right, cmdShift)),
            a(.swapPaneDown, "Swap Pane Down", "Split", .s(.down, cmdShift)),
            a(.swapPaneUp, "Swap Pane Up", "Split", .s(.up, cmdShift)),

            a(.nextTab, "Show Next Tab", "Window", .c("]", cmdShift), view: .nextTab),
            a(.previousTab, "Show Previous Tab", "Window", .c("[", cmdShift), view: .previousTab),
        ]
    }()

    static func find(_ id: ID) -> AppAction { all.first { $0.id == id }! }
    /// Stable menu section order for the Settings UI.
    static let categories = ["Application", "File", "Edit", "View", "Split", "Window"]
}

// MARK: - KeyBindingStore — defaults + user overrides, persisted to UserDefaults

/// Resolves the effective chord for each action: user override > disabled > default.
/// Persisted as JSON under `halite.keybindings`. Posts `.haliteKeybindingsChanged`
/// on every mutation so the menu rebuilds and the view hook re-reads live.
final class KeyBindingStore {
    static let shared = KeyBindingStore()
    private static let defaultsKey = "halite.keybindings"

    enum Binding: Codable, Equatable {
        case chord(KeyChord)
        case disabled
    }

    /// Sparse overrides keyed by `AppAction.ID.rawValue`. Absent → use default.
    private var overrides: [String: Binding] = [:]

    private init() { load() }

    // MARK: resolution

    /// Effective chord, or nil if the action is disabled (no shortcut).
    func chord(for id: AppAction.ID) -> KeyChord? {
        switch overrides[id.rawValue] {
        case .chord(let c): return c
        case .disabled: return nil
        case nil: return AppAction.find(id).defaultChord
        }
    }

    func isDefault(_ id: AppAction.ID) -> Bool { overrides[id.rawValue] == nil }
    func isDisabled(_ id: AppAction.ID) -> Bool { overrides[id.rawValue] == .disabled }

    // MARK: mutation

    func set(_ chord: KeyChord, for id: AppAction.ID) {
        if chord == AppAction.find(id).defaultChord { overrides[id.rawValue] = nil }
        else { overrides[id.rawValue] = .chord(chord) }
        persistAndNotify()
    }
    func disable(_ id: AppAction.ID) { overrides[id.rawValue] = .disabled; persistAndNotify() }
    func reset(_ id: AppAction.ID) { overrides[id.rawValue] = nil; persistAndNotify() }
    func resetAll() { overrides.removeAll(); persistAndNotify() }

    /// Actions whose effective chord collides with `chord`, excluding `except`.
    /// (Compared by the chord value; an action disabled or remapped away won't collide.)
    func conflicts(with chord: KeyChord, except: AppAction.ID) -> [AppAction.ID] {
        AppAction.all.compactMap { action in
            guard action.id != except, self.chord(for: action.id) == chord else { return nil }
            return action.id
        }
    }

    // MARK: persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: Binding].self, from: data)
        else { return }
        // Drop entries for unknown ids (catalogue may have changed between versions).
        let known = Set(AppAction.ID.allCases.map { $0.rawValue })
        overrides = decoded.filter { known.contains($0.key) }
    }

    private func persistAndNotify() {
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: .haliteKeybindingsChanged, object: nil)
    }

    // MARK: menu application

    /// Apply the effective chord to a menu item (or clear its shortcut if disabled).
    func apply(_ id: AppAction.ID, to item: NSMenuItem) {
        if let chord = chord(for: id) {
            item.keyEquivalent = chord.menuKeyEquivalent
            item.keyEquivalentModifierMask = chord.modifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // MARK: view-level key hook

    /// Installed on `HaliteSurfaceView.appKeyEquivalentHook` at startup. Resolves
    /// app-level keys (tab nav, prompt jump, close, quit) against the live store.
    /// Returns true if it handled the event.
    func handleViewKeyEquivalent(_ event: NSEvent, on view: HaliteSurfaceView) -> Bool {
        let viewActions: [(AppAction.ID, AppAction.ViewAction)] = [
            (.nextTab, .nextTab), (.previousTab, .previousTab),
            (.jumpPreviousPrompt, .jumpPreviousPrompt), (.jumpNextPrompt, .jumpNextPrompt),
            (.closeTab, .closeTab), (.quit, .quit),
        ]
        for (id, action) in viewActions {
            if let chord = chord(for: id), chord.matches(event) {
                return perform(action, on: view)
            }
        }
        // Fixed convenience accelerators, kept regardless of remaps so muscle memory
        // (and the engine's legacy behavior) survives: ⌘← / ⌘→ switch tabs.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command] {
            switch event.keyCode {
            case 123: return perform(.previousTab, on: view)
            case 124: return perform(.nextTab, on: view)
            default: break
            }
        }
        return false
    }

    private func perform(_ action: AppAction.ViewAction, on view: HaliteSurfaceView) -> Bool {
        switch action {
        case .nextTab:
            return NSApp.sendAction(Selector(("selectNextTab:")), to: nil, from: view)
        case .previousTab:
            return NSApp.sendAction(Selector(("selectPreviousTab:")), to: nil, from: view)
        case .jumpPreviousPrompt:
            view.jumpToPreviousPrompt(view); return true
        case .jumpNextPrompt:
            view.jumpToNextPrompt(view); return true
        case .closeTab:
            if NSApp.sendAction(Selector(("performCloseTab:")), to: nil, from: view) { return true }
            view.window?.performClose(nil); return true
        case .quit:
            NSApp.terminate(nil); return true
        }
    }
}

extension Notification.Name {
    static let haliteKeybindingsChanged = Notification.Name("HaliteKeybindingsChanged")
}
