import Foundation

/// 빌드 메타 — Info.plist에 build-app.sh가 주입한 git hash / 채널.
/// dev 빌드는 윈도우 타이틀에 hash를 표시해 정식(release)과 시각적으로 구분.
enum BuildInfo {
    static var gitHash: String? {
        guard let h = Bundle.main.object(forInfoDictionaryKey: "DamsonGitHash") as? String,
              !h.isEmpty, h != "__GIT_HASH__", h != "unknown"
        else { return nil }
        return h
    }

    static var channel: String {
        (Bundle.main.object(forInfoDictionaryKey: "DamsonBuildChannel") as? String) ?? "release"
    }

    static var isDevBuild: Bool { channel == "dev" }

    /// build-app.sh가 주입한 빌드 시각("YYYY-MM-DD HH:MM"). 미주입/플레이스홀더면 nil.
    static var buildDate: String? {
        guard let d = Bundle.main.object(forInfoDictionaryKey: "DamsonBuildDate") as? String,
              !d.isEmpty, d != "__BUILD_DATE__"
        else { return nil }
        return d
    }

    /// 윈도우 우상단 배지: dev 빌드면 "dev a12ee87", 정식 빌드면 빌드 시각.
    static var badgeText: String? {
        if isDevBuild { return gitHash.map { "dev \($0)" } ?? "dev" }
        return buildDate
    }

    /// 윈도우 타이틀에 붙일 dev 표시 (" · dev a12ee87"). release면 빈 문자열.
    static var titleSuffix: String {
        guard isDevBuild else { return "" }
        if let hash = gitHash { return " · dev \(hash)" }
        return " · dev"
    }
}
