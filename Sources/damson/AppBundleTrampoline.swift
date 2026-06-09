import AppKit
import Foundation

/// raw binary로 실행될 때 자기 자신을 `.app` 번들 안에서 relaunch 시키는 trampoline.
///
/// 한글 IME 첫 자모 race를 깨끗하게 잡으려면 LaunchServices가 우리 process를 "GUI 앱"으로
/// 등록하고 있어야 하고, 그건 사실상 `.app` bundle을 통한 실행만 보장.
/// 자세한 배경은 halite Rust 문서 `~/dev/halite/docs/KOREAN-IME.md` 참조.
///
/// 디버깅용 `DAMSON_NO_TRAMPOLINE=1`이 set 되어 있으면 skip.
enum AppBundleTrampoline {
    /// halite Rust와 일치시킨 bundle id / name / 경로 — LaunchServices가 동일 식별자로
    /// 두 구현을 같은 등록으로 다루도록 (charset of conventions).
    private static let bundleID = "app.damson.terminal"
    private static let bundleName = "damson"
    private static let appDirName = "Damson.app"

    static func relaunchInAppBundleIfNeeded() {
        if ProcessInfo.processInfo.environment["DAMSON_NO_TRAMPOLINE"] != nil {
            return
        }
        guard let executablePath = Bundle.main.executablePath else { return }
        if isInsideAppBundle(executablePath: executablePath) {
            return
        }

        let bundleURL = cachedBundleURL()
        let executableURL = URL(fileURLWithPath: executablePath)
        do {
            try materializeBundle(at: bundleURL, withExecutableFrom: executableURL)
        } catch {
            NSLog("damson trampoline: failed to materialize bundle: %@", error.localizedDescription)
            return // degraded mode
        }

        do {
            try relaunch(bundleURL: bundleURL)
            exit(0)
        } catch {
            NSLog("damson trampoline: failed to relaunch: %@", error.localizedDescription)
            return
        }
    }

    // MARK: - Internals

    private static func isInsideAppBundle(executablePath: String) -> Bool {
        executablePath.contains(".app/Contents/MacOS/")
    }

    private static func cachedBundleURL() -> URL {
        let fm = FileManager.default
        let cachesDir = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Caches")
        return cachesDir.appendingPathComponent("damson/\(appDirName)")
    }

    private static func materializeBundle(at bundleURL: URL, withExecutableFrom srcURL: URL) throws {
        let fm = FileManager.default
        let contentsDir = bundleURL.appendingPathComponent("Contents")
        let macosDir = contentsDir.appendingPathComponent("MacOS")
        let plistURL = contentsDir.appendingPathComponent("Info.plist")
        let dstBinaryURL = macosDir.appendingPathComponent(bundleName)

        try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try infoPlist().write(to: plistURL, atomically: true, encoding: .utf8)

        // 매번 덮어쓴다 — 새로 빌드한 binary가 즉시 반영되도록.
        // halite Rust trampoline과 동일 정책.
        if fm.fileExists(atPath: dstBinaryURL.path) {
            try fm.removeItem(at: dstBinaryURL)
        }
        try fm.copyItem(at: srcURL, to: dstBinaryURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstBinaryURL.path)

        // binary가 RPATH `@loader_path`로 sibling Frameworks를 로드 — Sparkle 통합 후엔
        // Sparkle.framework가 sibling으로 있어야 dyld 로드 성공. 원본 binary의 sibling
        // .framework들을 cached bundle의 MacOS/에도 똑같이 복사.
        let srcDir = srcURL.deletingLastPathComponent()
        if let entries = try? fm.contentsOfDirectory(at: srcDir, includingPropertiesForKeys: nil) {
            for entry in entries where entry.pathExtension == "framework" {
                let dst = macosDir.appendingPathComponent(entry.lastPathComponent)
                if fm.fileExists(atPath: dst.path) {
                    try? fm.removeItem(at: dst)
                }
                try? fm.copyItem(at: entry, to: dst)
            }
        }

        // 아이콘 — SwiftPM이 Bundle.module의 Damson.icns로 노출. Info.plist의
        // CFBundleIconFile=Damson와 짝이 되도록 Contents/Resources/Damson.icns에
        // 복사. 없으면 무시 (dock에 generic 아이콘).
        if let iconURL = Bundle.module.url(forResource: "Damson", withExtension: "icns") {
            let resourcesDir = contentsDir.appendingPathComponent("Resources")
            try? fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
            let dstIcon = resourcesDir.appendingPathComponent("Damson.icns")
            if fm.fileExists(atPath: dstIcon.path) {
                try? fm.removeItem(at: dstIcon)
            }
            try? fm.copyItem(at: iconURL, to: dstIcon)
        }
    }

    private static func infoPlist() -> String {
        // halite Rust의 plist에 맞춤 — 최소 필드만.
        // 불필요한 키가 LaunchServices 등록을 까다롭게 만들지 않도록.
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>\(bundleName)</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>\(bundleName)</string>
            <key>CFBundleVersion</key>
            <string>0.0.1</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
            <key>CFBundleIconFile</key>
            <string>Damson</string>
            <key>NSHighResolutionCapable</key>
            <true/>
        </dict>
        </plist>
        """
    }

    private static func relaunch(bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -F : fresh launch (saved-state 복원 안 함). halite Rust도 동일하게 -F 사용.
        // -n (new instance)은 LaunchServices 등록 캐시를 우회할 수도 있어 의도적으로 안 씀.
        process.arguments = ["-F", bundleURL.path]
        try process.run()
        // open(1)은 LaunchServices에 dispatch 후 곧장 종료. wait 불필요.
    }
}
