import CryptoKit
import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct BackupIntegrityAuditorTests {
    @Test
    func deterministicScheduleMatchesCrossPlatformFixture() throws {
        let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))

        #expect(BackupIntegrityAuditor.dailyOffsetSeconds(deviceID: deviceID) == 38_733)
        #expect(BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID) == 676)
        #expect(BackupIntegrityAuditor.dailyOffsetSeconds(deviceID: deviceID) == BackupIntegrityAuditor.dailyOffsetSeconds(deviceID: deviceID))
    }

    @Test
    func deterministicScheduleAlwaysStaysInRequiredRanges() throws {
        for value in 0..<256 {
            let suffix = String(format: "%012x", value)
            let deviceID = try #require(UUID(uuidString: "00000000-0000-0000-0000-\(suffix)"))
            #expect((0..<86_400).contains(Int(BackupIntegrityAuditor.dailyOffsetSeconds(deviceID: deviceID))))
            #expect((0...1_800).contains(Int(BackupIntegrityAuditor.overdueWakeDelaySeconds(deviceID: deviceID))))
        }
    }

    @Test
    func completedAuditLessThanTwentyFourHoursAgoIsNotDue() throws {
        let fixture = try IntegrityAuditFixture()
        defer { fixture.cleanup() }
        try fixture.writeAuditState(IntegrityAuditState(
            lastCompletedAt: fixture.dueDate.addingTimeInterval(-86_399),
            lastResult: "completed",
            repairedCount: 0
        ))

        let outcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: fixture.cursors,
            interruptionRequested: { false }
        )

        #expect(outcome == .notDue)
    }

    @Test
    func equalAuditStopsAtCommittedOffsetAndIgnoresPartialTail() throws {
        let committed = IntegrityAuditFixture.multiChunkJSONL()
        let fixture = try IntegrityAuditFixture(
            committedLocalPrefix: committed,
            localTail: Data("partial-local-tail".utf8),
            nasData: committed
        )
        defer { fixture.cleanup() }

        let outcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: fixture.cursors,
            interruptionRequested: { false }
        )

        #expect(outcome == .completed(checked: 1, repaired: 0))
        #expect(try fixture.nasTargetData() == committed)
        #expect(try fixture.loadManifest().sessions[fixture.sessionID]?.contentHash == sha256(committed))
        #expect(try fixture.loadAuditState().lastCompletedAt == fixture.dueDate)
    }

    @Test
    func corruptionInAnyChunkIsDetectedAndRepaired() throws {
        let committed = IntegrityAuditFixture.multiChunkJSONL()
        for chunkIndex in 0..<3 {
            var corrupted = committed
            let index = min(corrupted.count - 2, chunkIndex * 1_048_576 + 17)
            corrupted[index] ^= 0x01
            let fixture = try IntegrityAuditFixture(
                committedLocalPrefix: committed,
                nasData: corrupted,
                name: "chunk-\(chunkIndex)"
            )
            defer { fixture.cleanup() }

            let outcome = try fixture.auditor.runIfDue(
                now: fixture.dueDate,
                deviceID: fixture.deviceID,
                cursors: fixture.cursors,
                interruptionRequested: { false }
            )

            #expect(outcome == .completed(checked: 1, repaired: 1))
            #expect(try fixture.nasTargetData() == committed)
        }
    }

    @Test
    func interruptionDiscardsBufferedHashAndRestartsFileAtByteZero() throws {
        let committed = IntegrityAuditFixture.multiChunkJSONL()
        let observations = ChunkObservations()
        let fixture = try IntegrityAuditFixture(
            committedLocalPrefix: committed,
            nasData: committed,
            instrumentation: IntegrityAuditInstrumentation(
                didReadChunk: { _, offset, _ in observations.append(offset) }
            )
        )
        defer { fixture.cleanup() }
        let manifestBefore = try fixture.loadManifest()
        let stateBefore = try fixture.loadAuditState()

        let firstOutcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: fixture.cursors,
            interruptionRequested: { !observations.values.isEmpty }
        )

        #expect(firstOutcome == .interrupted)
        #expect(observations.values == [0])
        #expect(try fixture.loadManifest() == manifestBefore)
        #expect(try fixture.loadAuditState() == stateBefore)

        observations.reset()
        let secondOutcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: fixture.cursors,
            interruptionRequested: { false }
        )

        #expect(secondOutcome == .completed(checked: 1, repaired: 0))
        #expect(observations.values.first == 0)
    }

    @Test
    func successfulRepairQuarantinesOldBytesBeforeReplacing() throws {
        let fixture = try IntegrityAuditFixture(corrupted: true)
        defer { fixture.cleanup() }

        let outcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: fixture.cursors,
            interruptionRequested: { false }
        )

        #expect(outcome == .completed(checked: 1, repaired: 1))
        #expect(try fixture.nasTargetData() == fixture.committedLocalPrefix)
        #expect(try fixture.quarantineCopies().count == 1)
        #expect(try fixture.quarantineCopies().first?.data == fixture.corruptedNASData)
        #expect(try fixture.loadManifest().sessions[fixture.sessionID]?.contentHash == sha256(fixture.committedLocalPrefix))
        let state = try fixture.loadAuditState()
        #expect(state.lastCompletedAt == fixture.dueDate)
        #expect(state.repairedCount == 1)
    }

    @Test(arguments: [
        IntegrityAuditCheckpoint.beforeTemporaryFlush,
        .beforeQuarantineCopy,
        .beforeReplace,
        .beforePostReplaceVerification,
        .beforeMetadataCommit
    ])
    func repairFailureMatrixPreservesRequiredDurabilityBoundary(
        checkpoint: IntegrityAuditCheckpoint
    ) throws {
        let fixture = try IntegrityAuditFixture(
            corrupted: true,
            instrumentation: IntegrityAuditInstrumentation(checkpoint: { observed in
                if observed == checkpoint { throw IntegrityAuditTestError.injected(checkpoint) }
            })
        )
        defer { fixture.cleanup() }
        let manifestBefore = try fixture.loadManifest()
        let stateBefore = try fixture.loadAuditState()

        #expect(throws: IntegrityAuditTestError.injected(checkpoint)) {
            _ = try fixture.auditor.runIfDue(
                now: fixture.dueDate,
                deviceID: fixture.deviceID,
                cursors: fixture.cursors,
                interruptionRequested: { false }
            )
        }

        switch checkpoint {
        case .beforeTemporaryFlush, .beforeQuarantineCopy, .beforeReplace, .beforePostReplaceVerification:
            #expect(try fixture.nasTargetData() == fixture.corruptedNASData)
        case .beforeMetadataCommit:
            #expect(try fixture.nasTargetData() == fixture.committedLocalPrefix)
        }
        #expect(try fixture.loadManifest() == manifestBefore)
        #expect(try fixture.loadAuditState() == stateBefore)
        let copies = try fixture.quarantineCopies()
        if checkpoint == .beforeTemporaryFlush || checkpoint == .beforeQuarantineCopy {
            #expect(copies.isEmpty)
        } else {
            #expect(copies.count == 1)
            #expect(copies.first?.data == fixture.corruptedNASData)
        }
    }

    @Test(arguments: UnsafeLocalSourceCase.allCases)
    func unsafeLocalSourceNeverOverwritesFormalNASFile(sourceCase: UnsafeLocalSourceCase) throws {
        let fixture = try IntegrityAuditFixture(corrupted: true)
        defer { fixture.cleanup() }
        let cursors = try fixture.apply(sourceCase)

        #expect(throws: (any Error).self) {
            _ = try fixture.auditor.runIfDue(
                now: fixture.dueDate,
                deviceID: fixture.deviceID,
                cursors: cursors,
                interruptionRequested: { false }
            )
        }

        #expect(try fixture.nasTargetData() == fixture.corruptedNASData)
    }

    @Test
    func structurallyInvalidCommittedSourceNeverOverwritesFormalNASFile() throws {
        let local = Data("not-json\n".utf8)
        let target = Data("bad-json\n".utf8)
        let fixture = try IntegrityAuditFixture(committedLocalPrefix: local, nasData: target)
        defer { fixture.cleanup() }

        #expect(throws: (any Error).self) {
            _ = try fixture.auditor.runIfDue(
                now: fixture.dueDate,
                deviceID: fixture.deviceID,
                cursors: fixture.cursors,
                interruptionRequested: { false }
            )
        }

        #expect(try fixture.nasTargetData() == target)
        #expect(try fixture.quarantineCopies().isEmpty)
    }

    @Test
    func retentionExpiresOldCopiesCapsNewestThreeAndLeavesUnownedPathsAlone() throws {
        let fixture = try IntegrityAuditFixture(cursorsEnabled: false)
        defer { fixture.cleanup() }
        let sessionDirectory = fixture.paths.repairQuarantineRoot
            .appendingPathComponent(fixture.sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        var owned: [(url: URL, date: Date)] = []
        for day in [40, 20, 10, 5, 1] {
            let date = fixture.dueDate.addingTimeInterval(TimeInterval(-day * 86_400))
            let name = "repair-\(fixture.sessionID)-\(day)-00000000-0000-0000-0000-00000000000\(day % 10).jsonl"
            let url = sessionDirectory.appendingPathComponent(name)
            try Data("copy-\(day)".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            owned.append((url, date))
        }
        let unrelatedInQuarantine = sessionDirectory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelatedInQuarantine)
        let unrelatedMatchingExtension = sessionDirectory.appendingPathComponent(
            "repair-\(fixture.sessionID)-not-application-owned.jsonl"
        )
        try Data("keep-matching-extension".utf8).write(to: unrelatedMatchingExtension)
        let link = sessionDirectory.appendingPathComponent("repair-\(fixture.sessionID)-link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unrelatedInQuarantine)
        let formal = fixture.paths.sessionsRoot.appendingPathComponent("formal.jsonl")
        try FileManager.default.createDirectory(at: formal.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("formal".utf8).write(to: formal)
        let unrelatedNAS = fixture.paths.backupRoot.appendingPathComponent("other-device-data.bin")
        try Data("other".utf8).write(to: unrelatedNAS)

        let outcome = try fixture.auditor.runIfDue(
            now: fixture.dueDate,
            deviceID: fixture.deviceID,
            cursors: [:],
            interruptionRequested: { false }
        )

        #expect(outcome == .completed(checked: 0, repaired: 0))
        let retainedOwned = owned.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        #expect(retainedOwned.map(\.date).sorted() == owned.map(\.date).sorted().suffix(3))
        #expect(FileManager.default.fileExists(atPath: unrelatedInQuarantine.path))
        #expect(FileManager.default.fileExists(atPath: unrelatedMatchingExtension.path))
        #expect(FileManager.default.fileExists(atPath: link.path))
        #expect(try Data(contentsOf: formal) == Data("formal".utf8))
        #expect(try Data(contentsOf: unrelatedNAS) == Data("other".utf8))
    }
}

enum UnsafeLocalSourceCase: String, CaseIterable, Sendable {
    case missing
    case symlinked
    case escaped
    case nonRegular
    case unreadable
}

private enum IntegrityAuditTestError: Error, Equatable {
    case injected(IntegrityAuditCheckpoint)
}

private final class ChunkObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int64] = []

    var values: [Int64] {
        lock.withLock { storage }
    }

    func append(_ value: Int64) {
        lock.withLock { storage.append(value) }
    }

    func reset() {
        lock.withLock { storage = [] }
    }
}

private final class IntegrityAuditFixture {
    let root: URL
    let paths: BackupPaths
    let deviceID: UUID
    let dueDate = Date(timeIntervalSince1970: 1_783_824_000)
    let sessionID: String
    let source: URL
    let target: URL
    let committedLocalPrefix: Data
    let corruptedNASData: Data
    let auditor: BackupIntegrityAuditor
    private(set) var cursors: [String: BackupCursor]

    init(
        committedLocalPrefix: Data = Data("{\"role\":\"user\",\"content\":\"trusted\"}\n".utf8),
        localTail: Data = Data(),
        nasData: Data? = nil,
        corrupted: Bool = false,
        name: String = UUID().uuidString,
        cursorsEnabled: Bool = true,
        instrumentation: IntegrityAuditInstrumentation = IntegrityAuditInstrumentation()
    ) throws {
        root = FileManager.default.temporaryDirectory
            .resolvingSymlinksInPath()
            .appendingPathComponent("BackupIntegrityAuditorTests-\(name)", isDirectory: true)
        let codexRoot = root.appendingPathComponent(".codex", isDirectory: true)
        let backupRoot = root.appendingPathComponent("mounted-nas/device/incremental-backups", isDirectory: true)
        let stateRoot = root.appendingPathComponent("local-state", isDirectory: true)
        paths = BackupPaths(codexRoot: codexRoot, backupRoot: backupRoot, stateRoot: stateRoot)
        deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        sessionID = "session-one"
        source = codexRoot.appendingPathComponent("sessions/\(sessionID).jsonl")
        target = backupRoot.appendingPathComponent("sessions/\(sessionID).jsonl")
        self.committedLocalPrefix = committedLocalPrefix
        var damaged = nasData ?? committedLocalPrefix
        if corrupted, !damaged.isEmpty {
            damaged[damaged.startIndex] ^= 0x01
        }
        corruptedNASData = damaged
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        var sourceData = committedLocalPrefix
        sourceData.append(localTail)
        try sourceData.write(to: source)
        try damaged.write(to: target)
        let cursor = BackupCursor(
            sessionId: sessionID,
            sourcePath: source.path,
            backupPath: "sessions/\(sessionID).jsonl",
            lastByteOffset: Int64(committedLocalPrefix.count),
            lastSourceSize: Int64(sourceData.count),
            lastSourceModifiedAt: dueDate.timeIntervalSince1970,
            lineCount: committedLocalPrefix.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) },
            pendingPartialLine: localTail,
            status: "active",
            lastError: nil,
            updatedAt: dueDate.addingTimeInterval(-100_000).timeIntervalSince1970
        )
        cursors = cursorsEnabled ? [source.path: cursor] : [:]
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        if cursorsEnabled { try cursorStore.upsert(cursor) }
        let manifest = BackupManifest(
            codexRoot: codexRoot.path,
            backupRoot: backupRoot.path,
            createdAt: dueDate.addingTimeInterval(-200_000),
            updatedAt: dueDate.addingTimeInterval(-100_000),
            sessions: cursorsEnabled ? [
                sessionID: BackupSessionRecord(
                    sessionId: sessionID,
                    sourcePath: source.path,
                    backupPath: cursor.backupPath,
                    title: nil,
                    firstSeenAt: dueDate.addingTimeInterval(-200_000),
                    lastBackedUpAt: dueDate.addingTimeInterval(-100_000),
                    lineCount: cursor.lineCount,
                    bytesBackedUp: cursor.lastByteOffset,
                    status: "active",
                    contentHash: "stale-hash"
                )
            ] : [:]
        )
        try BackupManifestStore(manifestURL: paths.manifestURL, createParentDirectories: false).save(manifest)
        auditor = BackupIntegrityAuditor(
            paths: paths,
            chunkSize: 1_048_576,
            instrumentation: instrumentation
        )
        try writeAuditState(IntegrityAuditState(
            lastCompletedAt: dueDate.addingTimeInterval(-86_401),
            lastResult: "previous",
            repairedCount: 0
        ))
    }

    func cleanup() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        try? FileManager.default.removeItem(at: root)
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

    func loadManifest() throws -> BackupManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupManifest.self, from: Data(contentsOf: paths.manifestURL))
    }

    func nasTargetData() throws -> Data {
        try Data(contentsOf: target)
    }

    func quarantineCopies() throws -> [(url: URL, data: Data)] {
        guard FileManager.default.fileExists(atPath: paths.repairQuarantineRoot.path),
              let enumerator = FileManager.default.enumerator(
                at: paths.repairQuarantineRoot,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else { return [] }
        var copies: [(URL, Data)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            copies.append((url, try Data(contentsOf: url)))
        }
        return copies.sorted { $0.0.path < $1.0.path }
    }

    func apply(_ sourceCase: UnsafeLocalSourceCase) throws -> [String: BackupCursor] {
        let original = try #require(cursors[source.path])
        switch sourceCase {
        case .missing:
            try FileManager.default.removeItem(at: source)
            return [source.path: original]
        case .symlinked:
            let outside = root.appendingPathComponent("outside-symlink.jsonl")
            try committedLocalPrefix.write(to: outside)
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
            return [source.path: original]
        case .escaped:
            let outside = root.appendingPathComponent("escaped.jsonl")
            try committedLocalPrefix.write(to: outside)
            var escaped = original
            escaped.sourcePath = outside.path
            return [outside.path: escaped]
        case .nonRegular:
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            return [source.path: original]
        case .unreadable:
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: source.path)
            return [source.path: original]
        }
    }

    static func multiChunkJSONL() -> Data {
        let line = "{\"role\":\"user\",\"content\":\"" + String(repeating: "x", count: 991) + "\"}\n"
        var data = Data()
        let lineData = Data(line.utf8)
        while data.count < 3 * 1_048_576 + 257 {
            data.append(lineData)
        }
        return data
    }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
