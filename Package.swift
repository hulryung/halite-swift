// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "halite-swift",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // 엔진 라이브러리 — cmux와 halite.app이 공유
        .library(
            name: "HaliteTerminal",
            targets: ["HaliteTerminal"]
        ),
        // halite ↔ halite-cli IPC wire format (서버/클라이언트 공유)
        .library(
            name: "HaliteControl",
            targets: ["HaliteControl"]
        ),
        // 독립 앱 (개발 중에는 `swift run halite`, 배포는 추후 Xcode 프로젝트)
        .executable(
            name: "halite",
            targets: ["halite"]
        ),
        // CLI 클라이언트 — Rust halite-cli와 wire-format 호환
        .executable(
            name: "halite-cli",
            targets: ["halite-cli"]
        ),
    ],
    dependencies: [
        // Sparkle 자동업데이트 — Developer ID 서명된 .app 한정으로 동작.
        // EdDSA 키페어는 scripts/sparkle-keygen.sh로 1회 생성 후 Info.plist의
        // SUPublicEDKey에 박힘. 자세한 절차는 docs/RELEASE.md 참조.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "HaliteTerminal",
            path: "Sources/HaliteTerminal"
            // 추후 Shaders.metal 추가 시 resources에 .process()로 선언
        ),
        .target(
            name: "HaliteControl",
            path: "Sources/HaliteControl"
        ),
        .executableTarget(
            name: "halite",
            dependencies: [
                "HaliteTerminal",
                "HaliteControl",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/halite"
        ),
        .executableTarget(
            name: "halite-cli",
            dependencies: ["HaliteControl"],
            path: "Sources/halite-cli"
        ),
        .testTarget(
            name: "HaliteTerminalTests",
            dependencies: ["HaliteTerminal"],
            path: "Tests/HaliteTerminalTests"
        ),
        .testTarget(
            name: "HaliteControlTests",
            dependencies: ["HaliteControl"],
            path: "Tests/HaliteControlTests"
        ),
    ]
)
