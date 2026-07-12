import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupAgentTests {

@Test
func initialScanBacksUpCompleteLinesAndUpdatesManifest() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "11111111-1111-1111-1111-111111111111"
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: """
        {"role":"user","content":"Plan the backup work"}
        {"role":"assistant","content":"On it"}

        """
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    #expect(record.sessionId == sessionID)
    #expect(record.sourcePath.hasSuffix("/.codex/sessions/\(sessionID).jsonl"))
    #expect(record.title == "Plan the backup work")
    #expect(record.lineCount == 2)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Plan the backup work"}"#,
        #"{"role":"assistant","content":"On it"}"#
    ])))
    #expect(record.status == "active")
    #expect(record.lastBackedUpAt == fixture.now)

    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Plan the backup work"}
    {"role":"assistant","content":"On it"}

    """)
}

@Test
func secondScanOnlyAppendsNewCompletedLines() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "22222222-2222-2222-2222-222222222222"
    let sourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"First message"}"# + "\n"
    )
    let agent = fixture.makeAgent()
    try agent.performOneShotScan()

    try fixture.append(#"{"role":"assistant","content":"Second message"}"# + "\n", to: sourceURL)
    try agent.performOneShotScan()
    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let backupContents = try String(contentsOf: backupURL, encoding: .utf8)

    #expect(backupContents == """
    {"role":"user","content":"First message"}
    {"role":"assistant","content":"Second message"}

    """)
    #expect(record.lineCount == 2)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"First message"}"#,
        #"{"role":"assistant","content":"Second message"}"#
    ])))
}

@Test
func partialTrailingLineIsBackedUpOnlyAfterItIsCompleted() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "33333333-3333-3333-3333-333333333333"
    let sourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Half written"}"#
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let initialManifest = try fixture.loadManifest()
    let initialRecord = try #require(initialManifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(initialRecord.backupPath)
    #expect(FileManager.default.fileExists(atPath: backupURL.path) == false)
    #expect(initialRecord.lineCount == 0)
    #expect(initialRecord.bytesBackedUp == 0)

    try fixture.append("\n", to: sourceURL)
    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Half written"}

    """)
    #expect(record.title == "Half written")
    #expect(record.lineCount == 1)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Half written"}"#
    ])))
}

@Test
func cursorAdvancesAndPreventsDuplicateBackup() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "44444444-4444-4444-4444-444444444444"
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: """
        {"role":"user","content":"Only once"}

        """
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()
    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let cursor = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))

    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Only once"}

    """)
    #expect(cursor.lastByteOffset == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Only once"}"#
    ])))
    #expect(cursor.lineCount == 1)
    #expect(record.lineCount == 1)
}

@Test
func inaccessibleExistingBackupFailsClosedWithoutAdvancingMetadata() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Steady state"}"# + "\n"
    )
    let agent = fixture.makeAgent()
    try agent.performOneShotScan()
    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let cursorBefore = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: backupURL.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backupURL.path)
    }

    #expect(throws: (any Error).self) {
        try agent.performOneShotScan()
    }

    let updatedManifest = try fixture.loadManifest()
    let updatedRecord = try #require(updatedManifest.sessions[sessionID])
    let cursorAfter = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    #expect(updatedRecord == record)
    #expect(cursorAfter == cursorBefore)
}

@Test
func steadyStateScanDoesNotRewriteCursor() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "12121212-1212-1212-1212-121212121212"
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Stable cursor"}"# + "\n"
    )
    try BackupAgent(paths: fixture.paths, now: { fixture.now }).performOneShotScan()
    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let cursorBeforeNoOpScan = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    let later = fixture.now.addingTimeInterval(10)

    try BackupAgent(paths: fixture.paths, now: { later }).performOneShotScan()

    let cursorAfterNoOpScan = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    #expect(cursorAfterNoOpScan == cursorBeforeNoOpScan)
}

@Test
func archivedSessionsDirectoryIsScannedRecursively() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "55555555-5555-5555-5555-555555555555"
    _ = try fixture.writeArchivedSession(
        named: "\(sessionID).jsonl",
        relativeDirectory: "2026/07",
        contents: #"{"role":"user","content":"Archived question"}"# + "\n"
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)

    #expect(record.title == "Archived question")
    #expect(record.status == "active")
    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Archived question"}

    """)
}

@Test
func activeSessionIsPreferredWhenArchivedCopyAlsoExists() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Use active copy"}"# + "\n"
    )
    try fixture.writeArchivedSession(
        named: "\(sessionID).jsonl",
        relativeDirectory: "2026/07",
        contents: #"{"role":"user","content":"Use active copy"}"# + "\n"
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)

    #expect(record.sourcePath.hasSuffix("/.codex/sessions/\(sessionID).jsonl"))
    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Use active copy"}

    """)
    #expect(record.lineCount == 1)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Use active copy"}"#
    ])))
}

@Test
func movingSessionToArchivedDirectoryDoesNotDuplicateExistingBackup() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "99999999-9999-9999-9999-999999999999"
    let activeSourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Moved once"}"# + "\n"
    )
    let agent = fixture.makeAgent()
    try agent.performOneShotScan()

    let archivedDirectory = fixture.paths.codexRoot
        .appendingPathComponent("archived_sessions", isDirectory: true)
        .appendingPathComponent("2026/07", isDirectory: true)
    try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)
    let archivedSourceURL = archivedDirectory.appendingPathComponent("\(sessionID).jsonl")
    try FileManager.default.moveItem(at: activeSourceURL, to: archivedSourceURL)

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let currentCursor = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))

    #expect(record.sourcePath.hasSuffix("/.codex/archived_sessions/2026/07/\(sessionID).jsonl"))
    #expect(try String(contentsOf: backupURL, encoding: .utf8) == """
    {"role":"user","content":"Moved once"}

    """)
    #expect(record.lineCount == 1)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Moved once"}"#
    ])))
    #expect(currentCursor.lineCount == 1)
    #expect(currentCursor.lastByteOffset == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Moved once"}"#
    ])))
}

@Test
func missingManifestRecoversBackupPathFromExistingCursorOnLaterDay() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "abababab-abab-abab-abab-abababababab"
    let sourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Original day"}"# + "\n"
    )
    let firstAgent = BackupAgent(paths: fixture.paths, now: { fixture.now })
    try firstAgent.performOneShotScan()
    let originalManifest = try fixture.loadManifest()
    let originalRecord = try #require(originalManifest.sessions[sessionID])
    let originalBackupPath = originalRecord.backupPath
    let originalBackupURL = fixture.paths.backupRoot.appendingPathComponent(originalBackupPath)
    let laterDay = fixture.now.addingTimeInterval(86_400)

    try FileManager.default.removeItem(at: fixture.paths.manifestURL)
    try fixture.append(#"{"role":"assistant","content":"Later day"}"# + "\n", to: sourceURL)

    try BackupAgent(paths: fixture.paths, now: { laterDay }).performOneShotScan()

    let recoveredManifest = try fixture.loadManifest()
    let recoveredRecord = try #require(recoveredManifest.sessions[sessionID])
    #expect(recoveredRecord.backupPath == originalBackupPath)
    #expect(try String(contentsOf: originalBackupURL, encoding: .utf8) == """
    {"role":"user","content":"Original day"}
    {"role":"assistant","content":"Later day"}

    """)
}

@Test
func existingBackupFileAheadOfManifestIsReconciledBeforeAppending() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let sourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: """
        {"role":"user","content":"Already copied"}
        {"role":"assistant","content":"New after retry"}

        """
    )
    let backupURL = try fixture.paths.backupFileURL(for: sourceURL)
    let relativeBackupPath = try #require(fixture.paths.relativeBackupPath(for: backupURL))
    try fixture.writeBackupFile(
        at: backupURL,
        contents: #"{"role":"user","content":"Already copied"}"# + "\n"
    )
    try BackupManifestStore(manifestURL: fixture.paths.manifestURL).save(BackupManifest(
        codexRoot: fixture.paths.codexRoot.path,
        backupRoot: fixture.paths.backupRoot.path,
        createdAt: fixture.now,
        updatedAt: fixture.now,
        sessions: [
            sessionID: BackupSessionRecord(
                sessionId: sessionID,
                sourcePath: sourceURL.path,
                backupPath: relativeBackupPath,
                title: nil,
                firstSeenAt: fixture.now,
                lastBackedUpAt: nil,
                lineCount: 0,
                bytesBackedUp: 0,
                status: "active"
            )
        ]
    ))
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    try cursorStore.upsert(BackupCursor(
        sessionId: sessionID,
        sourcePath: sourceURL.path,
        backupPath: relativeBackupPath,
        lastByteOffset: 0,
        lastSourceSize: 0,
        lastSourceModifiedAt: 0,
        lineCount: 0,
        pendingPartialLine: Data(),
        status: "active",
        lastError: nil,
        updatedAt: fixture.now.timeIntervalSince1970
    ))
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let currentCursor = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    let expectedContents = """
    {"role":"user","content":"Already copied"}
    {"role":"assistant","content":"New after retry"}

    """

    #expect(try String(contentsOf: backupURL, encoding: .utf8) == expectedContents)
    #expect(record.title == "Already copied")
    #expect(record.lineCount == 2)
    #expect(record.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Already copied"}"#,
        #"{"role":"assistant","content":"New after retry"}"#
    ])))
    #expect(record.lastBackedUpAt == fixture.now)
    #expect(currentCursor.lineCount == 2)
    #expect(currentCursor.lastByteOffset == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Already copied"}"#,
        #"{"role":"assistant","content":"New after retry"}"#
    ])))
}

@Test
func statusJSONIsWrittenWithAggregateCountsAndRunningStatus() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    try fixture.writeSession(
        named: "66666666-6666-6666-6666-666666666666.jsonl",
        contents: #"{"role":"user","content":"Count me"}"# + "\n"
    )
    try fixture.writeSession(
        named: "77777777-7777-7777-7777-777777777777.jsonl",
        contents: """
        {"role":"user","content":"Count me too"}
        {"role":"assistant","content":"Two lines"}

        """
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let status = try fixture.loadStatus()
    #expect(status.enabled)
    #expect(status.status == .running)
    #expect(status.mode == .polling)
    #expect(status.codexRoot == fixture.paths.codexRoot.path)
    #expect(status.backupRoot == fixture.paths.backupRoot.path)
    #expect(status.lastHeartbeatAt == fixture.now)
    #expect(status.lastBackupAt == fixture.now)
    #expect(status.sessionCount == 2)
    #expect(status.lineCount == 3)
    #expect(status.bytesBackedUp == Int64(fixture.lineBytes([
        #"{"role":"user","content":"Count me"}"#,
        #"{"role":"user","content":"Count me too"}"#,
        #"{"role":"assistant","content":"Two lines"}"#
    ])))
    #expect(status.autoStartEnabled == false)
    #expect(status.lastError == nil)
}

@Test
func oversizedLineWithinLimitBacksUpAndDoesNotBlockFollowingLines() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "99999999-9999-9999-9999-999999999999"
    let longText = String(repeating: "x", count: 1_048_576 + 10)
    let longLine = #"{"role":"user","content":""# + longText + #""}"#
    let nextLine = #"{"role":"assistant","content":"after"}"#
    try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: "\(longLine)\n\(nextLine)\n"
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let cursor = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))

    #expect(try String(contentsOf: backupURL, encoding: .utf8) == "\(longLine)\n\(nextLine)\n")
    #expect(record.lineCount == 2)
    #expect(cursor.lastByteOffset == Int64(fixture.lineBytes([longLine, nextLine])))
    #expect(cursor.lastError == nil)
    #expect(try fixture.loadStatus().lastError == nil)
}

@Test
func oversizedLineBeyondLimitSetsErrorStatusAndContinuesOtherSessions() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let blockedSessionID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    let healthySessionID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
    let blockedLine = String(repeating: "x", count: 33_554_433)
    try fixture.writeSession(named: "\(blockedSessionID).jsonl", contents: blockedLine)
    try fixture.writeSession(
        named: "\(healthySessionID).jsonl",
        contents: #"{"role":"user","content":"healthy"}"# + "\n"
    )
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let manifest = try fixture.loadManifest()
    let blockedRecord = try #require(manifest.sessions[blockedSessionID])
    let healthyRecord = try #require(manifest.sessions[healthySessionID])
    let healthyBackupURL = fixture.paths.backupRoot.appendingPathComponent(healthyRecord.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let blockedCursor = try #require(try cursorStore.cursor(sourcePath: blockedRecord.sourcePath))
    let status = try fixture.loadStatus()

    #expect(blockedRecord.lineCount == 0)
    #expect(blockedRecord.bytesBackedUp == 0)
    #expect(blockedCursor.lastByteOffset == 0)
    #expect(blockedCursor.lastError?.contains("exceeds maximum JSONL line size") == true)
    #expect(try String(contentsOf: healthyBackupURL, encoding: .utf8) == #"{"role":"user","content":"healthy"}"# + "\n")
    #expect(status.status == .error)
    #expect(status.lastError?.contains("exceeds maximum JSONL line size") == true)
}

@Test
func corruptedManifestBackupPathOutsideBackupRootIsRepairedWithoutWritingOutsideRoot() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "88888888-8888-8888-8888-888888888888"
    let sourceURL = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: #"{"role":"user","content":"Unsafe path"}"# + "\n"
    )
    let store = BackupManifestStore(manifestURL: fixture.paths.manifestURL)
    let manifest = BackupManifest(
        codexRoot: fixture.paths.codexRoot.path,
        backupRoot: fixture.paths.backupRoot.path,
        createdAt: fixture.now,
        updatedAt: fixture.now,
        sessions: [
            sessionID: BackupSessionRecord(
                sessionId: sessionID,
                sourcePath: sourceURL.path,
                backupPath: "../outside.jsonl",
                title: nil,
                firstSeenAt: fixture.now,
                lastBackedUpAt: nil,
                lineCount: 0,
                bytesBackedUp: 0,
                status: "active"
            )
        ]
    )
    try store.save(manifest)
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let repaired = try #require(fixture.loadManifest().sessions[sessionID])
    #expect(repaired.backupPath == "sessions/\(sessionID).jsonl")
    #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("outside.jsonl").path) == false)
}

}

private struct BackupAgentFixture {
    let root: URL
    let paths: BackupPaths
    let now: Date

    init(now: Date = Date(timeIntervalSince1970: 1_783_123_200)) throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSessionVaultCoreTests-\(UUID().uuidString)", isDirectory: true)
        self.paths = BackupPaths(
            codexRoot: root.appendingPathComponent(".codex", isDirectory: true),
            backupRoot: root.appendingPathComponent("backup", isDirectory: true),
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )
        self.now = now

        try FileManager.default.createDirectory(
            at: paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: paths.backupRoot, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeAgent() -> BackupAgent {
        BackupAgent(paths: paths, now: { now })
    }

    @discardableResult
    func writeSession(named name: String, contents: String) throws -> URL {
        try writeCodexSession(
            named: name,
            relativeRoot: "sessions",
            relativeDirectory: nil,
            contents: contents
        )
    }

    @discardableResult
    func writeArchivedSession(
        named name: String,
        relativeDirectory: String,
        contents: String
    ) throws -> URL {
        try writeCodexSession(
            named: name,
            relativeRoot: "archived_sessions",
            relativeDirectory: relativeDirectory,
            contents: contents
        )
    }

    func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }

    func writeBackupFile(at url: URL, contents: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func loadManifest() throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: Data(contentsOf: paths.manifestURL))
    }

    func loadStatus() throws -> BackupStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupStatus.self, from: Data(contentsOf: paths.statusURL))
    }

    func lineBytes(_ lines: [String]) -> Int {
        lines.reduce(0) { total, line in
            total + Data(line.utf8).count + 1
        }
    }

    private func writeCodexSession(
        named name: String,
        relativeRoot: String,
        relativeDirectory: String?,
        contents: String
    ) throws -> URL {
        var directory = paths.codexRoot.appendingPathComponent(relativeRoot, isDirectory: true)
        if let relativeDirectory {
            directory = directory.appendingPathComponent(relativeDirectory, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: fileURL)
        return fileURL
    }
}
