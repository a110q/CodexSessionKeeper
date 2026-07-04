// swift-tools-version: 6.0

import Foundation
import PackageDescription

let testingInteropSearchPaths = [
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    "/Applications/Xcode.app/Contents/Developer/Library/Developer/usr/lib"
].filter {
    FileManager.default.fileExists(atPath: "\($0)/lib_TestingInterop.dylib")
}
// Keep Swift Testing explicit so plain `swift test` works when the toolchain
// framework is not visible through SwiftPM's default Command Line Tools paths.
let swiftTestingLinkerSettings: [LinkerSetting] = testingInteropSearchPaths.isEmpty
    ? []
    : [.unsafeFlags(testingInteropSearchPaths.flatMap {
        ["-L", $0, "-Xlinker", "-rpath", "-Xlinker", $0]
    })]

let package = Package(
    name: "CodexSessionVault",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexSessionVault", targets: ["CodexSessionVault"]),
        .library(name: "CodexSessionVaultCore", targets: ["CodexSessionVaultCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", revision: "937120cbc281cf29727fdfb8734482158508b4fc")
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
            dependencies: [
                "CodexSessionVaultCore",
                .product(name: "Testing", package: "swift-testing")
            ],
            path: "Tests/CodexSessionVaultCoreTests",
            linkerSettings: swiftTestingLinkerSettings
        )
    ]
)
