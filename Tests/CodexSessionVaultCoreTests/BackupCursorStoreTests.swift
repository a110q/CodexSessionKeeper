import Foundation
import Testing
@testable import CodexSessionVaultCore

@Test
func cursorStoreUpsertsAndLoadsCursor() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(
        databaseURL: tempDirectory.appendingPathComponent("nested/cursors.sqlite")
    )
    try store.open()
    let cursor = makeCursor(sourcePath: "/Users/alice/.codex/sessions/session.jsonl")

    try store.upsert(cursor)
    let loaded = try store.cursor(sourcePath: cursor.sourcePath)

    #expect(loaded == cursor)
}

@Test
func cursorStoreUpdatesExistingCursorForSameSourcePath() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let sourcePath = "/Users/alice/.codex/sessions/session.jsonl"
    let original = makeCursor(sourcePath: sourcePath)
    let updated = BackupCursor(
        sessionId: "session-updated",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/session-updated.jsonl",
        lastByteOffset: 64,
        lastSourceSize: 80,
        lastSourceModifiedAt: 1_800_000_000,
        lineCount: 3,
        pendingPartialLine: Data("updated partial".utf8),
        status: "error",
        lastError: "failed after retry",
        updatedAt: 1_800_000_001
    )

    try store.upsert(original)
    try store.upsert(updated)
    let loaded = try store.cursor(sourcePath: sourcePath)

    #expect(loaded == updated)
}

@Test
func cursorStoreReturnsNilForMissingSourcePath() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()

    let loaded = try store.cursor(sourcePath: "/missing/session.jsonl")

    #expect(loaded == nil)
}

@Test
func cursorStorePreservesPendingPartialLineAndLastError() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let cursor = BackupCursor(
        sessionId: "session-binary",
        sourcePath: "/Users/alice/.codex/sessions/binary.jsonl",
        backupPath: "sessions/2026/07/04/binary.jsonl",
        lastByteOffset: 10,
        lastSourceSize: 14,
        lastSourceModifiedAt: 1_700_000_100,
        lineCount: 1,
        pendingPartialLine: Data([0, 1, 2, 255]),
        status: "error",
        lastError: "line could not be decoded",
        updatedAt: 1_700_000_101
    )

    try store.upsert(cursor)
    let loaded = try #require(try store.cursor(sourcePath: cursor.sourcePath))

    #expect(loaded.pendingPartialLine == Data([0, 1, 2, 255]))
    #expect(loaded.lastError == "line could not be decoded")
}

@Test
func cursorStoreHandlesQuotesPipesAndNewlinesWithoutCorruptingParsing() throws {
    let tempDirectory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: tempDirectory) }
    let store = BackupCursorStore(databaseURL: tempDirectory.appendingPathComponent("cursors.sqlite"))
    try store.open()
    let sourcePath = "/Users/alice/.codex/sessions/quote'pipe|newline\nsession.jsonl"
    let cursor = BackupCursor(
        sessionId: "session-'|",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/quote'pipe|newline\nsession.jsonl",
        lastByteOffset: 123,
        lastSourceSize: 456,
        lastSourceModifiedAt: 1_900_000_000,
        lineCount: 7,
        pendingPartialLine: Data("{\"partial\":\"line\"}".utf8),
        status: "error|quoted",
        lastError: "failed at 'quote' | pipe\nsecond line",
        updatedAt: 1_900_000_001
    )

    try store.upsert(cursor)
    let loaded = try store.cursor(sourcePath: sourcePath)

    #expect(loaded == cursor)
}

private func makeCursor(sourcePath: String) -> BackupCursor {
    BackupCursor(
        sessionId: "session-123",
        sourcePath: sourcePath,
        backupPath: "sessions/2026/07/04/session-123.jsonl",
        lastByteOffset: 42,
        lastSourceSize: 50,
        lastSourceModifiedAt: 1_700_000_000,
        lineCount: 2,
        pendingPartialLine: Data("partial".utf8),
        status: "backedUp",
        lastError: nil,
        updatedAt: 1_700_000_001
    )
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexSessionVaultCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
