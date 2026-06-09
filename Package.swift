// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "damson",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // 엔진 라이브러리 — cmux와 halite.app이 공유
        .library(
            name: "DamsonTerminal",
            targets: ["DamsonTerminal"]
        ),
        // halite ↔ damson-cli IPC wire format (서버/클라이언트 공유)
        .library(
            name: "DamsonControl",
            targets: ["DamsonControl"]
        ),
        // 독립 앱 (개발 중에는 `swift run halite`, 배포는 추후 Xcode 프로젝트)
        .executable(
            name: "damson",
            targets: ["damson"]
        ),
        // CLI 클라이언트 — Rust damson-cli와 wire-format 호환
        .executable(
            name: "damson-cli",
            targets: ["damson-cli"]
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
            name: "DamsonTerminal",
            path: "Sources/DamsonTerminal"
            // 추후 Shaders.metal 추가 시 resources에 .process()로 선언
        ),
        .target(
            name: "DamsonControl",
            path: "Sources/DamsonControl"
        ),
        .executableTarget(
            name: "damson",
            dependencies: [
                "DamsonTerminal",
                "DamsonControl",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/damson",
            resources: [.copy("Resources/Damson.icns")]
        ),
        .executableTarget(
            name: "damson-cli",
            dependencies: ["DamsonControl"],
            path: "Sources/damson-cli"
        ),
        .testTarget(
            name: "DamsonTerminalTests",
            dependencies: ["DamsonTerminal"],
            path: "Tests/DamsonTerminalTests"
        ),
        .testTarget(
            name: "DamsonControlTests",
            dependencies: ["DamsonControl"],
            path: "Tests/DamsonControlTests"
        ),
    ]
)
