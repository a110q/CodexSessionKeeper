import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct IncrementalBackupCatalogTests {
    @Test
    func classifiesMissingAndExistingSessions() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.writeBackup(
            relativePath: "sessions/2026/07/08/missing.jsonl",
            contents: #"{"role":"user","content":"restore me"}"# + "\n"
        )
        try fixture.writeBackup(
            relativePath: "sessions/2026/07/08/existing.jsonl",
            contents: #"{"role":"user","content":"already here"}"# + "\n"
        )
        try fixture.saveManifest(records: [
            fixture.makeRecord(
                sessionID: "missing",
                backupPath: "sessions/2026/07/08/missing.jsonl",
                title: "restore me"
            ),
            fixture.makeRecord(
                sessionID: "existing",
                backupPath: "sessions/2026/07/08/existing.jsonl",
                title: "already here"
            )
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: ["existing"])

        #expect(result.totalCount == 2)
        #expect(result.missingCount == 1)
        #expect(result.existingCount == 1)
        #expect(result.candidates.first { $0.sessionId == "missing" }?.status == .missing)
        #expect(result.candidates.first { $0.sessionId == "existing" }?.status == .existing)
    }

    @Test
    func invalidBackupPathDoesNotEscapeBackupRoot() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.saveManifest(records: [
            fixture.makeRecord(sessionID: "bad", backupPath: "../outside.jsonl", title: "bad")
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: [])

        let bad = try #require(result.candidates.first)
        #expect(bad.status == .invalidBackup)
        #expect(bad.error?.contains("escapes backup root") == true)
        #expect(result.errorCount == 1)
    }

    @Test
    func missingBackupFileIsVisibleButNotRestorable() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        try fixture.saveManifest(records: [
            fixture.makeRecord(
                sessionID: "missing-file",
                backupPath: "sessions/2026/07/08/missing-file.jsonl",
                title: "missing file"
            )
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: [])

        let candidate = try #require(result.candidates.first)
        #expect(candidate.status == .backupFileMissing)
        #expect(candidate.isRestorable == false)
        #expect(result.errorCount == 1)
    }

    @Test
    func symlinkBackupFileEscapingRootIsInvalid() throws {
        let fixture = try IncrementalCatalogFixture()
        defer { fixture.cleanup() }
        let outsideDirectory = fixture.tempDirectory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let outsideFile = outsideDirectory.appendingPathComponent("escaped.jsonl", isDirectory: false)
        try Data(#"{"role":"user","content":"outside"}"#.utf8).write(to: outsideFile)
        let symlinkURL = fixture.paths.backupRoot.appendingPathComponent("escaped-link.jsonl", isDirectory: false)
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)
        try fixture.saveManifest(records: [
            fixture.makeRecord(sessionID: "symlink", backupPath: "escaped-link.jsonl", title: "symlink")
        ])

        let result = try IncrementalBackupCatalog(paths: fixture.paths).load(currentSessionIDs: [])

        let candidate = try #require(result.candidates.first)
        #expect(candidate.status == .invalidBackup)
        #expect(candidate.error?.contains("escapes backup root") == true)
    }
}

private final class IncrementalCatalogFixture {
    let tempDirectory: URL
    let paths: BackupPaths
    let now: Date

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IncrementalCatalogFixture-\(UUID().uuidString)", isDirectory: true)
        paths = BackupPaths(
            homeDirectory: tempDirectory,
            codexRoot: tempDirectory.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: tempDirectory.appendingPathComponent("incremental-backups", isDirectory: true)
        )
        now = try #require(ISO8601DateFormatter().date(from: "2026-07-08T12:00:00Z"))
        try FileManager.default.createDirectory(at: paths.codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func writeBackup(relativePath: String, contents: String) throws {
        let url = paths.backupRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func saveManifest(records: [BackupSessionRecord]) throws {
        let manifest = BackupManifest(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            createdAt: now,
            updatedAt: now,
            sessions: Dictionary(uniqueKeysWithValues: records.map { ($0.sessionId, $0) })
        )
        try BackupManifestStore(manifestURL: paths.manifestURL).save(manifest)
    }

    func makeRecord(sessionID: String, backupPath: String, title: String?) -> BackupSessionRecord {
        BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: paths.codexRoot.appendingPathComponent("sessions/\(sessionID).jsonl").path,
            backupPath: backupPath,
            title: title,
            firstSeenAt: now,
            lastBackedUpAt: now,
            lineCount: 1,
            bytesBackedUp: 32,
            status: "active"
        )
    }
}
