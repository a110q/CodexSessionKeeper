import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func defaultLayoutUsesCodexAndIncrementalBackupRoots() {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)

    #expect(paths.codexRoot.path == "/Users/alice/.codex")
    #expect(paths.backupRoot.path == "/Users/alice/.codex-session-vault/incremental-backups")
    #expect(paths.sessionsRoot.path == "/Users/alice/.codex-session-vault/incremental-backups/sessions")
    #expect(paths.manifestURL.path == "/Users/alice/.codex-session-vault/incremental-backups/manifest.json")
    #expect(paths.cursorDatabaseURL.path == "/Users/alice/.codex-session-vault/incremental-backups/cursors.sqlite")
    #expect(paths.statusURL.path == "/Users/alice/.codex-session-vault/incremental-backups/status.json")
    #expect(paths.logURL.path == "/Users/alice/.codex-session-vault/incremental-backups/logs/backup-agent.log")
}

@Test
func explicitNASLayoutSeparatesRemoteContentFromLocalControlState() {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let codexRoot = home.appendingPathComponent(".codex", isDirectory: true)
    let backupRoot = URL(fileURLWithPath: "/Volumes/文件中转站/codex会话备份/运营部/陈超/devices/mac-a13f/incremental-backups", isDirectory: true)
    let stateRoot = home.appendingPathComponent(".codex-session-vault/nas-state/mac-a13f", isDirectory: true)
    let paths = BackupPaths(
        homeDirectory: home,
        codexRoot: codexRoot,
        backupRoot: backupRoot,
        stateRoot: stateRoot
    )

    #expect(paths.cursorDatabaseURL.path == stateRoot.appendingPathComponent("cursors.sqlite").path)
    #expect(paths.localStatusURL.path == stateRoot.appendingPathComponent("status.json").path)
    #expect(paths.logURL.path == stateRoot.appendingPathComponent("logs/backup-agent.log").path)
    #expect(paths.manifestURL.path == backupRoot.appendingPathComponent("manifest.json").path)
    #expect(paths.remoteStatusURL.path == backupRoot.appendingPathComponent("status.json").path)
    #expect(paths.sessionsRoot.path == backupRoot.appendingPathComponent("sessions").path)
    #expect(paths.archivedSessionsRoot.path == backupRoot.appendingPathComponent("archived_sessions").path)
}

@Test
func backupFileURLMirrorsActiveAndArchivedSourceRelativePaths() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupPathsMirrorTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
    let backupRoot = root.appendingPathComponent("nas-backup", isDirectory: true)
    let active = codexRoot.appendingPathComponent("sessions/2026/07/active.jsonl")
    let archived = codexRoot.appendingPathComponent("archived_sessions/2026/07/archived.jsonl")
    for source in [active, archived] {
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: source)
    }
    let paths = BackupPaths(codexRoot: codexRoot, backupRoot: backupRoot, stateRoot: root.appendingPathComponent("state"))

    #expect(try paths.backupFileURL(for: active).path == backupRoot.appendingPathComponent("sessions/2026/07/active.jsonl").path)
    #expect(try paths.backupFileURL(for: archived).path == backupRoot.appendingPathComponent("archived_sessions/2026/07/archived.jsonl").path)
}

@Test
func backupFileURLRejectsOutsideLinkedAndNonJSONLSources() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BackupPathsSafetyTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
    let sessionsRoot = codexRoot.appendingPathComponent("sessions", isDirectory: true)
    let backupRoot = root.appendingPathComponent("nas-backup", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.jsonl")
    let nonJSONL = sessionsRoot.appendingPathComponent("notes.txt")
    let linked = sessionsRoot.appendingPathComponent("linked.jsonl")
    try Data("{}\n".utf8).write(to: outside)
    try Data("notes".utf8).write(to: nonJSONL)
    try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outside)
    let paths = BackupPaths(codexRoot: codexRoot, backupRoot: backupRoot, stateRoot: root.appendingPathComponent("state"))

    #expect(throws: BackupPathsError.sourceOutsideCodexSessionRoots(outside.path)) {
        _ = try paths.backupFileURL(for: outside)
    }
    #expect(throws: BackupPathsError.sourceIsNotJSONL(nonJSONL.path)) {
        _ = try paths.backupFileURL(for: nonJSONL)
    }
    #expect(throws: BackupPathsError.unsafeSource(linked.path)) {
        _ = try paths.backupFileURL(for: linked)
    }
}

@Test
func backupFilePathUsesFirstSeenDateInUTC() throws {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)
    let firstSeenAt = try #require(ISO8601DateFormatter().date(from: "2026-07-04T00:30:00Z"))

    let url = paths.backupFileURL(sessionID: "session-123", firstSeenAt: firstSeenAt)

    #expect(url.path == "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl")
}

@Test
func relativeBackupPathUsesForwardSlashPathRelativeToBackupRoot() {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)
    let file = URL(fileURLWithPath: "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04/session-123.jsonl")

    #expect(paths.relativeBackupPath(for: file) == Optional("sessions/2026/07/04/session-123.jsonl"))
}

@Test
func relativeBackupPathReturnsNilForFilesOutsideBackupRoot() {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)
    let file = URL(fileURLWithPath: "/Users/alice/Documents/session-123.jsonl")

    #expect(paths.relativeBackupPath(for: file) == nil)
}

@Test
func relativeBackupPathReturnsNilForBackupRootItself() {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)

    #expect(paths.relativeBackupPath(for: paths.backupRoot) == nil)
}

@Test
func backupFilePathSanitizesSessionIDForSafeLocalFilenames() throws {
    let home = URL(fileURLWithPath: "/Users/alice", isDirectory: true)
    let paths = BackupPaths(homeDirectory: home)
    let firstSeenAt = try #require(ISO8601DateFormatter().date(from: "2026-07-04T10:12:00Z"))

    let url = paths.backupFileURL(sessionID: "../session 123/../../evil", firstSeenAt: firstSeenAt)

    #expect(url.lastPathComponent == "session-123-evil.jsonl")
    #expect(url.deletingLastPathComponent().path == "/Users/alice/.codex-session-vault/incremental-backups/sessions/2026/07/04")
    #expect(paths.relativeBackupPath(for: url) == Optional("sessions/2026/07/04/session-123-evil.jsonl"))
}

@Test
func backupModelsRoundTripThroughCodable() throws {
    let firstSeenAt = Date(timeIntervalSince1970: 1_783_123_200)
    let lastBackedUpAt = Date(timeIntervalSince1970: 1_783_126_800)
    let record = BackupSessionRecord(
        sessionId: "session-123",
        sourcePath: "/Users/alice/.codex/sessions/session-123.jsonl",
        backupPath: "sessions/2026/07/04/session-123.jsonl",
        title: "Planning session",
        firstSeenAt: firstSeenAt,
        lastBackedUpAt: lastBackedUpAt,
        lineCount: 42,
        bytesBackedUp: 2_048,
        status: "backedUp"
    )
    let manifest = BackupManifest(
        version: 1,
        codexRoot: "/Users/alice/.codex",
        backupRoot: "/Users/alice/.codex-session-vault/incremental-backups",
        createdAt: firstSeenAt,
        updatedAt: lastBackedUpAt,
        sessions: [record.sessionId: record]
    )
    let status = BackupStatus(
        agentVersion: "1.0.0",
        enabled: true,
        status: .running,
        mode: .watching,
        codexRoot: manifest.codexRoot,
        backupRoot: manifest.backupRoot,
        firstRunAt: firstSeenAt,
        lastStartedAt: firstSeenAt,
        lastHeartbeatAt: lastBackedUpAt,
        lastBackupAt: lastBackedUpAt,
        sessionCount: 1,
        lineCount: record.lineCount,
        bytesBackedUp: record.bytesBackedUp,
        autoStartEnabled: true,
        lastError: nil
    )

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    let decodedManifest = try decoder.decode(BackupManifest.self, from: encoder.encode(manifest))
    let decodedStatus = try decoder.decode(BackupStatus.self, from: encoder.encode(status))

    #expect(decodedManifest == manifest)
    #expect(decodedStatus == status)
}
