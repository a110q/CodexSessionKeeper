import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func manifestStoreCreatesDefaultManifestWhenFileIsMissing() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let manifestURL = tempDirectory.appendingPathComponent("manifest.json")
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z"))
    let store = BackupManifestStore(manifestURL: manifestURL)

    let manifest = try store.loadOrCreate(
        codexRoot: "/Users/alice/.codex",
        backupRoot: "/Users/alice/.codex-session-vault/incremental-backups",
        now: now
    )

    #expect(manifest == BackupManifest(
        version: 1,
        codexRoot: "/Users/alice/.codex",
        backupRoot: "/Users/alice/.codex-session-vault/incremental-backups",
        createdAt: now,
        updatedAt: now,
        sessions: [:]
    ))
}

@Test
func manifestStoreSavesAndLoadsRoundTripPreservingSessionRecord() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let manifestURL = tempDirectory.appendingPathComponent("manifest.json")
    let store = BackupManifestStore(manifestURL: manifestURL)
    let firstSeenAt = try #require(ISO8601DateFormatter().date(from: "2026-07-04T10:00:00Z"))
    let backedUpAt = try #require(ISO8601DateFormatter().date(from: "2026-07-04T10:05:00Z"))
    let record = BackupSessionRecord(
        sessionId: "session-123",
        sourcePath: "/Users/alice/.codex/sessions/session-123.jsonl",
        backupPath: "sessions/2026/07/04/session-123.jsonl",
        title: "Plan the backup work",
        firstSeenAt: firstSeenAt,
        lastBackedUpAt: backedUpAt,
        lineCount: 12,
        bytesBackedUp: 3_456,
        status: "backedUp"
    )
    let manifest = BackupManifest(
        version: 1,
        codexRoot: "/Users/alice/.codex",
        backupRoot: "/Users/alice/.codex-session-vault/incremental-backups",
        createdAt: firstSeenAt,
        updatedAt: backedUpAt,
        sessions: [record.sessionId: record]
    )

    try store.save(manifest)
    let loaded = try store.loadOrCreate(codexRoot: "ignored", backupRoot: "ignored")

    #expect(loaded == manifest)
}

@Test
func manifestStoreCreatesParentDirectoryOnSave() throws {
    let tempDirectory = makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let manifestURL = tempDirectory
        .appendingPathComponent("nested", isDirectory: true)
        .appendingPathComponent("backup", isDirectory: true)
        .appendingPathComponent("manifest.json")
    let store = BackupManifestStore(manifestURL: manifestURL)
    let now = try #require(ISO8601DateFormatter().date(from: "2026-07-04T12:00:00Z"))
    let manifest = BackupManifest(
        codexRoot: "/Users/alice/.codex",
        backupRoot: "/Users/alice/.codex-session-vault/incremental-backups",
        createdAt: now,
        updatedAt: now
    )

    try store.save(manifest)

    var isDirectory: ObjCBool = false
    let parentExists = FileManager.default.fileExists(
        atPath: manifestURL.deletingLastPathComponent().path,
        isDirectory: &isDirectory
    )
    #expect(parentExists)
    #expect(isDirectory.boolValue)
    #expect(FileManager.default.fileExists(atPath: manifestURL.path))
}

private func makeTemporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSessionVaultCoreTests-\(UUID().uuidString)", isDirectory: true)
}
