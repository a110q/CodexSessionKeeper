import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite
struct ReleaseManifestTests {
    @Test
    func semanticVersionsCompareNumericComponents() throws {
        #expect(try SemanticVersion("1.10.0") > SemanticVersion("1.9.9"))
        #expect(try SemanticVersion("2.0.0") > SemanticVersion("1.99.99"))
        #expect(try SemanticVersion("1.1.0") == SemanticVersion("1.1.0"))
    }

    @Test(arguments: ["1.1", "1.1.0-beta", "01.1.0", "1.-1.0", ""])
    func semanticVersionRejectsNonReleaseText(_ version: String) {
        #expect(throws: ReleaseManifestError.self) {
            try SemanticVersion(version)
        }
    }

    @Test
    func decodesValidatedManifestAndSelectsPlatformArtifact() throws {
        let manifest = try ReleaseManifest.decodeValidated(from: try manifestData())

        #expect(manifest.version == "1.1.0")
        #expect(manifest.build == 10100)
        #expect(try manifest.artifact(for: .macosArm64).url.hasSuffix("macos-arm64.zip"))
        #expect(try manifest.artifact(for: .windowsX64).url.hasSuffix("Setup.exe"))
    }

    @Test
    func matchesOnlyTheExactSparkleVersionAndBuildIdentity() throws {
        let manifest = try ReleaseManifest.decodeValidated(from: try manifestData())

        #expect(manifest.matchesSparkleItem(displayVersion: "1.1.0", buildVersion: "10100"))
        #expect(!manifest.matchesSparkleItem(displayVersion: "1.1.0", buildVersion: "10099"))
        #expect(!manifest.matchesSparkleItem(displayVersion: "1.1.1", buildVersion: "10100"))
        #expect(!manifest.matchesSparkleItem(displayVersion: "1.1.0", buildVersion: "010100"))
    }

    @Test
    func rejectsUnknownFieldsAndForcedUpdates() throws {
        var value = manifestObject()
        value["extra"] = true
        #expect(throws: ReleaseManifestError.self) {
            try ReleaseManifest.decodeValidated(from: try JSONSerialization.data(withJSONObject: value))
        }

        value = manifestObject()
        value["required"] = true
        #expect(throws: ReleaseManifestError.self) {
            try ReleaseManifest.decodeValidated(from: try JSONSerialization.data(withJSONObject: value))
        }
    }

    @Test
    func rejectsUnsafeArtifactAndMalformedFields() throws {
        var value = manifestObject()
        var platforms = try #require(value["platforms"] as? [String: Any])
        var mac = try #require(platforms["macos-arm64"] as? [String: Any])
        mac["url"] = "http://attacker.invalid/app.zip"
        platforms["macos-arm64"] = mac
        value["platforms"] = platforms
        #expect(throws: ReleaseManifestError.self) {
            try ReleaseManifest.decodeValidated(from: try JSONSerialization.data(withJSONObject: value))
        }

        value = manifestObject()
        value["notes"] = [String(repeating: "字", count: 167)]
        #expect(throws: ReleaseManifestError.self) {
            try ReleaseManifest.decodeValidated(from: try JSONSerialization.data(withJSONObject: value))
        }
    }
}

func manifestObject(
    version: String = "1.1.0",
    build: Int = 10100
) -> [String: Any] {
    [
        "schemaVersion": 1,
        "channel": "stable",
        "version": version,
        "build": build,
        "publishedAt": "2026-07-21T00:00:00Z",
        "required": false,
        "notes": ["新增公司内网更新功能"],
        "platforms": [
            "macos-arm64": [
                "url": "macos/CodexSessionKeeper-\(version)-macos-arm64.zip",
                "size": 12,
                "sha256": String(repeating: "a", count: 64)
            ],
            "windows-x64": [
                "url": "windows/CodexSessionKeeper-\(version)-windows-x64-Setup.exe",
                "size": 34,
                "sha256": String(repeating: "b", count: 64)
            ]
        ]
    ]
}

func manifestData(
    version: String = "1.1.0",
    build: Int = 10100
) throws -> Data {
    try JSONSerialization.data(
        withJSONObject: manifestObject(version: version, build: build),
        options: [.sortedKeys]
    )
}
