import AppKit
import HaliteTerminal
import SwiftUI

/// SwiftUI 최소 설정창. @AppStorage로 영속, 변경 시 notification으로 활성 세션에 hot-reload.
struct HaliteSettingsView: View {
    @AppStorage("halite.fontSize") private var fontSize: Double = 13
    @AppStorage("halite.fontFamily") private var fontFamily: String = FontDiscovery.defaultFamily()
    @AppStorage("halite.scrollbackLines") private var scrollbackLines: Int = 10_000
    @AppStorage("halite.tabBarStyle") private var tabBarStyleRaw: String = TabBarStyle.compact.rawValue
    @AppStorage("halite.imeStyle") private var imeStyleRaw: String = IMECompositionStyle.none.rawValue
    @AppStorage("halite.theme") private var themeName: String = HaliteTheme.defaultDark.name
    @AppStorage("halite.autoUpdate") private var autoUpdate: Bool = false
    @AppStorage("halite.cursorBlink") private var cursorBlink: Bool = false
    @AppStorage("halite.animations") private var animations: Bool = true
    @AppStorage("halite.cursorShape") private var cursorShapeRaw: String = Grid.CursorShape.block.rawValue
    @AppStorage("halite.ligatures") private var ligatures: Bool = false
    @AppStorage("halite.showScrollbar") private var showScrollbar: Bool = false

    private let nerdFonts = FontDiscovery.nerdFontFamilies()
    private let regularFonts = FontDiscovery.regularMonospaceFamilies()

    var body: some View {
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
            Section("Scrollback") {
                HStack {
                    Text("Lines")
                    Spacer()
                    Stepper(value: $scrollbackLines, in: 1000...200_000, step: 1000) {
                        Text("\(scrollbackLines)").monospacedDigit().frame(minWidth: 70)
                    }
                }
            }
            Section("Theme") {
                Picker("Color Theme", selection: $themeName) {
                    ForEach(HaliteTheme.presets, id: \.name) { theme in
                        Text(theme.name).tag(theme.name)
                    }
                    Text("Custom").tag(HaliteTheme.customName)
                }
                // 미리보기 — 현재 선택된 테마의 배경 위에 ANSI 8색 샘플.
                let previewTheme = themeName == HaliteTheme.customName
                    ? CustomTheme.load().toTheme()
                    : (HaliteTheme.preset(named: themeName) ?? .defaultDark)
                HStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { i in
                        Color(nsColor: previewTheme.ansi[i]).frame(width: 22, height: 18)
                    }
                }
                .padding(4)
                .background(Color(nsColor: previewTheme.background))
                .cornerRadius(4)

                if themeName == HaliteTheme.customName {
                    CustomThemeEditor(onChange: { postChanged() })
                }
            }
            Section("Window") {
                Picker("Tab Bar", selection: $tabBarStyleRaw) {
                    ForEach(TabBarStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
                Toggle("Show Scrollbar", isOn: $showScrollbar)
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
            Section("Updates") {
                Toggle("Automatic Updates", isOn: $autoUpdate)
                Text("켜면 백그라운드에서 새 버전을 확인합니다. \"Check for Updates…\"로 언제든 수동 확인 가능.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460, height: 480)
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
        .onChange(of: themeName) { _ in postChanged() }
        .onChange(of: autoUpdate) { _ in
            // Sparkle updater에 즉시 반영 (config hot-reload 경로와 별개).
            HaliteUpdater.shared.applyAutomaticChecksSetting()
        }
    }

    private func postChanged() {
        NotificationCenter.default.post(name: .haliteSettingsChanged, object: nil)
    }
}

extension Notification.Name {
    static let haliteSettingsChanged = Notification.Name("HaliteSettingsChanged")
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
                ForEach(HaliteTheme.presets, id: \.name) { theme in
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

    private func copyFrom(_ theme: HaliteTheme) {
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

extension HaliteConfig {
    /// UserDefaults에 저장된 설정값으로 채워진 HaliteConfig 반환. 미설정 키는 기본값.
    static func fromUserDefaults() -> HaliteConfig {
        let d = UserDefaults.standard
        var config = HaliteConfig()
        let fs = d.double(forKey: "halite.fontSize")
        if fs >= 6 { config.fontSize = CGFloat(fs) }
        if let family = d.string(forKey: "halite.fontFamily"), !family.isEmpty {
            config.fontFamily = family
        } else {
            // 미설정 → FontDiscovery가 정한 디폴트 (Nerd Font 우선).
            config.fontFamily = FontDiscovery.defaultFamily()
        }
        let sb = d.integer(forKey: "halite.scrollbackLines")
        if sb > 0 { config.scrollbackLines = sb }
        if let raw = d.string(forKey: "halite.imeStyle"),
           let style = IMECompositionStyle(rawValue: raw) {
            config.imeStyle = style
        }
        config.cursorBlink = d.bool(forKey: "halite.cursorBlink")
        config.ligatures = d.bool(forKey: "halite.ligatures")
        config.showScrollbar = d.bool(forKey: "halite.showScrollbar")
        config.animations = d.object(forKey: "halite.animations") as? Bool ?? true
        if let raw = d.string(forKey: "halite.cursorShape"),
           let shape = Grid.CursorShape(rawValue: raw) {
            config.cursorShape = shape
        }
        if let themeName = d.string(forKey: "halite.theme") {
            if themeName == HaliteTheme.customName {
                config.theme = CustomTheme.load().toTheme()
            } else if let theme = HaliteTheme.preset(named: themeName) {
                config.theme = theme
            }
        }
        // 새 터미널의 시작 디렉토리는 사용자의 홈 디렉토리. 그렇지 않으면 halite를 띄운
        // working directory(예: Xcode 빌드, /tmp, 어딘가에서 cmd 실행)가 그대로 상속되어
        // 매번 cd를 쳐야 함.
        config.cwd = NSHomeDirectory()
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
