import AppKit
import Foundation

/// 한 `HaliteSession`에 주입되는 설정 스냅샷.
/// 값 타입. 변경하려면 새 값을 만들어 `HaliteSession.updateConfig(_:)` 호출.
public struct HaliteConfig {
    public var fontFamily: String
    public var fontSize: CGFloat
    public var backgroundColor: NSColor
    public var foregroundColor: NSColor
    public var palette: [Int: NSColor]
    public var scrollbackBytes: Int

    // PTY spawn
    public var argv: [String]
    public var env: [String: String]
    public var cwd: String?

    public init(
        fontFamily: String = "Menlo",
        fontSize: CGFloat = 13,
        backgroundColor: NSColor = NSColor.black,
        foregroundColor: NSColor = NSColor.white,
        palette: [Int: NSColor] = [:],
        scrollbackBytes: Int = 10_000_000,
        argv: [String] = HaliteConfig.defaultArgv(),
        env: [String: String] = ProcessInfo.processInfo.environment,
        cwd: String? = nil
    ) {
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.backgroundColor = backgroundColor
        self.foregroundColor = foregroundColor
        self.palette = palette
        self.scrollbackBytes = scrollbackBytes
        self.argv = argv
        self.env = env
        self.cwd = cwd
    }

    public static func defaultArgv() -> [String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return [shell]
    }
}
