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
        // 독립 앱 (개발 중에는 `swift run halite`, 배포는 추후 Xcode 프로젝트)
        .executable(
            name: "halite",
            targets: ["halite"]
        ),
    ],
    targets: [
        .target(
            name: "HaliteTerminal",
            path: "Sources/HaliteTerminal"
            // 추후 Shaders.metal 추가 시 resources에 .process()로 선언
        ),
        .executableTarget(
            name: "halite",
            dependencies: ["HaliteTerminal"],
            path: "Sources/halite"
        ),
        .testTarget(
            name: "HaliteTerminalTests",
            dependencies: ["HaliteTerminal"],
            path: "Tests/HaliteTerminalTests"
        ),
    ]
)
