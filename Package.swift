// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "damson",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        // Engine library — shared by cmux and Damson.app
        .library(
            name: "DamsonTerminal",
            targets: ["DamsonTerminal"]
        ),
        // damson ↔ damson-cli IPC wire format (shared by server/client)
        .library(
            name: "DamsonControl",
            targets: ["DamsonControl"]
        ),
        // Standalone app (`swift run damson` during development; Xcode project later for distribution)
        .executable(
            name: "damson",
            targets: ["damson"]
        ),
        // CLI client — sends commands to the damson server
        .executable(
            name: "damson-cli",
            targets: ["damson-cli"]
        ),
    ],
    dependencies: [
        // Sparkle auto-update — only works in a Developer ID-signed .app.
        // The EdDSA keypair is generated once via scripts/sparkle-keygen.sh and
        // baked into SUPublicEDKey in Info.plist. See docs/RELEASE.md for details.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "DamsonTerminal",
            path: "Sources/DamsonTerminal"
            // When Shaders.metal is added later, declare it in resources with .process()
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
