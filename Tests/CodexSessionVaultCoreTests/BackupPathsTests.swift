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
