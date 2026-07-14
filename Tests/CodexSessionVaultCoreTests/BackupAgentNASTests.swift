import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupAgentNASTests {
    @Test
    func missingTargetRootIsNotRecreatedLocallyAndWritesLocalErrorStatus() throws {
        let fixture = try DirectNASBackupFixture(createBackupRoot: false)
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "missing-root.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()

        #expect(throws: BackupTargetValidationError.targetUnavailable(fixture.paths.backupRoot.path)) {
            try agent.performOneShotScan()
        }

        #expect(FileManager.default.fileExists(atPath: fixture.paths.backupRoot.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.manifestURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.remoteStatusURL.path) == false)
        let status = try fixture.loadLocalStatus()
        #expect(status.status == .error)
        #expect(status.lastError?.contains("NAS") == true)
    }

    @Test
    func targetValidationRunsBeforeRemoteSideEffects() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "guarded.jsonl", contents: fixture.line("one"))
        var validationCount = 0
        let validator = BackupTargetValidator {
            validationCount += 1
            throw DirectNASBackupTestError.injectedTargetFailure
        }
        let agent = fixture.makeAgent(targetValidator: validator)

        #expect(throws: DirectNASBackupTestError.injectedTargetFailure) {
            try agent.performOneShotScan()
        }

        #expect(validationCount == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.manifestURL.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.paths.backupRoot.path).isEmpty)
    }

    @Test
    func errorStatusDoesNotLaunchSecondDiscoveryOrCursorPass() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "no-rescan.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent(targetValidator: BackupTargetValidator {
            throw DirectNASBackupTestError.injectedTargetFailure
        })

        #expect(throws: DirectNASBackupTestError.injectedTargetFailure) {
            try agent.performOneShotScan()
        }

        #expect(FileManager.default.fileExists(atPath: fixture.paths.cursorDatabaseURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.pendingSourcesURL.path) == false)
        #expect(try fixture.loadLocalStatus().status == .error)
    }

    @Test
    func failedDataSynchronizeDoesNotAdvanceCursorOrManifest() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "sync-failure.jsonl", contents: fixture.line("one"))
        let committer = BackupFileCommitter(synchronize: { _ in
            throw DirectNASBackupTestError.injectedSynchronizeFailure
        })
        let agent = fixture.makeAgent(fileCommitter: committer)

        #expect(throws: DirectNASBackupTestError.injectedSynchronizeFailure) {
            try agent.performOneShotScan()
        }

        #expect(try fixture.loadCursor(sourcePath: source.path) == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.manifestURL.path) == false)
        let target = try fixture.paths.backupFileURL(for: source)
        #expect(FileManager.default.fileExists(atPath: target.path) == false)
        if FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).isEmpty)
        }
    }

    @Test
    func interruptedAppendMatchingSourcePrefixResumesWithoutDuplicate() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "interrupted.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        let target = try fixture.paths.backupFileURL(for: source)

        try fixture.append(fixture.line("two"), to: source)
        try fixture.append(fixture.line("two"), to: target)
        try agent.performOneShotScan()

        #expect(try String(contentsOf: target, encoding: .utf8) == fixture.line("one") + fixture.line("two"))
        let recordedSourcePath = try #require(fixture.loadManifest().sessions["interrupted"]?.sourcePath)
        let cursor = try #require(try fixture.loadCursor(sourcePath: recordedSourcePath))
        #expect(cursor.lastByteOffset == Int64((fixture.line("one") + fixture.line("two")).utf8.count))
        #expect(cursor.lineCount == 2)
    }

    @Test
    func mismatchedInterruptedAppendRebuildsExactSource() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "mismatch.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        let target = try fixture.paths.backupFileURL(for: source)

        try fixture.append(fixture.line("good"), to: source)
        try fixture.append(fixture.line("evil"), to: target)
        try agent.performOneShotScan()

        #expect(try String(contentsOf: target, encoding: .utf8) == fixture.line("one") + fixture.line("good"))
        #expect(try fixture.temporaryFiles(beside: target).isEmpty)
    }

    @Test
    func sameSizeSourceRewriteAtomicallyReplacesStaleBackup() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "rewrite.jsonl", contents: fixture.line("AAAA"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        let target = try fixture.paths.backupFileURL(for: source)

        try Data(fixture.line("BBBB").utf8).write(to: source)
        try agent.performOneShotScan()

        #expect(try String(contentsOf: target, encoding: .utf8) == fixture.line("BBBB"))
        let manifest = try fixture.loadManifest()
        #expect(manifest.sessions["rewrite"]?.contentHash?.isEmpty == false)
    }

    @Test
    func archivedSourceUsesArchivedRelativeDestination() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeArchivedSession(
            relativePath: "2026/07/archived.jsonl",
            contents: fixture.line("archived")
        )

        try fixture.makeAgent().performOneShotScan()

        let record = try #require(fixture.loadManifest().sessions["archived"])
        #expect(record.backupPath == "archived_sessions/2026/07/archived.jsonl")
        #expect(try String(contentsOf: fixture.paths.backupFileURL(for: source), encoding: .utf8) == fixture.line("archived"))
    }

    @Test
    func pendingSessionCountUsesOnlyLocalSourceMetadata() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "pending.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        try fixture.append(fixture.line("two"), to: source)

        #expect(try agent.pendingSessionCount() == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.pendingSourcesURL.path))
        let pendingText = try String(contentsOf: fixture.paths.pendingSourcesURL, encoding: .utf8)
        #expect(pendingText.contains("one") == false)
        #expect(pendingText.contains("two") == false)
        let recordedSourcePath = try #require(fixture.loadManifest().sessions["pending"]?.sourcePath)
        let pendingRecords = try #require(
            JSONSerialization.jsonObject(with: Data(pendingText.utf8)) as? [[String: Any]]
        )
        #expect(pendingRecords.first?["sourcePath"] as? String == recordedSourcePath)
    }

    @Test
    func pendingSourceDeletedDuringOutageRemainsReportedUnrecoverable() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "deleted-pending.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        try fixture.append(fixture.line("two"), to: source)
        #expect(try agent.pendingSessionCount() == 1)
        try FileManager.default.removeItem(at: fixture.paths.backupRoot)

        #expect(throws: BackupTargetValidationError.self) {
            try agent.performOneShotScan()
        }
        try FileManager.default.removeItem(at: source)
        #expect(try agent.pendingSessionCount() == 1)

        let data = try Data(contentsOf: fixture.paths.pendingSourcesURL)
        let pendingRecords = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(pendingRecords.first?["unrecoverable"] as? Bool == true)
    }

    @Test
    func remoteStatusFailureWritesOnlyLocalErrorStatus() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "status-failure.jsonl", contents: fixture.line("one"))
        #expect(throws: (any Error).self) {
            try fixture.makeAgent(remoteStatusWriter: { _, _ in
                throw DirectNASBackupTestError.injectedTargetFailure
            }).performOneShotScan()
        }

        #expect(try fixture.loadLocalStatus().status == .error)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.remoteStatusURL.path) == false)
    }
}

private enum DirectNASBackupTestError: Error, Equatable {
    case injectedTargetFailure
    case injectedSynchronizeFailure
}

private final class DirectNASBackupFixture {
    let root: URL
    let paths: BackupPaths
    let now = Date(timeIntervalSince1970: 1_783_824_000)

    init(createBackupRoot: Bool = true) throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BackupAgentNASTests-\(UUID().uuidString)", isDirectory: true)
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let backupRoot = root.appendingPathComponent("mounted-nas/device/incremental-backups", isDirectory: true)
        let stateRoot = root.appendingPathComponent("local-state", isDirectory: true)
        paths = BackupPaths(
            codexRoot: codexRoot,
            backupRoot: backupRoot,
            stateRoot: stateRoot
        )
        try FileManager.default.createDirectory(
            at: codexRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        if createBackupRoot {
            try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeAgent(
        targetValidator: BackupTargetValidator? = nil,
        fileCommitter: BackupFileCommitter = BackupFileCommitter(),
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil
    ) -> BackupAgent {
        BackupAgent(
            paths: paths,
            now: { self.now },
            targetValidator: targetValidator ?? BackupTargetValidator(backupRoot: paths.backupRoot),
            fileCommitter: fileCommitter,
            remoteStatusWriter: remoteStatusWriter
        )
    }

    func line(_ content: String) -> String {
        "{\"role\":\"user\",\"content\":\"\(content)\"}\n"
    }

    @discardableResult
    func writeActiveSession(name: String, contents: String) throws -> URL {
        try writeSession(relativePath: "sessions/\(name)", contents: contents)
    }

    @discardableResult
    func writeArchivedSession(relativePath: String, contents: String) throws -> URL {
        try writeSession(relativePath: "archived_sessions/\(relativePath)", contents: contents)
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func loadManifest() throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: Data(contentsOf: paths.manifestURL))
    }

    func loadCursor(sourcePath: String) throws -> BackupCursor? {
        let store = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try store.open()
        return try store.cursor(sourcePath: sourcePath)
    }

    func loadLocalStatus() throws -> BackupStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupStatus.self, from: Data(contentsOf: paths.localStatusURL))
    }

    func temporaryFiles(beside target: URL) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
        return names.filter { $0.contains(".tmp-") }
    }

    private func writeSession(relativePath: String, contents: String) throws -> URL {
        let url = paths.codexRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
