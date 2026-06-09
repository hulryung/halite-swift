import Foundation

/// Policy for the starting working directory when opening a new tab. Stored as a raw string in
/// UserDefaults("damson.newTabDirectory"). (Splits always inherit the current pane's cwd regardless of this setting.)
enum NewTabDirectory: String, CaseIterable {
    /// Always start in the home directory. **Default.**
    case home

    /// Inherit the working directory of the currently active tab/pane (based on shell-integration OSC 7 reports).
    case inheritCwd

    var displayName: String {
        switch self {
        case .home: return "Home (home directory)"
        case .inheritCwd: return "Current (inherit current directory)"
        }
    }

    static var current: NewTabDirectory {
        if let raw = UserDefaults.standard.string(forKey: "damson.newTabDirectory"),
           let v = NewTabDirectory(rawValue: raw) {
            return v
        }
        return .home
    }
}
