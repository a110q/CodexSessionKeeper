import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("SnapshotPathValidator")
struct SnapshotPathValidatorTests {
    private let snapshotRoot = URL(
        fileURLWithPath: "/Users/alice/.codex-session-vault/snapshots",
        isDirectory: true
    )

    @Test
    func resolvesSafeSnapshotIDAsDirectChild() throws {
        let url = try SnapshotPathValidator.resolve("20260710-120000-manual", under: snapshotRoot)

        #expect(url.path == "/Users/alice/.codex-session-vault/snapshots/20260710-120000-manual")
        #expect(url.deletingLastPathComponent().standardizedFileURL == snapshotRoot.standardizedFileURL)
    }

    @Test(arguments: [
        "",
        ".",
        "..",
        "../outside",
        "nested/snapshot",
        #"..\outside"#,
        "/tmp/outside",
        #"C:\outside"#,
        #"C:outside"#,
        #"\\server\share"#,
        "snapshot\0outside"
    ])
    func rejectsUnsafeSnapshotIDs(snapshotID: String) {
        #expect(throws: SnapshotPathValidationError.self) {
            try SnapshotPathValidator.resolve(snapshotID, under: snapshotRoot)
        }
    }

    @Test
    func metadataIDMustResolveToEnumeratedDirectory() throws {
        let enumeratedDirectory = snapshotRoot.appendingPathComponent("real-directory", isDirectory: true)

        #expect(throws: SnapshotPathValidationError.self) {
            try SnapshotPathValidator.resolve(
                "other-directory",
                under: snapshotRoot,
                matching: enumeratedDirectory
            )
        }

        let resolved = try SnapshotPathValidator.resolve(
            "real-directory",
            under: snapshotRoot,
            matching: enumeratedDirectory
        )
        #expect(resolved == enumeratedDirectory.standardizedFileURL)
    }
}
