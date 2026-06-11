import AppKit
import DamsonTerminal
import SwiftUI

/// Minimal SwiftUI settings window. Persisted via @AppStorage; on change, hot-reloads active sessions via notification.
struct DamsonSettingsView: View {
    @AppStorage("damson.fontSize") private var fontSize: Double = 13
    @AppStorage("damson.fontFamily") private var fontFamily: String = FontDiscovery.defaultFamily()
    @AppStorage("damson.scrollbackLines") private var scrollbackLines: Int = 10_000
    @AppStorage("damson.restoreScrollback") private var restoreScrollback: Bool = false
    @AppStorage("damson.tabBarStyle") private var tabBarStyleRaw: String = TabBarStyle.compact.rawValue
    @AppStorage("damson.imeStyle") private var imeStyleRaw: String = IMECompositionStyle.none.rawValue
    @AppStorage("damson.theme") private var themeName: String = DamsonTheme.defaultDark.name
    @AppStorage("damson.autoUpdate") private var autoUpdate: Bool = false
    @AppStorage("damson.cursorBlink") private var cursorBlink: Bool = false
    @AppStorage("damson.animations") private var animations: Bool = true
    @AppStorage("damson.cursorShape") private var cursorShapeRaw: String = Grid.CursorShape.block.rawValue
    @AppStorage("damson.ligatures") private var ligatures: Bool = false
    @AppStorage("damson.showScrollbar") private var showScrollbar: Bool = false
    @AppStorage("damson.tabTransition") private var tabTransitionRaw: String = TabTransitionStyle.slide.rawValue
    @AppStorage("damson.activePaneIndicator") private var activePaneRaw: String = ActivePaneIndicator.dimInactive.rawValue
    @AppStorage("damson.focusFollowsMouse") private var focusFollowsMouse: Bool = true
    @AppStorage("damson.newTabDirectory") private var newTabDirRaw: String = NewTabDirectory.home.rawValue
    @AppStorage("damson.backgroundOpacity") private var backgroundOpacity: Double = 1.0
    @AppStorage("damson.paddingH") private var paddingH: Double = 4
    @AppStorage("damson.paddingV") private var paddingV: Double = 4
    @AppStorage("damson.backgroundBlur") private var backgroundBlur: Bool = false
    @AppStorage("damson.screenEffect") private var screenEffectRaw: String = ScreenEffect.none.rawValue
    @AppStorage("damson.screenEffectIntensity") private var screenEffectIntensity: Double = 1.0
    @AppStorage("damson.glyphAppear") private var glyphAppearRaw: String = GlyphAnimStyle.none.rawValue
    @AppStorage("damson.glyphDisappear") private var glyphDisappearRaw: String = GlyphAnimStyle.none.rawValue
    @AppStorage("damson.pressAndHold") private var pressAndHold: Bool = false
    @AppStorage("damson.copyOnSelect") private var copyOnSelect: Bool = true
    @AppStorage("damson.scrollSpeed") private var scrollSpeed: Double = 1.0
    @AppStorage("damson.tabBarTransparent") private var tabBarTransparent: Bool = false

    private let nerdFonts = FontDiscovery.nerdFontFamilies()
    private let regularFonts = FontDiscovery.regularMonospaceFamilies()

    var body: some View {
        TabView {
            appearanceTab.tabItem { Label("Appearance", systemImage: "paintbrush") }
            windowTab.tabItem { Label("Window", systemImage: "macwindow") }
            effectsTab.tabItem { Label("Effects", systemImage: "sparkles") }
            terminalTab.tabItem { Label("Terminal", systemImage: "terminal") }
            KeysSettingsTab().tabItem { Label("Keys", systemImage: "keyboard") }
            advancedTab.tabItem { Label("Advanced", systemImage: "gearshape") }
        }
        .frame(width: 540, height: 600)
        .onChange(of: fontSize) { _ in postChanged() }
        .onChange(of: fontFamily) { _ in postChanged() }
        .onChange(of: scrollbackLines) { _ in postChanged() }
        .onChange(of: tabBarStyleRaw) { _ in postChanged() }
        .onChange(of: imeStyleRaw) { _ in postChanged() }
        .onChange(of: cursorBlink) { _ in postChanged() }
        .onChange(of: animations) { _ in postChanged() }
        .onChange(of: cursorShapeRaw) { _ in postChanged() }
        .onChange(of: ligatures) { _ in postChanged() }
        .onChange(of: showScrollbar) { _ in postChanged() }
        .onChange(of: activePaneRaw) { _ in postChanged() }
        .onChange(of: backgroundOpacity) { _ in postChanged() }
        .onChange(of: paddingH) { _ in postChanged() }
        .onChange(of: paddingV) { _ in postChanged() }
        .onChange(of: backgroundBlur) { _ in postChanged() }
        .onChange(of: tabBarTransparent) { _ in postChanged() }
        .onChange(of: screenEffectRaw) { _ in postChanged() }
        .onChange(of: screenEffectIntensity) { _ in postChanged() }
        .onChange(of: glyphAppearRaw) { _ in postChanged() }
        .onChange(of: glyphDisappearRaw) { _ in postChanged() }
        .onChange(of: copyOnSelect) { _ in postChanged() }
        .onChange(of: scrollSpeed) { _ in postChanged() }
        .onChange(of: pressAndHold) { v in
            // Update the system key immediately (full effect after restart). Off = key repeat, on = accent popup.
            UserDefaults.standard.set(v, forKey: "ApplePressAndHoldEnabled")
        }
        .onChange(of: themeName) { _ in postChanged() }
        .onChange(of: autoUpdate) { _ in
            // Apply to the Sparkle updater immediately (separate from the config hot-reload path).
            DamsonUpdater.shared.applyAutomaticChecksSetting()
        }
    }

    // MARK: - Tabs

    private var appearanceTab: some View {
        Form {
            Section("Font") {
                HStack {
                    Text("Size")
                    Spacer()
                    Stepper(value: $fontSize, in: 8...32, step: 1) {
                        Text("\(Int(fontSize)) pt").monospacedDigit().frame(minWidth: 50)
                    }
                }
                Picker("Family", selection: $fontFamily) {
                    if !nerdFonts.isEmpty {
                        Section("Nerd Fonts (powerline/icon glyphs)") {
                            ForEach(nerdFonts, id: \.self) { f in
                                Text(f).tag(f)
                            }
                        }
                    }
                    Section("Monospaced") {
                        ForEach(regularFonts, id: \.self) { f in
                            Text(f).tag(f)
                        }
                    }
                }
                // Preview — a glyph sample in the selected font (includes powerline separators, icons, etc.).
                HStack {
                    Text("Preview")
                    Spacer()
                    Text("123 abc ❯  ")
                        .font(.custom(fontFamily, size: CGFloat(fontSize)))
                        .frame(width: 220, alignment: .leading)
                }
                Toggle("Ligatures", isOn: $ligatures)
                Text("Programming ligatures like => != -> ===. Shown only when the font supports them (Fira Code, JetBrains Mono, D2CodingLigature, etc.).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Theme") {
                // Browsing the list with ↑↓ instantly updates the large preview on the right and the live terminal.
                ThemeBrowser(themeName: $themeName)
                if themeName == DamsonTheme.customName {
                    CustomThemeEditor(onChange: { postChanged() })
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var windowTab: some View {
        Form {
            Section("Window") {
                Picker("Tab Bar", selection: $tabBarStyleRaw) {
                    ForEach(TabBarStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Toggle("Transparent tab bar", isOn: $tabBarTransparent)
                Text("When off (default), the tab bar is a solid theme background color; when on, it's frosted-glass translucent.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Toggle("Show Scrollbar", isOn: $showScrollbar)
                Picker("Tab Transition", selection: $tabTransitionRaw) {
                    ForEach(TabTransitionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Picker("Active Pane", selection: $activePaneRaw) {
                    ForEach(ActivePaneIndicator.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Toggle("Focus follows mouse", isOn: $focusFollowsMouse)
                Text("When on (default), the pane under the mouse cursor activates without a click. Only meaningful in split windows.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("New Tab Directory", selection: $newTabDirRaw) {
                    ForEach(NewTabDirectory.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                Text("Starting location for new tabs. Splits always inherit the current pane's directory. Shell integration (zsh OSC 7) is injected automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Padding") {
                HStack {
                    Text("Horizontal")
                    Slider(value: $paddingH, in: 0...32, step: 1)
                    Text("\(Int(paddingH)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Text("Vertical")
                    Slider(value: $paddingV, in: 0...32, step: 1)
                    Text("\(Int(paddingV)) pt")
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text("Inner space between the window edges and the terminal content. Applies live; the grid size (cols×rows) adjusts to the remaining area.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Transparency") {
                HStack {
                    Text("Background Opacity")
                    Slider(value: $backgroundOpacity, in: 0.2...1.0)
                    Text("\(Int((backgroundOpacity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Background Blur (frosted glass)", isOn: $backgroundBlur)
                    .disabled(backgroundOpacity >= 1.0)
                Text("Lowering the background opacity lets what's behind the window show through. Blur frosts that backdrop like frosted glass (no effect at 100% opacity).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var effectsTab: some View {
        Form {
            Section("Screen Effect") {
                Picker("Effect", selection: $screenEffectRaw) {
                    ForEach(ScreenEffect.allCases, id: \.rawValue) { e in
                        Text(e.displayName).tag(e.rawValue)
                    }
                }
                HStack {
                    Text("Intensity")
                    Slider(value: $screenEffectIntensity, in: 0.2...1.0)
                    Text("\(Int((screenEffectIntensity * 100).rounded()))%")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                .disabled(screenEffectRaw == ScreenEffect.none.rawValue)
                Text("An effect applied across the whole screen — CRT, phosphor, bloom, and more (static — no extra cost when idle).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Text Animation") {
                Picker("On Type (appear)", selection: $glyphAppearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.appearDisplayName()).tag(s.rawValue)
                    }
                }
                Picker("On Delete (disappear)", selection: $glyphDisappearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.disappearDisplayName()).tag(s.rawValue)
                    }
                }
                Text("A short animation played when glyphs appear or are erased near the cursor. Applies only to typing and deleting (excludes scrolling and bulk output).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var terminalTab: some View {
        Form {
            Section("Scrollback") {
                HStack {
                    Text("Lines")
                    Spacer()
                    Stepper(value: $scrollbackLines, in: 1000...200_000, step: 1000) {
                        Text("\(scrollbackLines)").monospacedDigit().frame(minWidth: 70)
                    }
                }
                Toggle("Restore scrollback on relaunch", isOn: $restoreScrollback)
                Text("Saves each pane's scrollback text on quit and shows it after relaunch (colors not preserved). Compact-mode windows only.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section("Cursor") {
                Picker("Shape", selection: $cursorShapeRaw) {
                    Text("Block").tag(Grid.CursorShape.block.rawValue)
                    Text("Underline").tag(Grid.CursorShape.underline.rawValue)
                    Text("Bar").tag(Grid.CursorShape.bar.rawValue)
                }
                Toggle("Blink", isOn: $cursorBlink)
                Toggle("Animations", isOn: $animations)
            }
            Section("IME Composition (Korean / Japanese / Chinese composition display)") {
                Picker("Style", selection: $imeStyleRaw) {
                    ForEach(IMECompositionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
            }
            Section("Selection") {
                Toggle("Copy on select", isOn: $copyOnSelect)
                Text("When on (default), selecting text (drag, or double-/triple-click) copies it to the clipboard immediately.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Scroll") {
                HStack {
                    Text("TUI Scroll Speed")
                    Slider(value: $scrollSpeed, in: 0.25...4.0)
                    Text(String(format: "%.2fx", scrollSpeed))
                        .monospacedDigit()
                        .frame(width: 48, alignment: .trailing)
                }
                Text("Trackpad scroll speed in mouse-tracking TUIs like Claude Code and tmux. Lower is slower. (No effect on normal scrollback scrolling.)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Keyboard") {
                Toggle("Press and hold for accents", isOn: $pressAndHold)
                Text("When off (default), every key repeats on press-and-hold (the terminal standard). When on, macOS default behavior applies — some keys like a/e show an accent popup on hold instead of repeating. Changes take effect after an app restart.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var advancedTab: some View {
        Form {
            Section("Updates") {
                Toggle("Automatic Updates", isOn: $autoUpdate)
                Text("When on, checks for new versions in the background. You can always check manually via \"Check for Updates…\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .damsonSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let damsonSettingsChanged = Notification.Name("DamsonSettingsChanged")
}

/// Theme browser — a list on the left (browse with ↑↓) plus a large preview on the right.
/// When the selection changes, $themeName (@AppStorage) updates and the parent view's
/// onChange(themeName) pushes a hot-reload to the live sessions (preview = live terminal, updated instantly).
struct ThemeBrowser: View {
    @Binding var themeName: String
    @FocusState private var listFocused: Bool

    private struct Entry: Identifiable {
        let name: String
        let theme: DamsonTheme
        var id: String { name }
    }

    private var entries: [Entry] {
        DamsonTheme.presets.map { Entry(name: $0.name, theme: $0) }
            + [Entry(name: DamsonTheme.customName, theme: CustomTheme.load().toTheme())]
    }

    private var selectedTheme: DamsonTheme {
        if themeName == DamsonTheme.customName { return CustomTheme.load().toTheme() }
        return DamsonTheme.preset(named: themeName) ?? .defaultDark
    }

    /// Move the selection by delta from the current position (clamped to range). For ↑↓ key browsing.
    private func moveSelection(_ delta: Int) {
        let all = entries
        guard !all.isEmpty else { return }
        let idx = all.firstIndex { $0.name == themeName } ?? 0
        let next = min(max(idx + delta, 0), all.count - 1)
        themeName = all[next].name
    }

    private func row(_ e: Entry) -> some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(nsColor: e.theme.background))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.35), lineWidth: 0.5))
            Text(e.name).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(e.name == themeName
                      ? Color.accentColor.opacity(listFocused ? 0.35 : 0.22)
                      : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { themeName = e.name; listFocused = true }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(entries) { e in row(e).id(e.name) }
                    }
                    .padding(4)
                }
                .frame(width: 190, height: 210)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(nsColor: .textBackgroundColor)))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(listFocused ? Color.accentColor.opacity(0.8)
                                            : Color.secondary.opacity(0.3),
                                lineWidth: listFocused ? 1.5 : 0.5))
                .focusable()
                .focusRingDisabled()
                .focused($listFocused)
                .onMoveCommand { dir in
                    switch dir {
                    case .up: moveSelection(-1)
                    case .down: moveSelection(1)
                    default: break
                    }
                }
                .onChange(of: themeName) { name in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(name, anchor: .center)
                    }
                }
                .onAppear { proxy.scrollTo(themeName, anchor: .center) }
            }

            ThemePreview(theme: selectedTheme)
                .frame(maxWidth: .infinity)
                .frame(height: 210)
        }
    }
}

private extension View {
    /// Remove the default blue focus ring (macOS 14+). On 13 it's left as-is (compile-only guarantee).
    @ViewBuilder func focusRingDisabled() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
    }
}

/// Mini terminal preview — colored sample prompt/output over the background, plus 16 ANSI color swatches.
struct ThemePreview: View {
    let theme: DamsonTheme
    private func col(_ i: Int) -> Color { Color(nsColor: theme.ansi[i]) }
    private var fg: Color { Color(nsColor: theme.foreground) }

    private func swatch(_ i: Int) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(col(i))
            .frame(maxWidth: .infinity).frame(height: 14)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Group {
                Text("➜ ").foregroundColor(col(2))
                    + Text("~/dev/damson ").foregroundColor(col(4))
                    + Text("git:(").foregroundColor(fg)
                    + Text("main").foregroundColor(col(1))
                    + Text(")").foregroundColor(fg)
                Text("$ ").foregroundColor(col(2))
                    + Text("ls ").foregroundColor(fg)
                    + Text("-la").foregroundColor(col(3))
                Text("# building project…").foregroundColor(col(8))
                Text("hello ").foregroundColor(fg)
                    + Text("world ").foregroundColor(col(5))
                    + Text("✓").foregroundColor(col(6))
            }
            .font(.system(size: 11, design: .monospaced))

            Spacer(minLength: 6)
            Text("ANSI").font(.system(size: 9)).foregroundColor(fg.opacity(0.6))
            HStack(spacing: 3) { ForEach(0..<8, id: \.self) { swatch($0) } }
            HStack(spacing: 3) { ForEach(8..<16, id: \.self) { swatch($0) } }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: theme.background))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// ColorPicker editor for the 19 custom-theme colors (background/foreground/cursor + 16 ANSI).
/// Saves to UserDefaults immediately on change and triggers a hot-reload via onChange.
struct CustomThemeEditor: View {
    let onChange: () -> Void
    @State private var data: CustomThemeData = CustomTheme.load()

    private static let ansiNames = [
        "0 Black", "1 Red", "2 Green", "3 Yellow",
        "4 Blue", "5 Magenta", "6 Cyan", "7 White",
        "8 Br Black", "9 Br Red", "10 Br Green", "11 Br Yellow",
        "12 Br Blue", "13 Br Magenta", "14 Br Cyan", "15 Br White",
    ]

    var body: some View {
        // Starting point for copying colors from a preset.
        HStack {
            Text("Start from")
            Spacer()
            Menu("Copy preset…") {
                ForEach(DamsonTheme.presets, id: \.name) { theme in
                    Button(theme.name) { copyFrom(theme) }
                }
            }
            .frame(width: 140)
        }

        ColorPicker("Background", selection: hexBinding(\.background))
        ColorPicker("Foreground", selection: hexBinding(\.foreground))
        ColorPicker("Cursor", selection: hexBinding(\.cursor))

        ForEach(0..<16, id: \.self) { i in
            ColorPicker(Self.ansiNames[i], selection: ansiBinding(i))
        }
    }

    private func copyFrom(_ theme: DamsonTheme) {
        let h = theme.toHexColors()
        data = CustomThemeData(background: h.bg, foreground: h.fg, cursor: h.cursor, ansi: h.ansi)
        CustomTheme.save(data)
        onChange()
    }

    private func hexBinding(_ kp: WritableKeyPath<CustomThemeData, String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: data[keyPath: kp]) ?? .black) },
            set: { c in
                data[keyPath: kp] = NSColor(c).hexString
                CustomTheme.save(data)
                onChange()
            }
        )
    }

    private func ansiBinding(_ i: Int) -> Binding<Color> {
        Binding(
            get: {
                guard i < data.ansi.count else { return .black }
                return Color(nsColor: NSColor(hexString: data.ansi[i]) ?? .black)
            },
            set: { c in
                while data.ansi.count <= i { data.ansi.append("#000000") }
                data.ansi[i] = NSColor(c).hexString
                CustomTheme.save(data)
                onChange()
            }
        )
    }
}

extension DamsonConfig {
    /// Returns a DamsonConfig populated from the settings saved in UserDefaults. Unset keys use defaults.
    static func fromUserDefaults() -> DamsonConfig {
        let d = UserDefaults.standard
        var config = DamsonConfig()
        let fs = d.double(forKey: "damson.fontSize")
        if fs >= 6 { config.fontSize = CGFloat(fs) }
        if let family = d.string(forKey: "damson.fontFamily"), !family.isEmpty {
            config.fontFamily = family
        } else {
            // Unset → the default chosen by FontDiscovery (Nerd Font preferred).
            config.fontFamily = FontDiscovery.defaultFamily()
        }
        let sb = d.integer(forKey: "damson.scrollbackLines")
        if sb > 0 { config.scrollbackLines = sb }
        if let raw = d.string(forKey: "damson.imeStyle"),
           let style = IMECompositionStyle(rawValue: raw) {
            config.imeStyle = style
        }
        config.cursorBlink = d.bool(forKey: "damson.cursorBlink")
        config.ligatures = d.bool(forKey: "damson.ligatures")
        config.showScrollbar = d.bool(forKey: "damson.showScrollbar")
        if let h = d.object(forKey: "damson.paddingH") as? Double {
            config.padding.width = CGFloat(max(0, min(64, h)))
        }
        if let v = d.object(forKey: "damson.paddingV") as? Double {
            config.padding.height = CGFloat(max(0, min(64, v)))
        }
        if let o = d.object(forKey: "damson.backgroundOpacity") as? Double {
            config.backgroundOpacity = CGFloat(max(0.2, min(1.0, o)))
        }
        config.backgroundBlur = d.bool(forKey: "damson.backgroundBlur")
        if let raw = d.string(forKey: "damson.screenEffect"),
           let e = ScreenEffect(rawValue: raw) {
            config.screenEffect = e
        }
        if let i = d.object(forKey: "damson.screenEffectIntensity") as? Double {
            config.screenEffectIntensity = CGFloat(max(0.2, min(1.0, i)))
        }
        if let raw = d.string(forKey: "damson.glyphAppear"),
           let s = GlyphAnimStyle(rawValue: raw) {
            config.glyphAppear = s
        }
        if let raw = d.string(forKey: "damson.glyphDisappear"),
           let s = GlyphAnimStyle(rawValue: raw) {
            config.glyphDisappear = s
        }
        config.copyOnSelect = d.object(forKey: "damson.copyOnSelect") as? Bool ?? true
        if let s = d.object(forKey: "damson.scrollSpeed") as? Double {
            config.scrollSpeed = CGFloat(max(0.25, min(4.0, s)))
        }
        config.animations = d.object(forKey: "damson.animations") as? Bool ?? true
        if let raw = d.string(forKey: "damson.cursorShape"),
           let shape = Grid.CursorShape(rawValue: raw) {
            config.cursorShape = shape
        }
        if let themeName = d.string(forKey: "damson.theme") {
            if themeName == DamsonTheme.customName {
                config.theme = CustomTheme.load().toTheme()
            } else if let theme = DamsonTheme.preset(named: themeName) {
                config.theme = theme
            }
        }
        // A new terminal's starting directory is the user's home directory. Otherwise it would
        // inherit the working directory Damson was launched from (e.g. an Xcode build, /tmp, a
        // command run from somewhere), forcing a cd every time. (The caller may override this
        // under an "inherit current directory" policy.)
        config.cwd = NSHomeDirectory()
        // Inject shell integration so the shell reports cwd via OSC 7 (zsh only). The source of split/new-tab cwd inheritance.
        config.env.merge(
            ShellIntegration.envOverrides(forShellPath: config.argv.first)
        ) { _, new in new }
        return config
    }
}

extension IMECompositionStyle {
    var displayName: String {
        switch self {
        case .none: return "None (no display, default)"
        case .underline: return "Underline (thin)"
        case .thickUnderline: return "Thick Underline (thick)"
        case .background: return "Background (highlight)"
        case .both: return "Background + Underline"
        }
    }
}
