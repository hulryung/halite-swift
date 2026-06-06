import Foundation

/// 셸이 OSC 7로 현재 작업 디렉토리를 보고하도록 셸 통합을 주입한다.
///
/// zsh는 기본적으로 OSC 7을 emit하지 않으므로, 우리가 생성한 `ZDOTDIR` 래퍼를
/// 통해 사용자의 원래 설정(`$HOME/.zshenv` 등)을 그대로 source한 뒤 `precmd`
/// 훅으로 OSC 7을 쏘게 한다. 사용자의 dotfile은 건드리지 않는다(read-only).
///
/// zsh가 아니면 아무것도 하지 않는다(빈 override 반환) — split/새 탭의 cwd 상속은
/// 그 경우 spawn 시점 디렉토리만 따른다.
enum ShellIntegration {
    /// 세션 env에 합칠 변수들. zsh가 아니거나 래퍼 생성에 실패하면 빈 dictionary.
    static func envOverrides(forShellPath shellPath: String?) -> [String: String] {
        guard let shellPath, isZsh(shellPath), let dir = ensureZdotdir() else {
            return [:]
        }
        return ["ZDOTDIR": dir, "HALITE_SHELL_INTEGRATION": "1"]
    }

    private static func isZsh(_ path: String) -> Bool {
        (path as NSString).lastPathComponent == "zsh"
    }

    /// 래퍼 디렉토리를 보장(없으면 생성)하고 경로를 반환. 프로세스당 1회만 쓴다.
    private static let zdotdir: String? = {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support
            .appendingPathComponent("halite", isDirectory: true)
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

    /// zsh 시작 파일 순서(.zshenv → .zprofile → .zshrc → .zlogin)를 모두 사용자의
    /// `$HOME` 원본으로 포워딩한다. .zshrc 에만 OSC 7 훅을 덧붙인다.
    private static var wrapperFiles: [(String, String)] {
        func forward(_ name: String) -> String {
            // ZDOTDIR이 우리 디렉토리이므로, 사용자의 원본은 항상 $HOME/<name>.
            "[ -r \"$HOME/\(name)\" ] && source \"$HOME/\(name)\"\n"
        }
        let hook = """

        # --- halite shell integration ---
        # 매 프롬프트마다: OSC 7로 cwd 보고(새 split/탭이 cwd 상속) + OSC 133;A로
        # 프롬프트 줄 마크(⌘↑/⌘↓ 프롬프트 점프).
        _halite_precmd() {
          printf '\\033]7;file://%s%s\\033\\\\' "${HOST}" "${PWD}"
          printf '\\033]133;A\\033\\\\'
        }
        autoload -Uz add-zsh-hook 2>/dev/null
        if (( $+functions[add-zsh-hook] )); then
          add-zsh-hook -d precmd _halite_precmd 2>/dev/null
          add-zsh-hook precmd _halite_precmd
        else
          precmd_functions+=(_halite_precmd)
        fi
        _halite_precmd
        # --- end halite shell integration ---

        """
        return [
            (".zshenv", forward(".zshenv")),
            (".zprofile", forward(".zprofile")),
            (".zshrc", forward(".zshrc") + hook),
            (".zlogin", forward(".zlogin")),
        ]
    }
}
