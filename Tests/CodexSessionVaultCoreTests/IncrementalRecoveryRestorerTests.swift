import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct IncrementalRecoveryRestorerTests {
    @Test
    func preflightValidatesAllSourcesBeforeDirectAtomicRestore() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "missing", title: "Missing conversation", contents: fixture.line("hello"))
        try fixture.writeExistingIndex()
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        let plan = try restorer.preflight(sessionIDs: ["missing"], currentSessionIDs: [])
        let result = try restorer.restore(plan, to: fixture.paths.codexRoot)

        let destination = fixture.recoveredURL(sessionID: "missing")
        #expect(try String(contentsOf: destination, encoding: .utf8) == fixture.line("hello"))
        #expect(result.restoredSessionIDs == ["missing"])
        #expect(result.threadRecords.first?.sessionID == "missing")
        #expect(try fixture.indexIDs() == ["existing", "missing"])
        #expect(try fixture.temporaryFiles(beside: destination).isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.backupRoot.appendingPathComponent("recovery-packages").path) == false)
    }

    @Test
    func restoreStreamsAFileLargerThanThreeVerificationChunks() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        let line = fixture.line(String(repeating: "x", count: 64 * 1_024))
        let minimumBytes = BackupVerificationDocument.defaultChunkSize * 3 + 17
        let repetitions = (minimumBytes + line.utf8.count - 1) / line.utf8.count
        let source = try fixture.addBackup(
            sessionID: "multi-chunk",
            title: "Multi chunk",
            contents: String(repeating: line, count: repetitions)
        )
        let expected = try BackupFileVerifier().verifyFull(source)
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        let plan = try restorer.preflight(sessionIDs: ["multi-chunk"], currentSessionIDs: [])
        let result = try restorer.restore(plan, to: fixture.paths.codexRoot)

        let destination = fixture.recoveredURL(sessionID: "multi-chunk")
        let restored = try BackupFileVerifier().verifyFull(
            destination,
            expectedByteCount: expected.byteCount,
            expectedLineCount: expected.lineCount,
            expectedContentHash: expected.contentHash,
            expectedChunkHashes: expected.chunkHashes
        )
        #expect(expected.chunkHashes.count > 3)
        #expect(restored == expected)
        #expect(result.restoredSessionIDs == ["multi-chunk"])
    }

    @Test
    func oneUnsafeSourceFailsWholePreflightWithoutCreatingDestinations() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "safe", title: "Safe", contents: fixture.line("safe"))
        try fixture.addEscapingSymlinkBackup(sessionID: "unsafe")
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        #expect(throws: (any Error).self) {
            _ = try restorer.preflight(sessionIDs: ["safe", "unsafe"], currentSessionIDs: [])
        }

        #expect(FileManager.default.fileExists(atPath: fixture.recoveredURL(sessionID: "safe").path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.codexRoot.appendingPathComponent("sessions/recovered").path) == false)
    }

    @Test
    func existingSessionsAreExcludedAndFinalDestinationIsNeverOverwritten() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "already-live", title: "Live", contents: fixture.line("backup"))
        try fixture.addBackup(sessionID: "race", title: "Race", contents: fixture.line("backup"))
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(
            sessionIDs: ["already-live", "race"],
            currentSessionIDs: ["already-live"]
        )
        let racedDestination = fixture.recoveredURL(sessionID: "race")
        try FileManager.default.createDirectory(at: racedDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(fixture.line("live").utf8).write(to: racedDestination)

        let result = try restorer.restore(plan, to: fixture.paths.codexRoot)

        #expect(plan.skippedExistingSessionIDs == ["already-live"])
        #expect(result.restoredSessionIDs.isEmpty)
        #expect(result.skippedExistingSessionIDs == ["already-live", "race"])
        #expect(try String(contentsOf: racedDestination, encoding: .utf8) == fixture.line("live"))
    }

    @Test
    func restoreRevalidatesSourceAfterPreflight() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        let source = try fixture.addBackup(sessionID: "changed", title: "Changed", contents: fixture.line("safe"))
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(sessionIDs: ["changed"], currentSessionIDs: [])
        let outside = fixture.root.appendingPathComponent("outside.jsonl")
        try Data(fixture.line("outside").utf8).write(to: outside)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try restorer.restore(plan, to: fixture.paths.codexRoot)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recoveredURL(sessionID: "changed").path) == false)
    }

    @Test
    func preflightRejectsSameLengthTamperingAndUntrustedLegacyBackups() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        let source = try fixture.addBackup(
            sessionID: "tampered",
            title: "Tampered",
            contents: fixture.line("safe-data")
        )
        try Data(fixture.line("evil-data").utf8).write(to: source)
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        #expect(throws: (any Error).self) {
            _ = try restorer.preflight(sessionIDs: ["tampered"], currentSessionIDs: [])
        }

        try fixture.addBackup(sessionID: "untrusted", title: "Untrusted", contents: fixture.line("legacy"))
        try fixture.removeVerification(sessionID: "untrusted")
        try fixture.clearContentHash(sessionID: "untrusted")
        #expect(throws: (any Error).self) {
            _ = try restorer.preflight(sessionIDs: ["untrusted"], currentSessionIDs: [])
        }
    }

    @Test
    func legacyContentHashBackupStillRestores() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "legacy", title: "Legacy", contents: fixture.line("trusted"))
        try fixture.removeVerification(sessionID: "legacy")
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        let plan = try restorer.preflight(sessionIDs: ["legacy"], currentSessionIDs: [])
        let result = try restorer.restore(plan, to: fixture.paths.codexRoot)

        #expect(result.restoredSessionIDs == ["legacy"])
    }

    @Test
    func freshComputerWithoutCodexDirectoryRestoresAfterSuccessfulPreflight() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "fresh", title: "Fresh", contents: fixture.line("fresh"))
        try FileManager.default.removeItem(at: fixture.paths.codexRoot)
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)

        let plan = try restorer.preflight(sessionIDs: ["fresh"], currentSessionIDs: [])
        #expect(FileManager.default.fileExists(atPath: fixture.paths.codexRoot.path) == false)
        let result = try restorer.restore(plan, to: fixture.paths.codexRoot)

        #expect(result.restoredSessionIDs == ["fresh"])
        #expect(FileManager.default.fileExists(atPath: fixture.recoveredURL(sessionID: "fresh").path))
    }

    @Test
    func stagingVerificationRejectsSourceReplacementAfterPreflight() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        let source = try fixture.addBackup(
            sessionID: "replaced",
            title: "Replaced",
            contents: fixture.line("original")
        )
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(sessionIDs: ["replaced"], currentSessionIDs: [])
        try Data(fixture.line("modified").utf8).write(to: source)

        #expect(throws: (any Error).self) {
            _ = try restorer.restore(plan, to: fixture.paths.codexRoot)
        }
        #expect(FileManager.default.fileExists(atPath: fixture.recoveredURL(sessionID: "replaced").path) == false)
    }

    @Test
    func freshDirectoryCreatorRejectsCodexSymlinkRace() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "linked-root", title: "Linked", contents: fixture.line("safe"))
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(sessionIDs: ["linked-root"], currentSessionIDs: [])
        let outside = fixture.root.appendingPathComponent("outside-codex", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: fixture.paths.codexRoot)
        try FileManager.default.createSymbolicLink(at: fixture.paths.codexRoot, withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try restorer.restore(plan, to: fixture.paths.codexRoot)
        }
        #expect(FileManager.default.fileExists(atPath: outside.appendingPathComponent("sessions").path) == false)
    }

    @Test
    func indexWriteFailureRollsBackAllNewlyPublishedSessions() throws {
        let fixture = try DirectRecoveryFixture()
        defer { fixture.cleanup() }
        try fixture.addBackup(sessionID: "index-failure", title: "Index failure", contents: fixture.line("safe"))
        let restorer = IncrementalRecoveryRestorer(paths: fixture.paths)
        let plan = try restorer.preflight(sessionIDs: ["index-failure"], currentSessionIDs: [])
        let indexURL = fixture.paths.codexRoot.appendingPathComponent("session_index.jsonl", isDirectory: true)
        try FileManager.default.createDirectory(at: indexURL, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            _ = try restorer.restore(plan, to: fixture.paths.codexRoot)
        }

        #expect(FileManager.default.fileExists(atPath: fixture.recoveredURL(sessionID: "index-failure").path) == false)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: indexURL.path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

private final class DirectRecoveryFixture {
    let root: URL
    let paths: BackupPaths
    let now = Date(timeIntervalSince1970: 1_783_824_000)
    private var records: [String: BackupSessionRecord] = [:]
    private var verifications: [String: BackupSessionVerification] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalRecoveryRestorerTests-\(UUID().uuidString)", isDirectory: true)
        paths = BackupPaths(
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("nas/incremental-backups", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        try FileManager.default.createDirectory(
            at: paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
    }

    @discardableResult
    func addBackup(sessionID: String, title: String, contents: String) throws -> URL {
        let relativePath = "sessions/\(sessionID).jsonl"
        let source = paths.backupRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: source)
        let verified = try BackupFileVerifier().verifyFull(source)
        records[sessionID] = record(
            sessionID: sessionID,
            title: title,
            backupPath: relativePath,
            byteCount: verified.byteCount,
            lineCount: verified.lineCount,
            contentHash: verified.contentHash
        )
        verifications[sessionID] = BackupSessionVerification(
            backupPath: relativePath,
            byteCount: verified.byteCount,
            lineCount: verified.lineCount,
            chunkHashes: verified.chunkHashes,
            verifiedAt: now
        )
        try saveManifest()
        try saveVerification()
        return source
    }

    func addEscapingSymlinkBackup(sessionID: String) throws {
        let outside = root.appendingPathComponent("outside-\(sessionID).jsonl")
        try Data(line("outside").utf8).write(to: outside)
        let relativePath = "sessions/\(sessionID).jsonl"
        let source = paths.backupRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        records[sessionID] = record(
            sessionID: sessionID,
            title: sessionID,
            backupPath: relativePath,
            byteCount: Int64(Data(line("outside").utf8).count),
            lineCount: 1,
            contentHash: nil
        )
        try saveManifest()
    }

    func recoveredURL(sessionID: String) -> URL {
        paths.codexRoot.appendingPathComponent("sessions/recovered/\(sessionID).jsonl")
    }

    func line(_ value: String) -> String {
        "{\"role\":\"user\",\"content\":\"\(value)\"}\n"
    }

    func writeExistingIndex() throws {
        let data = Data("{\"id\":\"existing\",\"thread_name\":\"Existing\",\"rollout_path\":\"/existing.jsonl\"}\n".utf8)
        try data.write(to: paths.codexRoot.appendingPathComponent("session_index.jsonl"))
    }

    func indexIDs() throws -> [String] {
        let text = try String(contentsOf: paths.codexRoot.appendingPathComponent("session_index.jsonl"), encoding: .utf8)
        return try text.split(separator: "\n").compactMap { line in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            return object?["id"] as? String
        }
    }

    func temporaryFiles(beside target: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
            .filter { $0.contains(".tmp-") }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func removeVerification(sessionID: String) throws {
        verifications.removeValue(forKey: sessionID)
        try saveVerification()
    }

    func clearContentHash(sessionID: String) throws {
        records[sessionID]?.contentHash = nil
        try saveManifest()
    }

    private func record(
        sessionID: String,
        title: String,
        backupPath: String,
        byteCount: Int64,
        lineCount: Int,
        contentHash: String?
    ) -> BackupSessionRecord {
        BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: paths.codexRoot.appendingPathComponent("sessions/\(sessionID).jsonl").path,
            backupPath: backupPath,
            title: title,
            firstSeenAt: now,
            lastBackedUpAt: now,
            lineCount: lineCount,
            bytesBackedUp: byteCount,
            status: "active",
            contentHash: contentHash
        )
    }

    private func saveManifest() throws {
        let manifest = BackupManifest(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            createdAt: now,
            updatedAt: now,
            sessions: records
        )
        try BackupManifestStore(manifestURL: paths.manifestURL).save(manifest)
    }

    private func saveVerification() throws {
        try BackupVerificationStore(fileURL: paths.verificationURL).save(
            BackupVerificationDocument(sessions: verifications)
        )
    }
}
