import AppKit
import Foundation

/// IME 조합 중인 텍스트(한글 / 일본어 / 중국어 등)의 시각적 표시 방식.
/// `DamsonConfig.imeStyle`로 설정.
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

/// 한 `DamsonSession`에 주입되는 설정 스냅샷.
/// 값 타입. 변경하려면 새 값을 만들어 `DamsonSession.updateConfig(_:)` 호출.
public struct DamsonConfig {
    public var fontFamily: String
    public var fontSize: CGFloat
    public var theme: DamsonTheme
    public var scrollbackBytes: Int
    public var scrollbackLines: Int
    public var imeStyle: IMECompositionStyle
    public var cursorBlink: Bool
    /// 탭/페인 라이프사이클 모션을 켤지. 기본 ON. macOS Reduce Motion은 이와 무관하게 항상 우선.
    public var animations: Bool
    /// 기본 cursor 모양. 셸/앱이 DECSCUSR로 바꾸면 그게 우선, ps=0(reset)이면 이 값으로 복귀.
    public var cursorShape: Grid.CursorShape
    /// 프로그래밍 리가처(=>, !=, ->, === 등)를 셀 정렬해 렌더할지. 기본 OFF.
    /// 폰트 자체의 OpenType liga/calt 테이블에 의존 — 리가처 없는 폰트(Menlo 등)는
    /// 켜도 변화 없음. Fira Code / JetBrains Mono / D2CodingLigature 등에서 보임.
    public var ligatures: Bool
    /// 오른쪽 가장자리에 스크롤 위치 인디케이터(thumb)를 표시할지. 기본 OFF.
    /// 스크롤백이 viewport보다 길 때만 보인다.
    public var showScrollbar: Bool
    /// 터미널 배경 불투명도(0.2~1.0). 1.0이면 완전 불투명(기존 동작). 1 미만이면
    /// 배경/선택/커서 fill만 그만큼 투명해지고(텍스트·이모지·밑줄은 불투명 유지),
    /// 창 뒤가 비친다. 창 쪽 isOpaque/블러는 앱(window controller)이 같이 맞춘다.
    public var backgroundOpacity: CGFloat
    /// 투명 배경 뒤에 frosted-glass 블러(NSVisualEffectView)를 깔지. 기본 OFF.
    /// backgroundOpacity가 1.0이면 보이지 않는다(배경이 불투명이라).
    public var backgroundBlur: Bool
    /// 화면 전체 post-processing 효과(CRT 등). 기본 none(=비용 0). [[ScreenEffect]].
    public var screenEffect: ScreenEffect
    /// 화면 효과 강도(0~1). 1이면 효과 기본값 그대로, 낮추면 약하게.
    public var screenEffectIntensity: CGFloat
    /// 커서 근처에서 글자가 새로 생길 때의 애니메이션. 기본 none. [[GlyphAnimStyle]].
    public var glyphAppear: GlyphAnimStyle
    /// 커서 근처에서 글자가 지워질 때의 애니메이션. 기본 none.
    public var glyphDisappear: GlyphAnimStyle
    /// 텍스트를 선택하면(드래그/더블·트리플 클릭) 자동으로 클립보드에 복사. 기본 ON.
    public var copyOnSelect: Bool
    /// mouse-reporting TUI(Claude Code 등)로 트랙패드 휠을 전달할 때의 속도 배율.
    /// 1.0 = ≈1줄 이동마다 휠 1틱. 높을수록 빠름. 자체 scrollback 스크롤엔 영향 없음.
    public var scrollSpeed: CGFloat

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
        theme: DamsonTheme = .defaultDark,
        scrollbackBytes: Int = 10_000_000,
        scrollbackLines: Int = 10_000,
        imeStyle: IMECompositionStyle = .none,
        cursorBlink: Bool = false,
        animations: Bool = true,
        cursorShape: Grid.CursorShape = .block,
        ligatures: Bool = false,
        showScrollbar: Bool = false,
        backgroundOpacity: CGFloat = 1.0,
        backgroundBlur: Bool = false,
        screenEffect: ScreenEffect = .none,
        screenEffectIntensity: CGFloat = 1.0,
        glyphAppear: GlyphAnimStyle = .none,
        glyphDisappear: GlyphAnimStyle = .none,
        copyOnSelect: Bool = true,
        scrollSpeed: CGFloat = 1.0,
        argv: [String] = DamsonConfig.defaultArgv(),
        env: [String: String] = DamsonConfig.defaultEnv(),
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
        self.ligatures = ligatures
        self.showScrollbar = showScrollbar
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.screenEffect = screenEffect
        self.screenEffectIntensity = screenEffectIntensity
        self.glyphAppear = glyphAppear
        self.glyphDisappear = glyphDisappear
        self.copyOnSelect = copyOnSelect
        self.scrollSpeed = scrollSpeed
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    /// spawn할 자식 프로세스의 기본 환경. 부모 환경을 상속하되 터미널 타입을 선언한다.
    ///
    /// 터미널 에뮬레이터는 자신이 어떤 터미널을 흉내내는지 `TERM`으로 declare해야 한다
    /// (Terminal.app/iTerm2/Ghostty 모두 상속에 기대지 않고 직접 set한다). GUI 앱이
    /// LaunchServices로 실행되면 상속 환경에 `TERM`/`COLORTERM`이 아예 없어서, Claude
    /// Code 등 capability를 env로 감지하는 TUI가 컬러 지원을 못 알아채고 색을 떨군다.
    /// (셸 프롬프트는 raw ANSI escape라 영향 없음 — 그래서 프롬프트만 색이 나왔다.)
    ///
    /// 렌더러가 256색·truecolor(24-bit)를 지원하므로 둘 다 선언한다. 자체 terminfo를
    /// ship하지 않으니 어디에나 설치돼 있는 `xterm-256color`를 TERM 값으로 쓴다.
    public static func defaultEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        return env
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
