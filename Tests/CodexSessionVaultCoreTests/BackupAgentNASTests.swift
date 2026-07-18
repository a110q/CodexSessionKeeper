import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupAgentNASTests {
    @Test
    func successfulInitialSeedInitializesAuditStateAndPreventsImmediateAudit() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "initial-seed.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()

        try agent.performOneShotScan()

        let state = try fixture.loadAuditState()
        #expect(state.lastCompletedAt == fixture.now)
        #expect(state.lastResult == "seeded")
        #expect(try agent.performIntegrityAuditIfDue(deviceID: fixture.deviceID) == .notDue)
    }

    @Test
    func blockedInitialSeedDoesNotInitializeAuditCompletion() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        _ = try fixture.writeActiveSession(name: "blocked-seed.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent(
            sessionBackupStreamer: SessionBackupStreamer(maxLineBytes: 0)
        )

        try agent.performOneShotScan()

        #expect(FileManager.default.fileExists(atPath: fixture.paths.auditStateURL.path) == false)
        #expect(try fixture.loadLocalStatus().status == .error)
    }

    @Test
    func integrityAuditRunsOnlyAfterIncrementalCatchup() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let source = try fixture.writeActiveSession(name: "audit-catchup.jsonl", contents: fixture.line("one"))
        let agent = fixture.makeAgent()
        try agent.performOneShotScan()
        try fixture.writeAuditState(IntegrityAuditState(
            lastCompletedAt: fixture.now.addingTimeInterval(-86_401),
            lastResult: "previous",
            repairedCount: 0
        ))
        try fixture.append(fixture.line("two"), to: source)

        let outcome = try agent.performIntegrityAuditIfDue(deviceID: fixture.deviceID)

        #expect(outcome == .completed(checked: 1, repaired: 0))
        let target = try fixture.paths.backupFileURL(for: source)
        #expect(try String(contentsOf: target, encoding: .utf8) == fixture.line("one") + fixture.line("two"))
        #expect(try fixture.loadManifest().sessions["audit-catchup"]?.contentHash?.isEmpty == false)
    }

    @Test
    func queuedIncrementalScanInterruptsAuditAtChunkBoundaryAndThenCatchesUp() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let initial = String(repeating: fixture.line("bulk"), count: 45_000)
        let source = try fixture.writeActiveSession(name: "audit-priority.jsonl", contents: initial)
        try fixture.makeAgent().performOneShotScan()
        try fixture.writeAuditState(IntegrityAuditState(
            lastCompletedAt: fixture.now.addingTimeInterval(-86_401),
            lastResult: "previous",
            repairedCount: 0
        ))

        let gate = AuditReadGate()
        let interruptionWasSet = DispatchSemaphore(value: 0)
        let auditor = BackupIntegrityAuditor(
            paths: fixture.paths,
            chunkSize: 1_048_576,
            instrumentation: IntegrityAuditInstrumentation(didReadChunk: { _, _, _ in
                gate.pauseFirstChunk()
            })
        )
        let agent = fixture.makeAgent(
            instrumentation: BackupAgentInstrumentation(auditInterruptionSet: {
                interruptionWasSet.signal()
            }),
            integrityAuditorFactory: { _ in auditor }
        )
        let auditResult = ThreadResultBox<IntegrityAuditOutcome>()
        let scanResult = ThreadResultBox<Void>()
        let auditDone = DispatchSemaphore(value: 0)
        let scanDone = DispatchSemaphore(value: 0)
        let deviceID = fixture.deviceID
        DispatchQueue.global().async {
            defer { auditDone.signal() }
            auditResult.capture { try agent.performIntegrityAuditIfDue(deviceID: deviceID) }
        }
        #expect(gate.waitUntilPaused() == .success)
        try fixture.append(fixture.line("new"), to: source)
        DispatchQueue.global().async {
            defer { scanDone.signal() }
            scanResult.capture { try agent.performOneShotScan() }
        }
        #expect(interruptionWasSet.wait(timeout: .now() + 5) == .success)
        gate.resume()
        #expect(auditDone.wait(timeout: .now() + 10) == .success)
        #expect(scanDone.wait(timeout: .now() + 10) == .success)

        #expect(try auditResult.get() == .interrupted)
        _ = try scanResult.get()
        let target = try fixture.paths.backupFileURL(for: source)
        #expect(try String(contentsOf: target, encoding: .utf8).hasSuffix(fixture.line("new")))
    }

    @Test
    func interruptedRepairWithCorruptPrefixRollsBackQueuedAppendWithoutAdvancingMetadata() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let initial = String(repeating: fixture.line("bulk"), count: 45_000)
        let source = try fixture.writeActiveSession(name: "repair-priority.jsonl", contents: initial)
        try fixture.makeAgent().performOneShotScan()
        try fixture.writeAuditState(IntegrityAuditState(
            lastCompletedAt: fixture.now.addingTimeInterval(-86_401),
            lastResult: "previous",
            repairedCount: 0
        ))
        let target = try fixture.paths.backupFileURL(for: source)
        var corrupted = try Data(contentsOf: target)
        corrupted[corrupted.startIndex] ^= 0x01
        try corrupted.write(to: target)

        let gate = AuditReadGate()
        let interruptionWasSet = DispatchSemaphore(value: 0)
        let auditor = BackupIntegrityAuditor(
            paths: fixture.paths,
            chunkSize: 1_048_576,
            instrumentation: IntegrityAuditInstrumentation(didStreamChunk: { phase, _, _, _ in
                if phase == .repairTemporary { gate.pauseFirstChunk() }
            })
        )
        let agent = fixture.makeAgent(
            instrumentation: BackupAgentInstrumentation(auditInterruptionSet: {
                interruptionWasSet.signal()
            }),
            integrityAuditorFactory: { _ in auditor }
        )
        let auditResult = ThreadResultBox<IntegrityAuditOutcome>()
        let scanResult = ThreadResultBox<Void>()
        let auditDone = DispatchSemaphore(value: 0)
        let scanDone = DispatchSemaphore(value: 0)
        let deviceID = fixture.deviceID
        DispatchQueue.global().async {
            defer { auditDone.signal() }
            auditResult.capture { try agent.performIntegrityAuditIfDue(deviceID: deviceID) }
        }
        #expect(gate.waitUntilPaused() == .success)
        try fixture.append(fixture.line("new"), to: source)
        DispatchQueue.global().async {
            defer { scanDone.signal() }
            scanResult.capture { try agent.performOneShotScan() }
        }
        #expect(interruptionWasSet.wait(timeout: .now() + 5) == .success)
        gate.resume()
        #expect(auditDone.wait(timeout: .now() + 10) == .success)
        #expect(scanDone.wait(timeout: .now() + 10) == .success)

        #expect(try auditResult.get() == .interrupted)
        #expect(throws: BackupFileVerificationError.self) {
            _ = try scanResult.get()
        }
        #expect(try String(contentsOf: target, encoding: .utf8).hasSuffix(fixture.line("new")) == false)
        #expect(try target.resourceValues(forKeys: [.fileSizeKey]).fileSize == initial.utf8.count)
        #expect(try fixture.loadCursor(sourcePath: source.path)?.lastByteOffset == Int64(initial.utf8.count))
    }

    @Test
    func nextIncrementalScanRecoversPreparedRepairJournalBeforeAppending() throws {
        let fixture = try DirectNASBackupFixture()
        defer { fixture.cleanup() }
        let initial = fixture.line("one")
        let source = try fixture.writeActiveSession(name: "wal-before-scan.jsonl", contents: initial)
        try fixture.makeAgent().performOneShotScan()
        try fixture.writeAuditState(IntegrityAuditState(
            lastCompletedAt: fixture.now.addingTimeInterval(-86_401),
            lastResult: "previous",
            repairedCount: 0
        ))
        let target = try fixture.paths.backupFileURL(for: source)
        var corrupted = try Data(contentsOf: target)
        corrupted[corrupted.startIndex] ^= 0x01
        try corrupted.write(to: target)
        let crashAuditor = BackupIntegrityAuditor(
            paths: fixture.paths,
            chunkSize: 1_048_576,
            instrumentation: IntegrityAuditInstrumentation(checkpoint: { checkpoint in
                if checkpoint == .afterFormalReplaceBeforeInstalledJournalCommit {
                    throw DirectNASBackupTestError.injectedTargetFailure
                }
            })
        )
        let crashAgent = fixture.makeAgent(integrityAuditorFactory: { _ in crashAuditor })

        #expect(throws: DirectNASBackupTestError.injectedTargetFailure) {
            _ = try crashAgent.performIntegrityAuditIfDue(deviceID: fixture.deviceID)
        }
        let pendingJournal = fixture.paths.stateRoot.appendingPathComponent("integrity-repair-pending.json")
        #expect(FileManager.default.fileExists(atPath: pendingJournal.path))

        try fixture.append(fixture.line("two"), to: source)
        try fixture.makeAgent().performOneShotScan()

        #expect(FileManager.default.fileExists(atPath: pendingJournal.path) == false)
        #expect(try String(contentsOf: target, encoding: .utf8) == initial + fixture.line("two"))
        #expect(try fixture.loadAuditState().repairedCount == 1)
        #expect(try fixture.loadLocalStatus().repairCount == 1)
        #expect(try fixture.loadLocalStatus().lastRepairAt == fixture.now)
    }

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
    let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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
        remoteStatusWriter: ((Data, URL) throws -> Void)? = nil,
        instrumentation: BackupAgentInstrumentation = BackupAgentInstrumentation(),
        integrityAuditorFactory: ((BackupPaths) -> BackupIntegrityAuditor)? = nil,
        sessionBackupStreamer: SessionBackupStreamer? = nil
    ) -> BackupAgent {
        guard integrityAuditorFactory != nil || sessionBackupStreamer != nil else {
            return BackupAgent(
                paths: paths,
                now: { self.now },
                targetValidator: targetValidator ?? BackupTargetValidator(backupRoot: paths.backupRoot),
                fileCommitter: fileCommitter,
                remoteStatusWriter: remoteStatusWriter
            )
        }
        return BackupAgent(
            paths: paths,
            now: { self.now },
            targetValidator: targetValidator ?? BackupTargetValidator(backupRoot: paths.backupRoot),
            fileCommitter: fileCommitter,
            remoteStatusWriter: remoteStatusWriter,
            sessionBackupStreamer: sessionBackupStreamer ?? SessionBackupStreamer(),
            cursorStoreFactory: { BackupCursorStore(databaseURL: $0) },
            manifestStoreFactory: {
                BackupManifestStore(manifestURL: $0, createParentDirectories: false)
            },
            instrumentation: instrumentation,
            integrityAuditorFactory: integrityAuditorFactory ?? { BackupIntegrityAuditor(paths: $0) }
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

    func writeAuditState(_ state: IntegrityAuditState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableAtomicWriter().write(
            try encoder.encode(state),
            to: paths.auditStateURL,
            createParentDirectories: true
        )
    }

    func loadAuditState() throws -> IntegrityAuditState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(IntegrityAuditState.self, from: Data(contentsOf: paths.auditStateURL))
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

private final class AuditReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didPause = false
    private let paused = DispatchSemaphore(value: 0)
    private let continuation = DispatchSemaphore(value: 0)

    func pauseFirstChunk() {
        let shouldPause = lock.withLock {
            guard !didPause else { return false }
            didPause = true
            return true
        }
        guard shouldPause else { return }
        paused.signal()
        continuation.wait()
    }

    func waitUntilPaused() -> DispatchTimeoutResult {
        paused.wait(timeout: .now() + 5)
    }

    func resume() {
        continuation.signal()
    }
}

private final class ThreadResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func capture(_ operation: () throws -> Value) {
        let captured = Result { try operation() }
        lock.withLock { result = captured }
    }

    func get() throws -> Value {
        try lock.withLock {
            try #require(result).get()
        }
    }
}
