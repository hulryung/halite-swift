import AppKit
import HaliteTerminal
import SwiftUI

/// SwiftUI 최소 설정창. @AppStorage로 영속, 변경 시 notification으로 활성 세션에 hot-reload.
struct HaliteSettingsView: View {
    @AppStorage("halite.fontSize") private var fontSize: Double = 13
    @AppStorage("halite.fontFamily") private var fontFamily: String = "Menlo"
    @AppStorage("halite.scrollbackLines") private var scrollbackLines: Int = 10_000
    @AppStorage("halite.tabBarStyle") private var tabBarStyleRaw: String = TabBarStyle.compact.rawValue

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
                HStack {
                    Text("Family")
                    Spacer()
                    TextField("", text: $fontFamily).frame(width: 180)
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
            Section("Window") {
                Picker("Tab Bar", selection: $tabBarStyleRaw) {
                    ForEach(TabBarStyle.allCases, id: \.rawValue) { style in
                        Text(style.displayName).tag(style.rawValue)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 460, height: 360)
        .onChange(of: fontSize) { _ in postChanged() }
        .onChange(of: fontFamily) { _ in postChanged() }
        .onChange(of: scrollbackLines) { _ in postChanged() }
        .onChange(of: tabBarStyleRaw) { _ in postChanged() }
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
        }
        let sb = d.integer(forKey: "halite.scrollbackLines")
        if sb > 0 { config.scrollbackLines = sb }
        return config
    }
}
