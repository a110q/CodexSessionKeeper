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
    let sourceURL = try fixture.writeSession(
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
    try fixture.append(#"{"role":"assistant","content":"force target access"}"# + "\n", to: sourceURL)

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
func unchangedScanStopsBeforeTargetAccess() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }

    try fixture.makeAgent().performOneShotScan()

    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.fullHashCount == 0)
    #expect(fixture.manifestWriteCount == 0)
    #expect(fixture.cursorReadBatchCount == 1)
    #expect(fixture.cursorWriteBatchCount == 0)
}

@Test
func unchangedFiveHundredSessionScanUsesOneCursorReadAndNoTargetCalls() throws {
    let fixture = try BackupAgentFixture.seededSession(count: 500)
    defer { fixture.cleanup() }

    try fixture.makeAgent().performOneShotScan()

    #expect(fixture.cursorReadBatchCount == 1)
    #expect(fixture.cursorWriteBatchCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.manifestWriteCount == 0)
    #expect(fixture.sqliteRunnerInvocationCount == 2)
}

@Test
func appendReadsAndVerifiesOnlyNewRangeAndClearsFullHash() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "13131313-1313-1313-1313-131313131313"
    let firstLine = #"{"role":"user","content":"first"}"# + "\n"
    let secondLine = #"{"role":"assistant","content":"second"}"# + "\n"
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: firstLine)
    try fixture.makeAgent().performOneShotScan()
    let oldOffset = Int64(Data(firstLine.utf8).count)
    fixture.resetSpies()

    try fixture.append(secondLine, to: source)
    let newOffset = oldOffset + Int64(Data(secondLine.utf8).count)
    try fixture.makeAgent().performOneShotScan()

    #expect(!fixture.sourceBodyReadRanges.isEmpty)
    #expect(fixture.sourceBodyReadRanges.allSatisfy { $0 == oldOffset..<newOffset })
    #expect(fixture.targetStatCount == 1)
    #expect(fixture.fullHashCount == 0)
    #expect(fixture.manifestWriteCount == 1)
    #expect(fixture.cursorReadBatchCount == 1)
    #expect(fixture.cursorWriteBatchCount == 1)
    let record = try #require(fixture.loadManifest().sessions[sessionID])
    #expect(record.contentHash == nil)
    #expect(record.bytesBackedUp == newOffset)
}

@Test
func appendStreamsLargeDeltaWithoutMaterializingTailerLines() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "18181818-1818-1818-1818-181818181818"
    let firstLine = #"{"role":"user","content":"first"}"# + "\n"
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: firstLine)
    let agent = fixture.makeAgent(tailer: SessionTailer(maxReadBytes: 0))
    try agent.performOneShotScan()
    let largeLine = #"{"role":"assistant","content":""#
        + String(repeating: "x", count: 3 * 1_048_576 + 17)
        + #""}"#
        + "\n"

    try fixture.append(largeLine, to: source)
    try agent.performOneShotScan()

    let record = try #require(fixture.loadManifest().sessions[sessionID])
    let target = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    #expect(try Data(contentsOf: target).count == Data((firstLine + largeLine).utf8).count)
    #expect(record.lineCount == 2)
}

@Test
func emptySeedAndEmptyRebuildStoreCanonicalContentHash() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "19191919-1919-1919-1919-191919191919"
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: "")
    let agent = fixture.makeAgent()

    try agent.performOneShotScan()

    let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    #expect(try fixture.loadManifest().sessions[sessionID]?.contentHash == emptyHash)

    try Data("complete\n".utf8).write(to: source)
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now.addingTimeInterval(120)],
        ofItemAtPath: source.path
    )
    try agent.performOneShotScan()
    try Data().write(to: source)
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now.addingTimeInterval(240)],
        ofItemAtPath: source.path
    )

    try agent.performOneShotScan()

    let rebuiltRecord = try #require(fixture.loadManifest().sessions[sessionID])
    let target = fixture.paths.backupRoot.appendingPathComponent(rebuiltRecord.backupPath)
    #expect(rebuiltRecord.contentHash == emptyHash)
    #expect(try Data(contentsOf: target).isEmpty)
}

@Test
func appendTitleFallbackUsesOnlyNewRangeInsteadOfLargeTargetPrefix() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "20202020-2020-2020-2020-202020202020"
    let largeAssistantLine = #"{"role":"assistant","content":""#
        + String(repeating: "x", count: 3 * 1_048_576 + 17)
        + #""}"#
        + "\n"
    let oldTitleLine = #"{"role":"user","content":"old prefix title"}"# + "\n"
    let newTitleLine = #"{"role":"user","content":"new appended title"}"# + "\n"
    let source = try fixture.writeSession(
        named: "\(sessionID).jsonl",
        contents: largeAssistantLine + oldTitleLine
    )
    let agent = fixture.makeAgent()
    try agent.performOneShotScan()
    var manifest = try fixture.loadManifest()
    manifest.sessions[sessionID]?.title = nil
    try fixture.saveManifest(manifest)
    let oldOffset = Int64(Data((largeAssistantLine + oldTitleLine).utf8).count)
    fixture.resetSpies()

    try fixture.append(newTitleLine, to: source)
    try agent.performOneShotScan()

    let newOffset = oldOffset + Int64(Data(newTitleLine.utf8).count)
    let updatedRecord = try #require(fixture.loadManifest().sessions[sessionID])
    #expect(updatedRecord.title == "new appended title")
    #expect(fixture.sourceBodyReadRanges.allSatisfy { $0 == oldOffset..<newOffset })
}

@Test
func sameSizeNewMtimeRewriteStreamsRebuild() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "14141414-1414-1414-1414-141414141414"
    let original = #"{"role":"user","content":"AAAA"}"# + "\n"
    let replacement = #"{"role":"user","content":"BBBB"}"# + "\n"
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: original)
    try fixture.makeAgent().performOneShotScan()
    fixture.resetSpies()
    try Data(replacement.utf8).write(to: source)
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now.addingTimeInterval(120)],
        ofItemAtPath: source.path
    )

    try fixture.makeAgent().performOneShotScan()

    let sourceSize = Int64(Data(replacement.utf8).count)
    #expect(fixture.sourceBodyReadRanges == [0..<sourceSize])
    #expect(fixture.targetStatCount == 1)
    #expect(fixture.fullHashCount == 0)
    let record = try #require(fixture.loadManifest().sessions[sessionID])
    let target = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    #expect(try String(contentsOf: target, encoding: .utf8) == replacement)
    #expect(record.contentHash?.isEmpty == false)
}

@Test
func truncationStreamsRebuild() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "15151515-1515-1515-1515-151515151515"
    let retained = #"{"role":"user","content":"keep"}"# + "\n"
    let removed = #"{"role":"assistant","content":"remove"}"# + "\n"
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: retained + removed)
    try fixture.makeAgent().performOneShotScan()
    fixture.resetSpies()
    try Data(retained.utf8).write(to: source)
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now.addingTimeInterval(120)],
        ofItemAtPath: source.path
    )

    try fixture.makeAgent().performOneShotScan()

    let retainedSize = Int64(Data(retained.utf8).count)
    #expect(fixture.sourceBodyReadRanges == [0..<retainedSize])
    #expect(fixture.targetStatCount == 1)
    let record = try #require(fixture.loadManifest().sessions[sessionID])
    let target = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    #expect(try String(contentsOf: target, encoding: .utf8) == retained)
    #expect(record.bytesBackedUp == retainedSize)
    #expect(record.lineCount == 1)
}

@Test
func missingTargetStreamsRebuild() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "16161616-1616-1616-1616-161616161616"
    let contents = #"{"role":"user","content":"restore target"}"# + "\n"
    _ = try fixture.writeSession(named: "\(sessionID).jsonl", contents: contents)
    try fixture.makeAgent().performOneShotScan()
    let record = try #require(fixture.loadManifest().sessions[sessionID])
    let target = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.setAttributes(
        [.modificationDate: fixture.now.addingTimeInterval(120)],
        ofItemAtPath: fixture.paths.codexRoot
            .appendingPathComponent("sessions/\(sessionID).jsonl").path
    )
    fixture.resetSpies()

    try fixture.makeAgent().performOneShotScan()

    let sourceSize = Int64(Data(contents.utf8).count)
    #expect(fixture.sourceBodyReadRanges == [0..<sourceSize])
    #expect(fixture.targetStatCount == 1)
    #expect(try String(contentsOf: target, encoding: .utf8) == contents)
}

@Test
func partialTrailingLineDoesNotAdvanceCommittedOffset() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let sessionID = "17171717-1717-1717-1717-171717171717"
    let committed = #"{"role":"user","content":"committed"}"# + "\n"
    let partial = #"{"role":"assistant","content":"partial"}"#
    let source = try fixture.writeSession(named: "\(sessionID).jsonl", contents: committed)
    try fixture.makeAgent().performOneShotScan()
    let committedOffset = Int64(Data(committed.utf8).count)
    fixture.resetSpies()

    try fixture.append(partial, to: source)
    try fixture.makeAgent().performOneShotScan()

    let record = try #require(fixture.loadManifest().sessions[sessionID])
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let cursor = try #require(try cursorStore.cursor(sourcePath: source.path))
    #expect(cursor.lastByteOffset == committedOffset)
    #expect(!cursor.pendingPartialLine.isEmpty)
    #expect(record.bytesBackedUp == committedOffset)
    #expect(record.lineCount == 1)

    fixture.resetSpies()
    try fixture.makeAgent().performOneShotScan()
    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.cursorWriteBatchCount == 0)
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
    let initialRecord = try #require(try fixture.loadManifest().sessions[sessionID])
    let initialBackupURL = fixture.paths.backupRoot.appendingPathComponent(initialRecord.backupPath)

    let archivedDirectory = fixture.paths.codexRoot
        .appendingPathComponent("archived_sessions", isDirectory: true)
        .appendingPathComponent("2026/07", isDirectory: true)
    try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)
    let archivedSourceURL = archivedDirectory.appendingPathComponent("\(sessionID).jsonl")
    try FileManager.default.moveItem(at: activeSourceURL, to: archivedSourceURL)
    fixture.resetSpies()

    try agent.performOneShotScan()
    #expect(fixture.cursorWriteBatchCount == 1)

    let manifest = try fixture.loadManifest()
    let record = try #require(manifest.sessions[sessionID])
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let cursorStore = BackupCursorStore(databaseURL: fixture.paths.cursorDatabaseURL)
    try cursorStore.open()
    let currentCursor = try #require(try cursorStore.cursor(sourcePath: record.sourcePath))
    let cursorsAfterMove = try cursorStore.loadAll()
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: fixture.now.addingTimeInterval(-86_401),
        lastResult: "previous",
        repairedCount: 0
    ))
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let auditOutcome = try agent.performIntegrityAuditIfDue(deviceID: deviceID)

    #expect(record.sourcePath.hasSuffix("/.codex/archived_sessions/2026/07/\(sessionID).jsonl"))
    #expect(record.backupPath == initialRecord.backupPath)
    #expect(backupURL == initialBackupURL)
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
    #expect(cursorsAfterMove.count == 1)
    #expect(cursorsAfterMove[activeSourceURL.path] == nil)
    #expect(auditOutcome == .completed(checked: 1, repaired: 0))
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
func persistedStatusIsPublishedThroughSendableCallback() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    try fixture.writeSession(
        named: "67676767-6767-6767-6767-676767676767.jsonl",
        contents: #"{"role":"user","content":"Publish me"}"# + "\n"
    )
    let statuses = LockedStatusRecorder()
    let agent = fixture.makeAgent(statusHandler: { status in
        statuses.append(status)
    })

    try agent.performOneShotScan()

    #expect(statuses.values == [try fixture.loadStatus()])
}

@Test
func concurrentTriggersAreSerializedAndOneDrainIsCappedAtTwoScans() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let barrier = ControlledScanBarrier()
    let published = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        targetValidator: BackupTargetValidator { barrier.enterAndWait() },
        statusHandler: { _ in published.signal() }
    )
    defer {
        barrier.releaseAll()
        agent.stop()
    }

    agent.requestImmediateScan(.timer)
    #expect(barrier.waitForEntry() == .success)
    agent.requestImmediateScan(.wake)
    agent.requestImmediateScan(.reconnect)
    agent.requestImmediateScan(.timer)
    barrier.releaseOne()
    #expect(barrier.waitForEntry() == .success)
    agent.requestImmediateScan(.wake)
    agent.requestImmediateScan(.reconnect)
    agent.requestImmediateScan(.timer)
    barrier.releaseOne()
    #expect(published.wait(timeout: .now() + 5) == .success)
    #expect(published.wait(timeout: .now() + 5) == .success)
    #expect(barrier.waitForEntry(timeout: 0.25) == .timedOut)

    #expect(barrier.scanCount == 2)
    #expect(barrier.maximumConcurrentScans == 1)
}

@Test
func stoppedPartialSeedRetainsPendingStateAndReplacementCatchesUp() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    try fixture.writeSession(
        named: "01010101-0101-0101-0101-010101010101.jsonl",
        contents: #"{"role":"user","content":"first"}"# + "\n"
    )
    let secondSource = try fixture.writeSession(
        named: "02020202-0202-0202-0202-020202020202.jsonl",
        contents: #"{"role":"user","content":"second"}"# + "\n"
    )
    let stepBarrier = ControlledSessionStepBarrier()
    let published = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        sessionStepBarrier: stepBarrier,
        statusHandler: { _ in published.signal() }
    )
    defer {
        stepBarrier.release()
        agent.stop()
    }

    agent.requestImmediateScan(.startup)
    #expect(stepBarrier.waitForFirstSession() == .success)
    let started = ContinuousClock.now
    #expect(agent.stopAndAwaitQuiescence(timeout: 0.05) == false)
    #expect(started.duration(to: .now) < .milliseconds(250))
    stepBarrier.release()
    #expect(agent.stopAndAwaitQuiescence(timeout: 5))
    #expect(published.wait(timeout: .now() + 5) == .success)

    #expect(stepBarrier.visitedSessionCount == 1)
    let partialManifest = try fixture.loadManifest()
    #expect(partialManifest.sessions["01010101-0101-0101-0101-010101010101"] != nil)
    #expect(partialManifest.sessions["02020202-0202-0202-0202-020202020202"] == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.paths.auditStateURL.path) == false)
    #expect(try fixture.loadStatus().status == .waiting)
    let pendingData = try Data(contentsOf: fixture.paths.pendingSourcesURL)
    let pendingRecords = try #require(
        JSONSerialization.jsonObject(with: pendingData) as? [[String: Any]]
    )
    #expect(pendingRecords.count == 1)
    #expect(pendingRecords.first?["sourcePath"] as? String == secondSource.path)

    let replacement = fixture.makeAgent()
    try replacement.performOneShotScan()

    let completedManifest = try fixture.loadManifest()
    #expect(completedManifest.sessions["01010101-0101-0101-0101-010101010101"] != nil)
    #expect(completedManifest.sessions["02020202-0202-0202-0202-020202020202"] != nil)
    #expect(try fixture.loadAuditState().lastResult == "seeded")
    #expect(try fixture.loadStatus().status == .running)
    let clearedPending = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: fixture.paths.pendingSourcesURL)) as? [[String: Any]]
    )
    #expect(clearedPending.isEmpty)
}

@Test
func stopReturnsPromptlyAndDropsQueuedAndFutureWork() throws {
    let fixture = try BackupAgentFixture()
    defer { fixture.cleanup() }
    let barrier = ControlledScanBarrier()
    let published = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        targetValidator: BackupTargetValidator { barrier.enterAndWait() },
        statusHandler: { _ in published.signal() }
    )
    defer { barrier.releaseAll() }

    agent.startPolling(intervalSeconds: 1)
    agent.requestImmediateScan(.startup)
    #expect(barrier.waitForEntry() == .success)
    agent.requestImmediateScan(.wake)
    let started = ContinuousClock.now
    agent.stop()
    let stopDuration = started.duration(to: .now)
    agent.requestImmediateScan(.reconnect)
    barrier.releaseOne()
    #expect(published.wait(timeout: .now() + 5) == .success)
    Thread.sleep(forTimeInterval: 1.2)

    #expect(stopDuration < .milliseconds(250))
    #expect(barrier.scanCount == 1)
}

@Test
func overdueAuditRunsAfterIncrementalCatchupOnDeviceUUIDSchedule() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    #expect(BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID) == 0)
    let statuses = LockedStatusRecorder()
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        statusHandler: { statuses.append($0) }
    )
    defer { agent.stop() }

    agent.requestImmediateScan(.startup)

    #expect(statuses.waitForStatus(timeout: 5) { status in
        status.lastAuditAt == fixture.now && status.lastAuditResult == "completed"
    })
    #expect(try fixture.loadAuditState().lastCompletedAt == fixture.now)
}

@Test
func stopCancelsScheduledAuditBeforeItStarts() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
    #expect(BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID) == 1)
    let statuses = LockedStatusRecorder()
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        statusHandler: { statuses.append($0) }
    )

    agent.requestImmediateScan(.startup)
    #expect(statuses.waitForStatus(timeout: 5) { $0.lastAuditAt == previousAudit })
    agent.stop()
    Thread.sleep(forTimeInterval: 1.2)

    #expect(try fixture.loadAuditState().lastCompletedAt == previousAudit)
    #expect(try fixture.loadAuditState().lastResult == "previous")
}

@Test
func stoppedAgentCannotEraseAuditInterruptionWhenAuditStartsLater() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let agent = fixture.makeAgent(deviceID: deviceID)

    agent.stop()
    let outcome = try agent.performIntegrityAuditIfDue(deviceID: deviceID)

    #expect(outcome == .interrupted)
    #expect(try fixture.loadAuditState().lastCompletedAt == previousAudit)
}

@Test
func periodicScanWhileAuditTimerWaitsDoesNotStarveScheduledAudit() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let outcomes = LockedAuditOutcomeRecorder()
    let scansFinished = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditDidFinish: { outcomes.append($0) },
        statusHandler: { _ in scansFinished.signal() }
    )
    defer { agent.stop() }

    agent.requestImmediateScan(.startup)
    #expect(scansFinished.wait(timeout: .now() + 5) == .success)
    #expect(timers.waitForScheduledCount(1))
    agent.requestImmediateScan(.timer)
    #expect(scansFinished.wait(timeout: .now() + 5) == .success)
    timers.fire(at: 0)

    #expect(outcomes.waitForCount(1))
    #expect(outcomes.values.first == .completed(checked: 1, repaired: 0))
}

@Test
func explicitActivationAfterScheduledAuditCallbackBeginsInterruptsAudit() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let auditGate = ControlledAuditStartBarrier()
    let outcomes = LockedAuditOutcomeRecorder()
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditWillStart: { auditGate.enterAndWaitOnce() },
        auditDidFinish: { outcomes.append($0) }
    )
    defer {
        auditGate.release()
        agent.stop()
    }

    agent.requestImmediateScan(.startup)
    #expect(timers.waitForScheduledCount(1))
    timers.fire(at: 0)
    #expect(auditGate.waitForEntry() == .success)
    agent.requestImmediateScan(.activation)
    auditGate.release()

    #expect(outcomes.waitForCount(1))
    #expect(outcomes.values.first == .interrupted)
}

@Test
func twoNoChangeTimerTicksDoNotInterruptRunningAuditOrQueueBackupWork() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let auditChunk = ControlledAuditStartBarrier()
    let outcomes = LockedAuditOutcomeRecorder()
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditDidFinish: { outcomes.append($0) },
        integrityAuditorFactory: { paths in
            BackupIntegrityAuditor(
                paths: paths,
                chunkSize: 8,
                instrumentation: IntegrityAuditInstrumentation(didReadChunk: { _, _, _ in
                    auditChunk.enterAndWaitOnce()
                })
            )
        }
    )
    defer {
        auditChunk.release()
        agent.stop()
    }

    agent.requestImmediateScan(.startup)
    #expect(timers.waitForScheduledCount(1))
    timers.fire(at: 0)
    #expect(auditChunk.waitForEntry() == .success)
    fixture.resetSpies()

    agent.requestImmediateScan(.timer)
    agent.requestImmediateScan(.timer)

    #expect(fixture.cursorReadBatchCount == 2)
    #expect(fixture.sqliteRunnerInvocationCount == 2)
    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.cursorWriteBatchCount == 0)
    auditChunk.release()
    #expect(outcomes.waitForCount(1))
    #expect(outcomes.values.first == .completed(checked: 1, repaired: 0))
}

@Test
func timerTickWithCompleteAppendInterruptsAuditAndBacksUpAppend() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let record = try #require(fixture.loadManifest().sessions.values.first)
    let sourceURL = URL(fileURLWithPath: record.sourcePath)
    let backupURL = fixture.paths.backupRoot.appendingPathComponent(record.backupPath)
    let appended = #"{"role":"assistant","content":"new during audit"}"# + "\n"
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let auditChunk = ControlledAuditStartBarrier()
    let sessionStep = ControlledSessionStepBarrier()
    let outcomes = LockedAuditOutcomeRecorder()
    let scansFinished = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        sessionStepBarrier: sessionStep,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditDidFinish: { outcomes.append($0) },
        statusHandler: { _ in scansFinished.signal() },
        integrityAuditorFactory: { paths in
            BackupIntegrityAuditor(
                paths: paths,
                chunkSize: 8,
                instrumentation: IntegrityAuditInstrumentation(didReadChunk: { _, _, _ in
                    auditChunk.enterAndWaitOnce()
                })
            )
        }
    )
    defer {
        auditChunk.release()
        sessionStep.release()
        agent.stop()
    }

    agent.requestImmediateScan(.startup)
    #expect(scansFinished.wait(timeout: .now() + 5) == .success)
    #expect(timers.waitForScheduledCount(1))
    timers.fire(at: 0)
    #expect(auditChunk.waitForEntry() == .success)
    fixture.resetSpies()
    try fixture.append(appended, to: sourceURL)

    agent.requestImmediateScan(.timer)

    #expect(fixture.cursorReadBatchCount == 1)
    #expect(fixture.sqliteRunnerInvocationCount == 1)
    #expect(fixture.sourceBodyReadCount == 0)
    #expect(fixture.targetStatCount == 0)
    #expect(fixture.cursorWriteBatchCount == 0)
    auditChunk.release()
    #expect(outcomes.waitForCount(1))
    #expect(outcomes.values.first == .interrupted)
    #expect(sessionStep.waitForFirstSession() == .success)
    while scansFinished.wait(timeout: .now()) == .success {}
    sessionStep.release()
    #expect(scansFinished.wait(timeout: .now() + 5) == .success)
    #expect(try String(contentsOf: backupURL, encoding: .utf8).hasSuffix(appended))
    #expect(fixture.sourceBodyReadCount > 0)
    #expect(fixture.targetStatCount == 1)
    #expect(fixture.cursorWriteBatchCount == 1)
}

@Test
func staleAuditTimerCannotClearOrFireInPlaceOfReplacementTimer() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    initialStatus.lastAuditResult = "previous"
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let auditStarts = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditWillStart: { auditStarts.signal() }
    )
    defer { agent.stop() }

    agent.requestImmediateScan(.startup)
    #expect(timers.waitForScheduledCount(1))
    agent.requestImmediateScan(.wake)
    #expect(timers.waitForScheduledCount(2))

    timers.fire(at: 0)
    #expect(auditStarts.wait(timeout: .now() + 0.25) == .timedOut)
    timers.fire(at: 1)
    #expect(auditStarts.wait(timeout: .now() + 5) == .success)
}

@Test
func stoppedAgentRejectsEvenManuallyFiredCurrentAuditTimer() throws {
    let fixture = try BackupAgentFixture.seededSession()
    defer { fixture.cleanup() }
    let previousAudit = fixture.now.addingTimeInterval(-86_401)
    try fixture.writeAuditState(IntegrityAuditState(
        lastCompletedAt: previousAudit,
        lastResult: "previous",
        repairedCount: 0
    ))
    var initialStatus = try fixture.loadStatus()
    initialStatus.lastAuditAt = previousAudit
    let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000009a"))
    let timers = ControlledAuditTimerScheduler()
    let auditStarts = DispatchSemaphore(value: 0)
    let agent = fixture.makeAgent(
        deviceID: deviceID,
        initialStatus: initialStatus,
        auditDelayProvider: { _, _, _ in 0 },
        auditTimerScheduler: { delay, action in timers.schedule(delay: delay, action: action) },
        auditWillStart: { auditStarts.signal() }
    )

    agent.requestImmediateScan(.startup)
    #expect(timers.waitForScheduledCount(1))
    agent.stop()
    timers.fire(at: 0)

    #expect(auditStarts.wait(timeout: .now() + 0.25) == .timedOut)
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

private final class BackupAgentFixture {
    let root: URL
    let paths: BackupPaths
    let now: Date
    private(set) var sourceBodyReadRanges: [Range<Int64>] = []
    private(set) var targetStatCount = 0
    private(set) var fullHashCount = 0
    private(set) var manifestWriteCount = 0
    private(set) var cursorReadBatchCount = 0
    private(set) var cursorWriteBatchCount = 0
    private(set) var sqliteRunnerInvocationCount = 0

    var sourceBodyReadCount: Int { sourceBodyReadRanges.count }

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

    static func seededSession(count: Int = 1) throws -> BackupAgentFixture {
        let fixture = try BackupAgentFixture()
        for index in 0..<count {
            let sessionID = String(format: "00000000-0000-0000-0000-%012d", index)
            try fixture.writeSession(
                named: "\(sessionID).jsonl",
                contents: #"{"role":"user","content":"seeded"}"# + "\n"
            )
        }
        try fixture.makeAgent().performOneShotScan()
        fixture.resetSpies()
        return fixture
    }

    func resetSpies() {
        sourceBodyReadRanges = []
        targetStatCount = 0
        fullHashCount = 0
        manifestWriteCount = 0
        cursorReadBatchCount = 0
        cursorWriteBatchCount = 0
        sqliteRunnerInvocationCount = 0
    }

    func makeAgent(
        tailer: SessionTailer = SessionTailer(),
        targetValidator: BackupTargetValidator? = nil,
        deviceID: UUID? = nil,
        initialStatus: BackupStatus? = nil,
        sessionStepBarrier: ControlledSessionStepBarrier? = nil,
        auditDelayProvider: (@Sendable (Date, Date?, UUID) -> TimeInterval)? = nil,
        auditTimerScheduler: (@Sendable (
            TimeInterval,
            @escaping @Sendable () -> Void
        ) -> Task<Void, Never>)? = nil,
        auditWillStart: @escaping @Sendable () -> Void = {},
        auditDidFinish: @escaping @Sendable (IntegrityAuditOutcome) -> Void = { _ in },
        statusHandler: (@Sendable (BackupStatus) -> Void)? = nil,
        integrityAuditorFactory: ((BackupPaths) -> BackupIntegrityAuditor)? = nil
    ) -> BackupAgent {
        BackupAgent(
            paths: paths,
            now: { self.now },
            tailer: tailer,
            targetValidator: targetValidator,
            deviceID: deviceID,
            initialStatus: initialStatus,
            statusHandler: statusHandler,
            auditDelayProvider: auditDelayProvider,
            auditTimerScheduler: auditTimerScheduler,
            sessionBackupStreamer: SessionBackupStreamer(chunkSize: 1_048_576),
            cursorStoreFactory: { [weak self] databaseURL in
                BackupCursorStore(databaseURL: databaseURL, sqliteRunner: { arguments, input in
                    guard let self else { throw BackupAgentFixtureError.fixtureReleased }
                    self.sqliteRunnerInvocationCount += 1
                    if input.contains("FROM backup_cursors") {
                        self.cursorReadBatchCount += 1
                    }
                    if input.contains("BEGIN IMMEDIATE") {
                        self.cursorWriteBatchCount += 1
                    }
                    return try runSQLiteForBackupAgentTests(arguments: arguments, input: input)
                })
            },
            manifestStoreFactory: { [weak self] manifestURL in
                guard let self else {
                    return BackupManifestStore(manifestURL: manifestURL, createParentDirectories: false)
                }
                return BackupManifestStore(
                    manifestURL: manifestURL,
                    createParentDirectories: false,
                    writer: DurableAtomicWriter(synchronize: { handle in
                        self.manifestWriteCount += 1
                        try handle.synchronize()
                    })
                )
            },
            instrumentation: BackupAgentInstrumentation(
                sourceBodyRead: { [weak self] _, offset, length in
                    guard let self else { return }
                    self.sourceBodyReadRanges.append(offset..<(offset + length))
                    sessionStepBarrier?.visitAndBlockFirstSession()
                },
                targetStat: { [weak self] _ in
                    self?.targetStatCount += 1
                },
                fullHash: { [weak self] _, _ in
                    self?.fullHashCount += 1
                },
                auditWillStart: auditWillStart,
                auditDidFinish: auditDidFinish
            ),
            integrityAuditorFactory: integrityAuditorFactory ?? { BackupIntegrityAuditor(paths: $0) }
        )
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

    func saveManifest(_ manifest: BackupManifest) throws {
        try BackupManifestStore(manifestURL: paths.manifestURL).save(manifest)
    }

    func loadStatus() throws -> BackupStatus {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupStatus.self, from: Data(contentsOf: paths.statusURL))
    }

    func writeAuditState(_ state: IntegrityAuditState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(
            at: paths.auditStateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(state).write(to: paths.auditStateURL, options: .atomic)
    }

    func loadAuditState() throws -> IntegrityAuditState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IntegrityAuditState.self, from: Data(contentsOf: paths.auditStateURL))
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

private enum BackupAgentFixtureError: Error {
    case fixtureReleased
    case sqliteFailed(String)
}

private final class LockedStatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BackupStatus] = []

    var values: [BackupStatus] {
        lock.withLock { storage }
    }

    func append(_ status: BackupStatus) {
        lock.withLock { storage.append(status) }
    }

    func waitForStatus(
        timeout: TimeInterval,
        matching predicate: (BackupStatus) -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ storage.contains(where: predicate) }) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return lock.withLock { storage.contains(where: predicate) }
    }
}

private final class ControlledScanBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var activeScans = 0
    private var storedScanCount = 0
    private var storedMaximumConcurrentScans = 0

    var scanCount: Int {
        lock.withLock { storedScanCount }
    }

    var maximumConcurrentScans: Int {
        lock.withLock { storedMaximumConcurrentScans }
    }

    func enterAndWait() {
        lock.withLock {
            activeScans += 1
            storedScanCount += 1
            storedMaximumConcurrentScans = max(storedMaximumConcurrentScans, activeScans)
        }
        entered.signal()
        continuation.wait()
        lock.withLock { activeScans -= 1 }
    }

    func waitForEntry(timeout: TimeInterval = 5) -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + timeout)
    }

    func releaseOne() {
        continuation.signal()
    }

    func releaseAll() {
        for _ in 0..<8 { continuation.signal() }
    }
}

private final class ControlledSessionStepBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var visits = 0

    var visitedSessionCount: Int {
        lock.withLock { visits }
    }

    func visitAndBlockFirstSession() {
        let shouldBlock = lock.withLock { () -> Bool in
            visits += 1
            return visits == 1
        }
        guard shouldBlock else { return }
        entered.signal()
        continuation.wait()
    }

    func waitForFirstSession() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }

    func release() {
        continuation.signal()
    }
}

private final class ControlledAuditStartBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)
    private var shouldBlock = true

    func enterAndWaitOnce() {
        let blocks = lock.withLock { () -> Bool in
            guard shouldBlock else { return false }
            shouldBlock = false
            return true
        }
        guard blocks else { return }
        entered.signal()
        continuation.wait()
    }

    func waitForEntry() -> DispatchTimeoutResult {
        entered.wait(timeout: .now() + 5)
    }

    func release() {
        continuation.signal()
    }
}

private final class LockedAuditOutcomeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IntegrityAuditOutcome] = []

    var values: [IntegrityAuditOutcome] {
        lock.withLock { storage }
    }

    func append(_ outcome: IntegrityAuditOutcome) {
        lock.withLock { storage.append(outcome) }
    }

    func waitForCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ storage.count >= count }) { return true }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return lock.withLock { storage.count >= count }
    }
}

private final class ControlledAuditTimerScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduled = DispatchSemaphore(value: 0)
    private var actions: [@Sendable () -> Void] = []

    func schedule(
        delay: TimeInterval,
        action: @escaping @Sendable () -> Void
    ) -> Task<Void, Never> {
        lock.withLock { actions.append(action) }
        scheduled.signal()
        return Task.detached {}
    }

    func waitForScheduledCount(_ count: Int, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ actions.count >= count }) { return true }
            _ = scheduled.wait(timeout: .now() + 0.01)
        }
        return lock.withLock { actions.count >= count }
    }

    func fire(at index: Int) {
        let action = lock.withLock { actions[index] }
        action()
    }
}

private func runSQLiteForBackupAgentTests(arguments: [String], input: String) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
    process.arguments = arguments
    let inputPipe = Pipe()
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardInput = inputPipe
    process.standardOutput = outputPipe
    process.standardError = errorPipe

    try process.run()
    try inputPipe.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try inputPipe.fileHandleForWriting.close()
    let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
    let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    try? outputPipe.fileHandleForReading.close()
    try? errorPipe.fileHandleForReading.close()
    guard process.terminationStatus == 0 else {
        throw BackupAgentFixtureError.sqliteFailed(
            String(data: error, encoding: .utf8) ?? "sqlite failed"
        )
    }
    return String(data: output, encoding: .utf8) ?? ""
}
