// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexSessionVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSessionVault", targets: ["CodexSessionVault"]),
        .library(name: "CodexSessionVaultCore", targets: ["CodexSessionVaultCore"])
    ],
    targets: [
        .target(
            name: "CodexSessionVaultCore",
            path: "Sources/CodexSessionVaultCore"
        ),
        .executableTarget(
            name: "CodexSessionVault",
            dependencies: ["CodexSessionVaultCore"],
            path: "Sources/CodexSessionVault"
        ),
        .testTarget(
            name: "CodexSessionVaultCoreTests",
            dependencies: ["CodexSessionVaultCore"],
            path: "Tests/CodexSessionVaultCoreTests"
        )
    ]
)
