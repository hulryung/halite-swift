import Foundation

/// Injects shell integration so the shell reports its current working directory via OSC 7.
///
/// zsh doesn't emit OSC 7 by default, so through a `ZDOTDIR` wrapper we generate, it sources
/// the user's original config (`$HOME/.zshenv`, etc.) as-is and then emits OSC 7 from a `precmd`
/// hook. The user's dotfiles are never modified (read-only).
///
/// For non-zsh shells it does nothing (returns an empty override) — in that case the cwd
/// inheritance for splits/new tabs only follows the directory at spawn time.
enum ShellIntegration {
    /// Variables to merge into the session env. Empty dictionary if not zsh or if wrapper creation fails.
    static func envOverrides(forShellPath shellPath: String?) -> [String: String] {
        guard let shellPath, isZsh(shellPath), let dir = ensureZdotdir() else {
            return [:]
        }
        return ["ZDOTDIR": dir, "DAMSON_SHELL_INTEGRATION": "1"]
    }

    private static func isZsh(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "zsh"
    }

    /// Ensures the wrapper directory exists (creating it if needed) and returns its path. Written once per process.
    private static let zdotdir: String? = {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support
            .appendingPathComponent("Damson", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent("zsh", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in wrapperFiles {
                let url = dir.appendingPathComponent(name)
                try body.write(to: url, atomically: true, encoding: .utf8)
            }
            return dir.path
        } catch {
            return nil
        }
    }()

    private static func ensureZdotdir() -> String? { zdotdir }

    /// Forwards the entire zsh startup-file sequence (.zshenv → .zprofile → .zshrc → .zlogin)
    /// to the user's originals under `$HOME`. The OSC 7 hook is appended to .zshrc only.
    private static var wrapperFiles: [(String, String)] {
        func forward(_ name: String) -> String {
            // Since ZDOTDIR is our directory, the user's original is always $HOME/<name>.
            "[ -r \"$HOME/\(name)\" ] && source \"$HOME/\(name)\"\n"
        }
        let hook = """

        # --- damson shell integration ---
        # On every prompt: report cwd via OSC 7 (new splits/tabs inherit cwd) + mark the
        # prompt line via OSC 133;A (⌘↑/⌘↓ prompt jump).
        _damson_precmd() {
          printf '\\033]7;file://%s%s\\033\\\\' "${HOST}" "${PWD}"
          printf '\\033]133;A\\033\\\\'
        }
        autoload -Uz add-zsh-hook 2>/dev/null
        if (( $+functions[add-zsh-hook] )); then
          add-zsh-hook -d precmd _damson_precmd 2>/dev/null
          add-zsh-hook precmd _damson_precmd
        else
          precmd_functions+=(_damson_precmd)
        fi
        _damson_precmd
        # --- end damson shell integration ---

        """
        return [
            (".zshenv", forward(".zshenv")),
            (".zprofile", forward(".zprofile")),
            (".zshrc", forward(".zshrc") + hook),
            (".zlogin", forward(".zlogin")),
        ]
    }
}
