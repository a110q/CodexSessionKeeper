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
func corruptedManifestBackupPathOutsideBackupRootThrowsClearError() throws {
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

    do {
        try agent.performOneShotScan()
        #expect(Bool(false), "Expected invalid backup path error")
    } catch {
        #expect(error.localizedDescription.contains("outside backup root"))
        #expect(error.localizedDescription.contains("../outside.jsonl"))
    }
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
            backupRoot: root.appendingPathComponent("backup", isDirectory: true)
        )
        self.now = now

        try FileManager.default.createDirectory(
            at: paths.codexRoot.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
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
