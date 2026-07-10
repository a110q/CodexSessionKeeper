import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("ExternalAttachmentRestoreValidator")
struct ExternalAttachmentRestoreValidatorTests {
    private let sourceRoot = URL(
        fileURLWithPath: "/vault/snapshots/20260710-manual/data",
        isDirectory: true
    )
    private let destinationRoot = URL(
        fileURLWithPath: "/Users/alice/.codex/recovered_attachments/20260710-manual",
        isDirectory: true
    )

    @Test
    func mapsValidStoredPathIntoSafeRecoveryDirectory() throws {
        let record = attachmentRecord(
            originalPath: "/tmp/untrusted-target.png",
            storedRelativePath: "external_attachments/session-1/hash-image.png"
        )

        let paths = try ExternalAttachmentRestoreValidator.validate(
            records: [record],
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            selectedSessionIDs: nil
        )

        #expect(paths.count == 1)
        #expect(paths[0].sessionID == "session-1")
        #expect(paths[0].sourceURL.path == "/vault/snapshots/20260710-manual/data/external_attachments/session-1/hash-image.png")
        #expect(paths[0].destinationURL.path == "/Users/alice/.codex/recovered_attachments/20260710-manual/session-1/hash-image.png")
        #expect(paths[0].destinationURL.path != record.originalPath)
    }

    @Test
    func validatesOnlyRecordsForSelectedSessions() throws {
        let selected = attachmentRecord(
            sessionID: "session-1",
            storedRelativePath: "external_attachments/session-1/hash-image.png"
        )
        let unrelated = attachmentRecord(
            sessionID: "session-2",
            storedRelativePath: "../../outside.txt"
        )

        let paths = try ExternalAttachmentRestoreValidator.validate(
            records: [selected, unrelated],
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            selectedSessionIDs: ["session-1"]
        )

        #expect(paths.map(\.sessionID) == ["session-1"])
    }

    @Test(arguments: [
        "",
        ".",
        "external_attachments/session-1",
        "external_attachments/session-1/.",
        "external_attachments/session-1/../outside.txt",
        "external_attachments/session-1//image.png",
        "../../outside.txt",
        #"external_attachments\session-1\..\outside.txt"#,
        "/tmp/outside.txt",
        #"C:\Users\Ada\outside.txt"#,
        #"\\server\share\outside.txt"#,
        "external_attachments/session-1/image\0.png"
    ])
    func rejectsUnsafeStoredPaths(storedRelativePath: String) {
        #expect(throws: ExternalAttachmentRestoreValidationError.self) {
            try ExternalAttachmentRestoreValidator.validate(
                records: [attachmentRecord(storedRelativePath: storedRelativePath)],
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                selectedSessionIDs: nil
            )
        }
    }

    @Test
    func rejectsSessionMismatch() {
        #expect(throws: ExternalAttachmentRestoreValidationError.self) {
            try ExternalAttachmentRestoreValidator.validate(
                records: [
                    attachmentRecord(
                        sessionID: "session-1",
                        storedRelativePath: "external_attachments/session-2/image.png"
                    )
                ],
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                selectedSessionIDs: nil
            )
        }
    }

    @Test
    func rejectsTheWholeSelectedListWhenOneRecordIsUnsafe() {
        #expect(throws: ExternalAttachmentRestoreValidationError.self) {
            try ExternalAttachmentRestoreValidator.validate(
                records: [
                    attachmentRecord(storedRelativePath: "external_attachments/session-1/image.png"),
                    attachmentRecord(storedRelativePath: "../../outside.txt")
                ],
                sourceRoot: sourceRoot,
                destinationRoot: destinationRoot,
                selectedSessionIDs: nil
            )
        }
    }

    private func attachmentRecord(
        sessionID: String = "session-1",
        originalPath: String = "/tmp/original.png",
        storedRelativePath: String,
        sizeBytes: Int64 = 42
    ) -> ExternalAttachmentRestoreRecord {
        ExternalAttachmentRestoreRecord(
            sessionID: sessionID,
            originalPath: originalPath,
            storedRelativePath: storedRelativePath,
            sizeBytes: sizeBytes
        )
    }
}
