// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexSessionVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSessionVault", targets: ["CodexSessionVault"])
    ],
    targets: [
        .executableTarget(
            name: "CodexSessionVault",
            path: "Sources/CodexSessionVault"
        )
    ]
)

