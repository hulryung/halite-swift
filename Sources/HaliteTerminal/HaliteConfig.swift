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
    public var cursorBlink: Bool
    /// 탭/페인 라이프사이클 모션을 켤지. 기본 ON. macOS Reduce Motion은 이와 무관하게 항상 우선.
    public var animations: Bool
    /// 기본 cursor 모양. 셸/앱이 DECSCUSR로 바꾸면 그게 우선, ps=0(reset)이면 이 값으로 복귀.
    public var cursorShape: Grid.CursorShape

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
        cursorBlink: Bool = false,
        animations: Bool = true,
        cursorShape: Grid.CursorShape = .block,
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
        self.cursorBlink = cursorBlink
        self.animations = animations
        self.cursorShape = cursorShape
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    public static func defaultArgv() -> [String] {
        // 로그인 셸(-l)로 spawn — 그래야 /etc/zprofile의 path_helper가 돌아서
        // Homebrew(/opt/homebrew/bin) 등이 PATH에 들어감. GUI 앱(LaunchServices로
        // 실행)이 spawn하는 셸은 기본적으로 non-login이라 PATH가 시스템 기본만 잡혀
        // starship 등 brew 설치 도구를 "command not found"로 못 찾는 문제가 있음.
        // Terminal.app/iTerm2도 로그인 셸로 띄운다.
        return [loginShellPath(), "-l"]
    }

    /// 사용자의 로그인 셸 경로. SHELL 환경변수 우선, GUI 앱에선 비어있을 수 있으므로
    /// passwd DB(getpwuid)로 폴백, 그래도 없으면 /bin/zsh.
    public static func loginShellPath() -> String {
        if let s = ProcessInfo.processInfo.environment["SHELL"], !s.isEmpty {
            return s
        }
        if let pw = getpwuid(getuid()), let sh = pw.pointee.pw_shell {
            let path = String(cString: sh)
            if !path.isEmpty { return path }
        }
        return "/bin/zsh"
    }
}
