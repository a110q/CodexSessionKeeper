import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupRecoveryBuilderTests {

@Test
func buildsPackageFromOneIncrementalBackup() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    let sessionID = "session-1"
    let contents = """
    {"role":"user","content":"Recover this"}
    {"role":"assistant","content":"Recovered"}

    """
    let backupPath = "sessions/2026/07/04/session-1.jsonl"
    try fixture.writeBackup(relativePath: backupPath, contents: contents)
    try fixture.saveManifest(records: [
        fixture.makeRecord(
            sessionID: sessionID,
            backupPath: backupPath,
            title: "Recover this",
            lineCount: 2,
            bytesBackedUp: Int64(Data(contents.utf8).count)
        )
    ])
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    let package = try builder.buildRecoveryPackage(sessionIDs: [sessionID])

    #expect(FileManager.default.fileExists(atPath: package.snapshotJSON.path))
    #expect(FileManager.default.fileExists(atPath: package.sessionIndexURL.path))
    let recoveredURL = package.dataURL
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("recovered", isDirectory: true)
        .appendingPathComponent("session-1.jsonl", isDirectory: false)
    #expect(try String(contentsOf: recoveredURL, encoding: .utf8) == contents)

    let entries = try readSessionIndex(at: package.sessionIndexURL)
    #expect(entries.count == 1)
    guard let entry = entries.first else {
        #expect(Bool(false), "Expected one session index entry")
        return
    }
    #expect(entry.id == sessionID)
    #expect(entry.title == "Recover this")
    #expect(entry.threadName == "Recover this")
    #expect(entry.rolloutPath == fixture.paths.codexRoot
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("recovered", isDirectory: true)
        .appendingPathComponent("session-1.jsonl", isDirectory: false)
        .path)
    #expect(entry.sourcePath == fixture.sourcePath(for: sessionID))
    #expect(entry.backupPath == backupPath)
    #expect(entry.updatedAt == "2026-07-04T12:05:00Z")
    #expect(entry.lineCount == 2)
    #expect(entry.bytesBackedUp == Int64(Data(contents.utf8).count))

    let snapshot = try readSnapshot(at: package.snapshotJSON)
    #expect(package.rootURL.lastPathComponent == snapshot.id)
    #expect(snapshot.reason == "incremental-recovery")
    #expect(snapshot.kind == "system")
    #expect(snapshot.codexRoot == fixture.paths.codexRoot.path)
    #expect(snapshot.backupRoot == fixture.paths.backupRoot.path)
    #expect(snapshot.sessionCount == 1)
    #expect(snapshot.archivedSessionCount == 0)
    #expect(snapshot.includedPaths.contains("sessions"))
    #expect(snapshot.includedPaths == [
        "session_index.jsonl",
        "sessions",
        "sessions/recovered/session-1.jsonl"
    ])
}

@Test
func multipleRequestedSessionsAreDedupedAndSortedInSessionIndex() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    try fixture.writeBackup(
        relativePath: "sessions/2026/07/04/session-b.jsonl",
        contents: #"{"role":"user","content":"B"}"# + "\n"
    )
    try fixture.writeBackup(
        relativePath: "sessions/2026/07/04/session-a.jsonl",
        contents: #"{"role":"user","content":"A"}"# + "\n"
    )
    try fixture.saveManifest(records: [
        fixture.makeRecord(
            sessionID: "session-b",
            backupPath: "sessions/2026/07/04/session-b.jsonl",
            title: "B"
        ),
        fixture.makeRecord(
            sessionID: "session-a",
            backupPath: "sessions/2026/07/04/session-a.jsonl",
            title: "A"
        )
    ])
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    let package = try builder.buildRecoveryPackage(sessionIDs: ["session-b", "session-a", "session-b"])

    let entries = try readSessionIndex(at: package.sessionIndexURL)
    #expect(entries.map { $0.id } == ["session-a", "session-b"])
}

@Test
func throwsClearErrorWhenNoSelectedSessionsExist() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    try fixture.saveManifest(records: [
        fixture.makeRecord(
            sessionID: "other-session",
            backupPath: "sessions/2026/07/04/other-session.jsonl"
        )
    ])
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    expectLocalizedError(containing: "No requested sessions were found") {
        _ = try builder.buildRecoveryPackage(sessionIDs: ["missing-session"])
    }
}

@Test
func throwsClearErrorWhenBackupFileIsMissing() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    try fixture.saveManifest(records: [
        fixture.makeRecord(
            sessionID: "missing-file",
            backupPath: "sessions/2026/07/04/missing-file.jsonl"
        )
    ])
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    expectLocalizedError(containing: "Backup file is missing") {
        _ = try builder.buildRecoveryPackage(sessionIDs: ["missing-file"])
    }
}

@Test
func rejectsBackupPathTraversalAndAbsolutePathsEscapingBackupRoot() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    try fixture.saveManifest(records: [
        fixture.makeRecord(sessionID: "traversal", backupPath: "../outside.jsonl")
    ])
    expectLocalizedError(containing: "escapes backup root") {
        _ = try builder.buildRecoveryPackage(sessionIDs: ["traversal"])
    }

    try fixture.saveManifest(records: [
        fixture.makeRecord(sessionID: "absolute", backupPath: "/tmp/outside.jsonl")
    ])
    expectLocalizedError(containing: "absolute") {
        _ = try builder.buildRecoveryPackage(sessionIDs: ["absolute"])
    }
}

@Test
func rejectsBackupPathSymlinkEscapingBackupRoot() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    let outsideDirectory = fixture.tempDirectory.appendingPathComponent("outside", isDirectory: true)
    try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
    let outsideFile = outsideDirectory.appendingPathComponent("escaped.jsonl", isDirectory: false)
    try Data(#"{"role":"user","content":"outside"}"#.utf8).write(to: outsideFile)
    let symlinkURL = fixture.paths.backupRoot.appendingPathComponent("escaped-link.jsonl", isDirectory: false)
    try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)
    try fixture.saveManifest(records: [
        fixture.makeRecord(sessionID: "symlink", backupPath: "escaped-link.jsonl")
    ])
    let builder = BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })

    expectLocalizedError(containing: "escapes backup root") {
        _ = try builder.buildRecoveryPackage(sessionIDs: ["symlink"])
    }
}

@Test
func recoveryPackageOnlyContainsRequestedSessionFiles() throws {
    let fixture = try BackupRecoveryFixture()
    defer { fixture.cleanup() }
    try fixture.writeBackup(
        relativePath: "sessions/2026/07/08/a.jsonl",
        contents: #"{"role":"user","content":"A"}"# + "\n"
    )
    try fixture.writeBackup(
        relativePath: "sessions/2026/07/08/b.jsonl",
        contents: #"{"role":"user","content":"B"}"# + "\n"
    )
    try fixture.saveManifest(records: [
        fixture.makeRecord(
            sessionID: "a",
            backupPath: "sessions/2026/07/08/a.jsonl",
            title: "A"
        ),
        fixture.makeRecord(
            sessionID: "b",
            backupPath: "sessions/2026/07/08/b.jsonl",
            title: "B"
        )
    ])

    let package = try BackupRecoveryBuilder(paths: fixture.paths, now: { fixture.now })
        .buildRecoveryPackage(sessionIDs: ["b"])

    let recoveredRoot = package.dataURL
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("recovered", isDirectory: true)
    #expect(FileManager.default.fileExists(
        atPath: recoveredRoot.appendingPathComponent("b.jsonl", isDirectory: false).path
    ))
    #expect(!FileManager.default.fileExists(
        atPath: recoveredRoot.appendingPathComponent("a.jsonl", isDirectory: false).path
    ))
    let entries = try readSessionIndex(at: package.sessionIndexURL)
    #expect(entries.map(\.id) == ["b"])
}
}

private struct RecoveryIndexEntry: Decodable {
    let id: String
    let title: String
    let threadName: String
    let rolloutPath: String
    let sourcePath: String
    let backupPath: String
    let updatedAt: String
    let lineCount: Int
    let bytesBackedUp: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case threadName = "thread_name"
        case rolloutPath = "rollout_path"
        case sourcePath = "source_path"
        case backupPath = "backup_path"
        case updatedAt = "updated_at"
        case lineCount = "line_count"
        case bytesBackedUp = "bytes_backed_up"
    }
}

private struct RecoverySnapshot: Decodable {
    let id: String
    let reason: String
    let kind: String
    let codexRoot: String
    let backupRoot: String
    let sessionCount: Int
    let archivedSessionCount: Int
    let includedPaths: [String]
}

private final class BackupRecoveryFixture {
    let tempDirectory: URL
    let paths: BackupPaths
    let now: Date
    let updatedAt: Date

    init() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupRecoveryBuilderTests-\(UUID().uuidString)", isDirectory: true)
        let codexRoot = tempDirectory.appendingPathComponent(".codex", isDirectory: true)
        let backupRoot = tempDirectory.appendingPathComponent("incremental-backups", isDirectory: true)
        paths = BackupPaths(
            homeDirectory: tempDirectory,
            codexRoot: codexRoot,
            backupRoot: backupRoot
        )
        now = try #require(ISO8601DateFormatter().date(from: "2026-07-04T12:34:56Z"))
        updatedAt = try #require(ISO8601DateFormatter().date(from: "2026-07-04T12:05:00Z"))
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func sourcePath(for sessionID: String) -> String {
        paths.codexRoot
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
            .path
    }

    func writeBackup(relativePath: String, contents: String) throws {
        let url = paths.backupRoot.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func makeRecord(
        sessionID: String,
        backupPath: String,
        title: String? = nil,
        lineCount: Int = 1,
        bytesBackedUp: Int64 = 1
    ) -> BackupSessionRecord {
        BackupSessionRecord(
            sessionId: sessionID,
            sourcePath: sourcePath(for: sessionID),
            backupPath: backupPath,
            title: title,
            firstSeenAt: now,
            lastBackedUpAt: updatedAt,
            lineCount: lineCount,
            bytesBackedUp: bytesBackedUp,
            status: "active"
        )
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
}

private func readSessionIndex(at url: URL) throws -> [RecoveryIndexEntry] {
    let text = try String(contentsOf: url, encoding: .utf8)
    let decoder = JSONDecoder()
    return try text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { try decoder.decode(RecoveryIndexEntry.self, from: Data($0.utf8)) }
}

private func readSnapshot(at url: URL) throws -> RecoverySnapshot {
    let data = try Data(contentsOf: url)
    let decoder = JSONDecoder()
    return try decoder.decode(RecoverySnapshot.self, from: data)
}

private func expectLocalizedError(
    containing expectedText: String,
    _ body: () throws -> Void
) {
    do {
        try body()
        #expect(Bool(false), "Expected an error containing '\(expectedText)'")
    } catch {
        #expect(
            error.localizedDescription.localizedCaseInsensitiveContains(expectedText),
            "Expected '\(error.localizedDescription)' to contain '\(expectedText)'"
        )
    }
}
