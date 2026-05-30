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
                }
                // 미리보기 — 선택된 테마의 배경 위에 ANSI 8색 샘플.
                if let theme = HaliteTheme.preset(named: themeName) {
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { i in
                            Color(nsColor: theme.ansi[i])
                                .frame(width: 22, height: 18)
                        }
                    }
                    .padding(4)
                    .background(Color(nsColor: theme.background))
                    .cornerRadius(4)
                }
            }
            Section("Window") {
                Picker("Tab Bar", selection: $tabBarStyleRaw) {
                    ForEach(TabBarStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
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
        if let themeName = d.string(forKey: "halite.theme"),
           let theme = HaliteTheme.preset(named: themeName) {
            config.theme = theme
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
