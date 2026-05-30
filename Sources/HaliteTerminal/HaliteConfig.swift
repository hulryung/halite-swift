import AppKit
import Foundation

/// IME 조합 중인 텍스트(한글 / 일본어 / 중국어 등)의 시각적 표시 방식.
/// `HaliteConfig.imeStyle`로 설정.
public enum IMECompositionStyle: String, Codable, CaseIterable, Sendable {
    /// 얇은 underline만 (가장 subtle, 디폴트).
    case underline
    /// 두꺼운 underline. macOS 기본 IME 표시와 비슷.
    case thickUnderline
    /// 배경 하이라이트만.
    case background
    /// 배경 + 두꺼운 underline (이전 동작).
    case both
    /// 표시 없음 — 텍스트만 다른 색으로.
    case none
}

/// 한 `HaliteSession`에 주입되는 설정 스냅샷.
/// 값 타입. 변경하려면 새 값을 만들어 `HaliteSession.updateConfig(_:)` 호출.
public struct HaliteConfig {
    public var fontFamily: String
    public var fontSize: CGFloat
    public var theme: HaliteTheme
    public var scrollbackBytes: Int
    public var scrollbackLines: Int
    public var imeStyle: IMECompositionStyle

    // 색은 theme에서 파생 — 기존 호출처 호환용 computed property.
    public var backgroundColor: NSColor { theme.background }
    public var foregroundColor: NSColor { theme.foreground }
    public var cursorColor: NSColor { theme.cursor }

    // PTY spawn
    public var argv: [String]
    public var env: [String: String]
    public var cwd: String?

    public init(
        fontFamily: String = "Menlo",
        fontSize: CGFloat = 13,
        theme: HaliteTheme = .defaultDark,
        scrollbackBytes: Int = 10_000_000,
        scrollbackLines: Int = 10_000,
        imeStyle: IMECompositionStyle = .none,
        argv: [String] = HaliteConfig.defaultArgv(),
        env: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.theme = theme
        self.scrollbackBytes = scrollbackBytes
        self.scrollbackLines = scrollbackLines
        self.imeStyle = imeStyle
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    public static func defaultArgv() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell]
    }
}
