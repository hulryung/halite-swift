import AppKit
import DamsonTerminal
import SwiftUI

/// SwiftUI 최소 설정창. @AppStorage로 영속, 변경 시 notification으로 활성 세션에 hot-reload.
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
        .onChange(of: backgroundBlur) { _ in postChanged() }
        .onChange(of: tabBarTransparent) { _ in postChanged() }
        .onChange(of: screenEffectRaw) { _ in postChanged() }
        .onChange(of: screenEffectIntensity) { _ in postChanged() }
        .onChange(of: glyphAppearRaw) { _ in postChanged() }
        .onChange(of: glyphDisappearRaw) { _ in postChanged() }
        .onChange(of: copyOnSelect) { _ in postChanged() }
        .onChange(of: scrollSpeed) { _ in postChanged() }
        .onChange(of: pressAndHold) { v in
            // 시스템 키 즉시 갱신(완전 적용은 재시작 후). 끄면 키 반복, 켜면 악센트 팝업.
            UserDefaults.standard.set(v, forKey: "ApplePressAndHoldEnabled")
        }
        .onChange(of: themeName) { _ in postChanged() }
        .onChange(of: autoUpdate) { _ in
            // Sparkle updater에 즉시 반영 (config hot-reload 경로와 별개).
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
                // 미리보기 — 선택된 폰트로 글리프 샘플 (powerline 분리자, 아이콘 등 포함).
                HStack {
                    Text("Preview")
                    Spacer()
                    Text("123 abc ❯  ")
                        .font(.custom(fontFamily, size: CGFloat(fontSize)))
                        .frame(width: 220, alignment: .leading)
                }
                Toggle("Ligatures", isOn: $ligatures)
                Text("=> != -> === 등 프로그래밍 리가처. 폰트가 지원할 때만 보입니다 (Fira Code, JetBrains Mono, D2CodingLigature 등).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Theme") {
                // 리스트에서 ↑↓로 훑으면 오른쪽 큰 미리보기 + 실제 터미널이 즉시 바뀐다.
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
                Text("끄면(기본) 탭바가 테마 배경색의 솔리드, 켜면 frosted-glass 투명.")
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
                Text("켜면(기본) 클릭 없이 마우스 커서가 올라간 pane이 활성화됩니다. 분할(split)된 창에서만 의미가 있습니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("New Tab Directory", selection: $newTabDirRaw) {
                    ForEach(NewTabDirectory.allCases, id: \.rawValue) { policy in
                        Text(policy.displayName).tag(policy.rawValue)
                    }
                }
                Text("새 탭 시작 위치. split(분할)은 항상 현재 pane의 디렉토리를 상속합니다. 셸 통합(zsh OSC 7)이 자동 주입됩니다.")
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
                Text("배경 불투명도를 낮추면 창 뒤가 비칩니다. 블러는 그 뒤를 frosted-glass로 흐립니다(불투명도 100%면 효과 없음).")
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
                Text("화면 전체에 입히는 효과. CRT/인광/블룸 등(정적 — idle 시 추가 비용 없음).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Text Animation") {
                Picker("On Type (생성)", selection: $glyphAppearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.appearDisplayName()).tag(s.rawValue)
                    }
                }
                Picker("On Delete (소멸)", selection: $glyphDisappearRaw) {
                    ForEach(GlyphAnimStyle.allCases, id: \.rawValue) { s in
                        Text(s.disappearDisplayName()).tag(s.rawValue)
                    }
                }
                Text("커서 근처에서 글자가 생기거나 지워질 때 짧게 재생되는 애니메이션. 타이핑/지우기에만 적용(스크롤·대량 출력 제외).")
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
            Section("IME Composition (한글/일본어/중국어 조합 표시)") {
                Picker("Style", selection: $imeStyleRaw) {
                    ForEach(IMECompositionStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
            }
            Section("Selection") {
                Toggle("Copy on select", isOn: $copyOnSelect)
                Text("켜면(기본) 텍스트를 선택(드래그/더블·트리플 클릭)하는 즉시 클립보드에 복사됩니다.")
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
                Text("Claude Code·tmux 등 마우스 추적 TUI에서 트랙패드 스크롤 속도. 낮추면 느리게. (일반 scrollback 스크롤엔 영향 없음)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Section("Keyboard") {
                Toggle("Press and hold for accents", isOn: $pressAndHold)
                Text("끄면(기본) 모든 키가 길게 누름에 반복 입력됩니다(터미널 표준). 켜면 macOS 기본 동작 — a·e 등 일부 키는 길게 누를 때 악센트 팝업이 떠 반복이 안 됩니다. 변경은 앱 재시작 후 적용.")
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
                Text("켜면 백그라운드에서 새 버전을 확인합니다. \"Check for Updates…\"로 언제든 수동 확인 가능.")
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

/// 테마 브라우저 — 왼쪽 리스트(↑↓로 훑기) + 오른쪽 큰 미리보기. 선택이 바뀌면
/// $themeName(@AppStorage)이 갱신되고, 상위 뷰의 onChange(themeName)가 실제 세션에
/// hot-reload를 푸시한다(미리보기 = 실제 터미널도 즉시 반영).
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

    /// 현재 선택에서 delta만큼 이동(범위 clamp). ↑↓ 키 브라우징.
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
    /// 기본 파란 포커스 링 제거(macOS 14+). 13에선 그대로 둔다(컴파일만 보장).
    @ViewBuilder func focusRingDisabled() -> some View {
        if #available(macOS 14.0, *) { self.focusEffectDisabled() } else { self }
    }
}

/// 미니 터미널 미리보기 — 배경 위에 색이 들어간 샘플 프롬프트/출력 + ANSI 16색 스와치.
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

/// 커스텀 테마 19색(배경/글자/커서 + ANSI 16) ColorPicker 에디터.
/// 변경 즉시 UserDefaults에 저장 + onChange로 hot-reload 트리거.
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
        // 프리셋에서 색 복사 시작점.
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
    /// UserDefaults에 저장된 설정값으로 채워진 DamsonConfig 반환. 미설정 키는 기본값.
    static func fromUserDefaults() -> DamsonConfig {
        let d = UserDefaults.standard
        var config = DamsonConfig()
        let fs = d.double(forKey: "damson.fontSize")
        if fs >= 6 { config.fontSize = CGFloat(fs) }
        if let family = d.string(forKey: "damson.fontFamily"), !family.isEmpty {
            config.fontFamily = family
        } else {
            // 미설정 → FontDiscovery가 정한 디폴트 (Nerd Font 우선).
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
        // 새 터미널의 시작 디렉토리는 사용자의 홈 디렉토리. 그렇지 않으면 damson을 띄운
        // working directory(예: Xcode 빌드, /tmp, 어딘가에서 cmd 실행)가 그대로 상속되어
        // 매번 cd를 쳐야 함. (호출처에서 "현재 디렉토리 상속" 정책 시 덮어쓸 수 있음.)
        config.cwd = NSHomeDirectory()
        // 셸이 OSC 7로 cwd를 보고하도록 셸 통합 주입(zsh만). split/새 탭 cwd 상속의 소스.
        config.env.merge(
            ShellIntegration.envOverrides(forShellPath: config.argv.first)
        ) { _, new in new }
        return config
    }
}

extension IMECompositionStyle {
    var displayName: String {
        switch self {
        case .none: return "None (표시 없음, 디폴트)"
        case .underline: return "Underline (얇게)"
        case .thickUnderline: return "Thick Underline (두껍게)"
        case .background: return "Background (배경)"
        case .both: return "Background + Underline"
        }
    }
}
