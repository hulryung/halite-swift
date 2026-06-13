import AppKit
import Foundation

/// How text being composed by the IME (Korean / Japanese / Chinese, etc.) is displayed visually.
/// Configured via `DamsonConfig.imeStyle`.
public enum IMECompositionStyle: String, Codable, CaseIterable, Sendable {
    /// Thin underline only (the most subtle option, the default).
    case underline
    /// Thick underline. Similar to macOS's default IME presentation.
    case thickUnderline
    /// Background highlight only.
    case background
    /// Background + thick underline (the previous behavior).
    case both
    /// No indicator — just a different text color.
    case none
}

/// A configuration snapshot injected into a single `DamsonSession`.
/// A value type. To change it, build a new value and call `DamsonSession.updateConfig(_:)`.
public struct DamsonConfig {
    public var fontFamily: String
    public var fontSize: CGFloat
    public var theme: DamsonTheme
    public var scrollbackBytes: Int
    public var scrollbackLines: Int
    public var imeStyle: IMECompositionStyle
    public var cursorBlink: Bool
    /// Whether to enable tab/pane lifecycle motion. Default ON. macOS Reduce Motion always takes precedence regardless.
    public var animations: Bool
    /// Default cursor shape. If the shell/app changes it via DECSCUSR that wins; ps=0 (reset) reverts to this value.
    public var cursorShape: Grid.CursorShape
    /// Whether to render programming ligatures (=>, !=, ->, ===, etc.) cell-aligned. Default OFF.
    /// Depends on the font's own OpenType liga/calt tables — fonts without ligatures (Menlo, etc.)
    /// show no change even when enabled. Visible with Fira Code / JetBrains Mono / D2CodingLigature, etc.
    public var ligatures: Bool
    /// Whether to show a scroll-position indicator (thumb) on the right edge. Default OFF.
    /// Only visible when the scrollback is longer than the viewport.
    public var showScrollbar: Bool
    /// Render oversized Nerd Font icons (powerline prompts etc.) at natural size
    /// across two cells, centered on their grid slot, instead of shrinking them
    /// into one cell. Default ON. Only affects non-Mono / Propo font variants —
    /// Mono variants size icons to one cell already, so nothing overflows. The
    /// trade-off is icons may overlap immediately-adjacent text. [[ScreenEffect]]-free.
    public var doubleWidthIcons: Bool
    /// Terminal background opacity (0.2~1.0). 1.0 is fully opaque (the existing behavior). Below 1,
    /// only the background/selection/cursor fills become that translucent (text, emoji, and underlines
    /// stay opaque) and what's behind the window shows through. The window's isOpaque/blur is matched
    /// alongside by the app (window controller).
    public var backgroundOpacity: CGFloat
    /// Whether to lay a frosted-glass blur (NSVisualEffectView) behind the translucent background. Default OFF.
    /// Not visible when backgroundOpacity is 1.0 (the background is opaque).
    public var backgroundBlur: Bool
    /// Inner padding between the window edges and the terminal grid, in points
    /// (width = left/right, height = top/bottom). Default 4×4 — the historical inset.
    public var padding: NSSize
    /// Full-screen post-processing effect (CRT, etc.). Default none (= zero cost). [[ScreenEffect]].
    public var screenEffect: ScreenEffect
    /// Screen-effect intensity (0~1). 1 uses the effect's default values; lower softens it.
    public var screenEffectIntensity: CGFloat
    /// Animation for characters appearing near the cursor. Default none. [[GlyphAnimStyle]].
    public var glyphAppear: GlyphAnimStyle
    /// Animation for characters being erased near the cursor. Default none.
    public var glyphDisappear: GlyphAnimStyle
    /// Automatically copy to the clipboard when text is selected (drag / double- or triple-click). Default ON.
    public var copyOnSelect: Bool
    /// Speed multiplier when forwarding trackpad-wheel events to a mouse-reporting TUI (Claude Code, etc.).
    /// 1.0 = ≈one wheel tick per line of movement. Higher is faster. No effect on native scrollback scrolling.
    public var scrollSpeed: CGFloat

    // Colors are derived from the theme — computed properties for backward compatibility with existing call sites.
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
        doubleWidthIcons: Bool = true,
        backgroundOpacity: CGFloat = 1.0,
        backgroundBlur: Bool = false,
        padding: NSSize = NSSize(width: 4, height: 4),
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
        self.doubleWidthIcons = doubleWidthIcons
        self.backgroundOpacity = backgroundOpacity
        self.backgroundBlur = backgroundBlur
        self.padding = padding
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

    /// Default environment for the child process to spawn. Inherits the parent environment but declares the terminal type.
    ///
    /// A terminal emulator must declare which terminal it emulates via `TERM`
    /// (Terminal.app/iTerm2/Ghostty all set it directly rather than relying on inheritance). When a GUI app is
    /// launched via LaunchServices, the inherited environment has no `TERM`/`COLORTERM` at all, so a TUI that
    /// detects capabilities from env (Claude Code, etc.) fails to recognize color support and drops colors.
    /// (The shell prompt is unaffected since it's raw ANSI escapes — which is why only the prompt was colored.)
    ///
    /// Since the renderer supports 256-color and truecolor (24-bit), declare both. We don't ship our own terminfo,
    /// so we use `xterm-256color`, which is installed everywhere, as the TERM value.
    public static func defaultEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        return env
    }

    public static func defaultArgv() -> [String] {
        // Spawn a login shell (-l) so that /etc/zprofile's path_helper runs and
        // Homebrew (/opt/homebrew/bin) etc. get added to PATH. A shell spawned by a GUI
        // app (launched via LaunchServices) is non-login by default, so PATH holds only the
        // system defaults and brew-installed tools like starship can't be found
        // ("command not found"). Terminal.app/iTerm2 also launch a login shell.
        return [loginShellPath(), "-l"]
    }

    /// The user's login shell path. Prefers the SHELL env var; since it may be empty in a GUI
    /// app, falls back to the passwd DB (getpwuid), and to /bin/zsh if that's also unavailable.
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
