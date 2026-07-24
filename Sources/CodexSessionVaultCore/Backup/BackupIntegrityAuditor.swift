import CryptoKit
import Foundation

enum IntegrityAuditCheckpoint: Equatable, Sendable {
    case beforeTemporaryFlush
    case beforeQuarantineCopy
    case beforeReplace
    case beforePostReplaceVerification
    case beforePreparedRepairJournalFlush
    case afterPreparedJournalCommitBeforeFormalReplace
    case afterFormalReplaceBeforeInstalledJournalCommit
    case beforeMetadataCommit
    case afterManifestCommit
    case afterCursorCommit
    case afterAuditStateCommit
    case afterRuntimeStatusCommit
}

enum IntegrityAuditStreamPhase: Equatable, Sendable {
    case comparison
    case repairTemporary
    case repairTemporaryVerification
    case quarantineCopy
    case quarantineVerification
    case formalPreReplacementVerification
    case installedVerification
}

struct IntegrityAuditInstrumentation: @unchecked Sendable {
    let didReadChunk: @Sendable (URL, Int64, Int) -> Void
    let didStreamChunk: @Sendable (IntegrityAuditStreamPhase, URL, Int64, Int) -> Void
    let didWriteChunk: @Sendable (IntegrityAuditStreamPhase, URL, Int) -> Void
    let checkpoint: @Sendable (IntegrityAuditCheckpoint) throws -> Void

    init(
        didReadChunk: @escaping @Sendable (URL, Int64, Int) -> Void = { _, _, _ in },
        didStreamChunk: @escaping @Sendable (IntegrityAuditStreamPhase, URL, Int64, Int) -> Void = { _, _, _, _ in },
        didWriteChunk: @escaping @Sendable (IntegrityAuditStreamPhase, URL, Int) -> Void = { _, _, _ in },
        checkpoint: @escaping @Sendable (IntegrityAuditCheckpoint) throws -> Void = { _ in }
    ) {
        self.didReadChunk = didReadChunk
        self.didStreamChunk = didStreamChunk
        self.didWriteChunk = didWriteChunk
        self.checkpoint = checkpoint
    }
}

public enum IntegrityAuditError: Error, Equatable, Sendable {
    case missingManifestRecord(String)
    case unsafeCursor(String)
    case invalidCommittedSource(String)
    case verificationFailed(String)
    case restoreFailed(String)
}

extension IntegrityAuditError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .missingManifestRecord(sessionID):
            return "Integrity audit has no manifest record for session: \(sessionID)"
        case let .unsafeCursor(path):
            return "Integrity audit rejected unsafe cursor metadata: \(path)"
        case let .invalidCommittedSource(path):
            return "Integrity repair rejected structurally invalid committed JSONL: \(path)"
        case let .verificationFailed(path):
            return "Integrity verification failed: \(path)"
        case let .restoreFailed(path):
            return "Integrity repair rollback failed: \(path)"
        }
    }
}

public struct BackupIntegrityAuditor: @unchecked Sendable {
    private static let maximumChunkSize = 1_048_576
    private static let auditInterval: TimeInterval = 86_400
    private static let retentionInterval: TimeInterval = 30 * 86_400
    private static let maximumQuarantineCopiesPerSession = 3

    private let paths: BackupPaths
    private let fileManager: FileManager
    private let chunkSize: Int
    private let synchronize: (FileHandle) throws -> Void
    private let instrumentation: IntegrityAuditInstrumentation

    public init(paths: BackupPaths, fileManager: FileManager = .default) {
        self.init(
            paths: paths,
            fileManager: fileManager,
            chunkSize: Self.maximumChunkSize,
            synchronize: { try $0.synchronize() },
            instrumentation: IntegrityAuditInstrumentation()
        )
    }

    init(
        paths: BackupPaths,
        fileManager: FileManager = .default,
        chunkSize: Int,
        synchronize: @escaping (FileHandle) throws -> Void = { try $0.synchronize() },
        instrumentation: IntegrityAuditInstrumentation = IntegrityAuditInstrumentation()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.chunkSize = min(max(1, chunkSize), Self.maximumChunkSize)
        self.synchronize = synchronize
        self.instrumentation = instrumentation
    }

    public static func dailyOffsetSeconds(deviceID: UUID) -> TimeInterval {
        TimeInterval(digestWord(deviceID: deviceID, range: 0..<8) % 86_400)
    }

    public static func overdueWakeDelaySeconds(deviceID: UUID) -> TimeInterval {
        TimeInterval(digestWord(deviceID: deviceID, range: 8..<16) % 1_801)
    }

    public func runIfDue(
        now: Date,
        deviceID: UUID,
        cursors: [String: BackupCursor],
        interruptionRequested: @Sendable () -> Bool
    ) throws -> IntegrityAuditOutcome {
        var state = try loadAuditState()
        let pendingRepair = try loadPendingRepairMetadata()
        if pendingRepair == nil,
           let lastCompletedAt = state.lastCompletedAt,
           now.timeIntervalSince(lastCompletedAt) < Self.auditInterval {
            return .notDue
        }

        try BackupTargetValidator(backupRoot: paths.backupRoot, fileManager: fileManager).validateTarget()
        if pendingRepair == nil {
            try cleanupQuarantine(now: now)
        }
        let manifestStore = BackupManifestStore(
            manifestURL: paths.manifestURL,
            createParentDirectories: false
        )
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now
        )
        if let pendingRepair {
            try resolvePendingRepairMetadata(
                pendingRepair,
                manifest: &manifest,
                manifestStore: manifestStore,
                state: &state
            )
            try cleanupQuarantine(now: now)
        }
        if let lastCompletedAt = state.lastCompletedAt,
           now.timeIntervalSince(lastCompletedAt) < Self.auditInterval {
            return .notDue
        }
        var bufferedHashes: [String: String] = [:]
        var checked = 0
        var repaired = 0
        let orderedCursors = cursors.values.sorted(by: Self.cursorOrder)
        let currentCursorsBySession = [String: BackupCursor](uniqueKeysWithValues: orderedCursors.compactMap { cursor in
            guard let record = manifest.sessions[cursor.sessionId],
                  cursor.sourcePath == record.sourcePath,
                  cursor.backupPath == record.backupPath,
                  cursor.lastByteOffset == record.bytesBackedUp else {
                return nil
            }
            return (cursor.sessionId, cursor)
        })
        let staleCursorSourcePaths = Set<String>(orderedCursors.compactMap { cursor in
            guard let record = manifest.sessions[cursor.sessionId],
                  currentCursorsBySession[cursor.sessionId] != nil,
                  isProvenStaleCursor(cursor, record: record) else {
                return nil
            }
            return cursor.sourcePath
        })

        for cursor in orderedCursors where !staleCursorSourcePaths.contains(cursor.sourcePath) {
            guard !interruptionRequested() else { return .interrupted }
            guard let record = manifest.sessions[cursor.sessionId] else {
                throw IntegrityAuditError.missingManifestRecord(cursor.sessionId)
            }
            let validated = try validate(cursor: cursor, record: record)
            switch try compareCommittedPrefix(
                validated,
                interruptionRequested: interruptionRequested
            ) {
            case .interrupted:
                return .interrupted
            case let .equal(hash):
                bufferedHashes[cursor.sessionId] = hash
            case .mismatch:
                switch try repair(
                    validated,
                    now: now,
                    manifest: &manifest,
                    manifestStore: manifestStore,
                    state: &state,
                    interruptionRequested: interruptionRequested
                ) {
                case .interrupted:
                    return .interrupted
                case let .repaired(hash):
                    bufferedHashes.removeValue(forKey: cursor.sessionId)
                    if manifest.sessions[cursor.sessionId]?.contentHash != hash {
                        throw IntegrityAuditError.verificationFailed(validated.target.path)
                    }
                    repaired += 1
                }
            }
            checked += 1
        }

        guard !interruptionRequested() else { return .interrupted }
        var manifestChanged = false
        for (sessionID, hash) in bufferedHashes {
            guard var record = manifest.sessions[sessionID], record.contentHash != hash else { continue }
            record.contentHash = hash
            manifest.sessions[sessionID] = record
            manifestChanged = true
        }
        if manifestChanged {
            manifest.updatedAt = now
            try manifestStore.save(manifest)
        }
        try refreshVerification(
            manifest: manifest,
            cursorsBySession: currentCursorsBySession,
            verifiedAt: now
        )
        if !staleCursorSourcePaths.isEmpty {
            let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
            try cursorStore.open()
            try cursorStore.upsertMany(
                [],
                deletingSourcePaths: Array(staleCursorSourcePaths)
            )
        }

        try cleanupQuarantine(now: now)
        state.lastCompletedAt = now
        state.lastResult = "completed"
        try saveAuditState(state)
        try updatePersistedStatus(
            lastAuditAt: now,
            lastAuditResult: state.lastResult,
            lastRepairAt: nil,
            repairCount: state.repairedCount
        )
        return .completed(checked: checked, repaired: repaired)
    }

    private func refreshVerification(
        manifest: BackupManifest,
        cursorsBySession: [String: BackupCursor],
        verifiedAt: Date
    ) throws {
        guard !cursorsBySession.isEmpty else { return }
        let store = BackupVerificationStore(
            fileURL: paths.verificationURL,
            createParentDirectories: false,
            fileManager: fileManager
        )
        var document = try store.load()
        let original = document
        let verifier = BackupFileVerifier(chunkSize: document.chunkSize)
        for sessionID in cursorsBySession.keys.sorted() {
            guard let cursor = cursorsBySession[sessionID],
                  let record = manifest.sessions[sessionID],
                  cursor.backupPath == record.backupPath,
                  cursor.lastByteOffset == record.bytesBackedUp else {
                continue
            }
            let target = try trustedPendingURL(
                relativePath: record.backupPath,
                allowedRoots: [paths.sessionsRoot, paths.archivedSessionsRoot]
            )
            let result = try verifier.verifyFull(
                target,
                expectedByteCount: record.bytesBackedUp,
                expectedLineCount: record.lineCount,
                expectedContentHash: record.contentHash
            )
            document.sessions[sessionID] = BackupSessionVerification(
                backupPath: record.backupPath,
                byteCount: result.byteCount,
                lineCount: result.lineCount,
                chunkHashes: result.chunkHashes,
                verifiedAt: verifiedAt
            )
        }
        if document != original {
            try store.save(document)
        }
    }

    func recordInitialSeedCompleted(at date: Date) throws {
        var state = try loadAuditState()
        guard state.lastCompletedAt == nil else { return }
        state.lastCompletedAt = date
        state.lastResult = "seeded"
        try saveAuditState(state)
    }

    func recoverPendingRepairIfNeeded(now: Date) throws {
        guard let pendingRepair = try loadPendingRepairMetadata() else { return }
        try BackupTargetValidator(
            backupRoot: paths.backupRoot,
            fileManager: fileManager
        ).validateTarget()
        let manifestStore = BackupManifestStore(
            manifestURL: paths.manifestURL,
            createParentDirectories: false
        )
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now
        )
        var state = try loadAuditState()
        try resolvePendingRepairMetadata(
            pendingRepair,
            manifest: &manifest,
            manifestStore: manifestStore,
            state: &state
        )
        try cleanupQuarantine(now: now)
    }

    private static func digestWord(deviceID: UUID, range: Range<Int>) -> UInt64 {
        let bytes = Array(SHA256.hash(data: Data(deviceID.uuidString.lowercased().utf8)))
        return bytes[range].reduce(UInt64(0)) { partial, byte in
            (partial << 8) | UInt64(byte)
        }
    }

    private static func cursorOrder(_ lhs: BackupCursor, _ rhs: BackupCursor) -> Bool {
        if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
        return lhs.sourcePath < rhs.sourcePath
    }

    private func isProvenStaleCursor(
        _ cursor: BackupCursor,
        record: BackupSessionRecord
    ) -> Bool {
        guard cursor.sessionId == record.sessionId,
              cursor.sourcePath != record.sourcePath,
              cursor.backupPath == record.backupPath else {
            return false
        }
        let source = URL(fileURLWithPath: cursor.sourcePath, isDirectory: false).standardizedFileURL
        guard SessionIdentity.sessionID(from: source) == cursor.sessionId,
              let trustedSourceRoot = sourceRootIfTrusted(for: source) else {
            return false
        }
        do {
            try RestoreFilesystemValidator.validateSource(
                source,
                under: trustedSourceRoot,
                allowMissing: true
            )
            let target = paths.backupRoot.appendingPathComponent(cursor.backupPath, isDirectory: false)
            guard paths.relativeBackupPath(for: target) == cursor.backupPath else { return false }
            try RestoreFilesystemValidator.validateDestination(target, under: paths.backupRoot)
            return true
        } catch {
            return false
        }
    }

    private func validate(
        cursor: BackupCursor,
        record: BackupSessionRecord
    ) throws -> ValidatedAuditFile {
        guard cursor.lastByteOffset >= 0,
              cursor.sessionId == record.sessionId,
              cursor.sourcePath == record.sourcePath,
              cursor.backupPath == record.backupPath,
              cursor.lastByteOffset == record.bytesBackedUp else {
            throw IntegrityAuditError.unsafeCursor(cursor.sourcePath)
        }

        let source = URL(fileURLWithPath: cursor.sourcePath, isDirectory: false).standardizedFileURL
        guard source.pathExtension.lowercased() == "jsonl",
              let trustedSourceRoot = sourceRootIfTrusted(for: source) else {
            throw BackupPathsError.unsafeSource(source.path)
        }
        let expectedTarget = try trustedPendingURL(
            relativePath: cursor.backupPath,
            allowedRoots: [paths.sessionsRoot, paths.archivedSessionsRoot]
        )
        try RestoreFilesystemValidator.validateSource(source, under: trustedSourceRoot)
        try RestoreFilesystemValidator.validateDestination(expectedTarget, under: paths.backupRoot)
        let targetParent = expectedTarget.deletingLastPathComponent()
        try RestoreFilesystemValidator.validateSource(targetParent, under: paths.backupRoot)

        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              Int64(sourceValues.fileSize ?? -1) >= cursor.lastByteOffset else {
            throw BackupPathsError.unsafeSource(source.path)
        }
        let targetValues: URLResourceValues?
        do {
            targetValues = try expectedTarget.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            targetValues = nil
        }
        if let targetValues {
            try RestoreFilesystemValidator.validateSource(expectedTarget, under: paths.backupRoot)
            guard targetValues.isRegularFile == true, targetValues.isSymbolicLink != true else {
                throw BackupTargetValidationError.unsafeTarget(expectedTarget.path)
            }
        }

        return ValidatedAuditFile(
            cursor: cursor,
            source: source,
            target: expectedTarget,
            targetExists: targetValues != nil,
            targetByteCount: Int64(targetValues?.fileSize ?? 0)
        )
    }

    private func sourceRootIfTrusted(for source: URL) -> URL? {
        let archived = paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        if source.pathComponents.starts(with: archived.standardizedFileURL.pathComponents) {
            return archived
        }
        let sessions = paths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
        if source.pathComponents.starts(with: sessions.standardizedFileURL.pathComponents) {
            return sessions
        }
        return nil
    }

    private func compareCommittedPrefix(
        _ file: ValidatedAuditFile,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> ComparisonResult {
        guard file.targetExists,
              file.targetByteCount == file.cursor.lastByteOffset else { return .mismatch }
        let sourceHandle = try FileHandle(forReadingFrom: file.source)
        let targetHandle = try FileHandle(forReadingFrom: file.target)
        defer {
            try? sourceHandle.close()
            try? targetHandle.close()
        }
        var digest = SHA256()
        var offset: Int64 = 0
        while offset < file.cursor.lastByteOffset {
            guard !interruptionRequested() else { return .interrupted }
            let count = Int(min(Int64(chunkSize), file.cursor.lastByteOffset - offset))
            var iterationResult: ComparisonResult?
            try autoreleasepool {
                let sourceData = try sourceHandle.read(upToCount: count) ?? Data()
                let targetData = try targetHandle.read(upToCount: count) ?? Data()
                instrumentation.didReadChunk(file.source, offset, sourceData.count)
                instrumentation.didStreamChunk(.comparison, file.source, offset, sourceData.count)
                guard !interruptionRequested() else {
                    iterationResult = .interrupted
                    return
                }
                guard sourceData.count == count,
                      targetData.count == count,
                      sourceData == targetData else {
                    iterationResult = .mismatch
                    return
                }
                digest.update(data: sourceData)
                offset += Int64(sourceData.count)
            }
            if let iterationResult { return iterationResult }
        }
        guard !interruptionRequested() else { return .interrupted }
        return .equal(hash: Self.hexDigest(digest.finalize()))
    }

    private func repair(
        _ file: ValidatedAuditFile,
        now: Date,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> RepairResult {
        let revalidated = try validate(
            cursor: file.cursor,
            record: try requiredRecord(file.cursor.sessionId, in: manifest)
        )
        let repairTemporary = revalidated.target.deletingLastPathComponent().appendingPathComponent(
            ".\(revalidated.target.lastPathComponent).repair-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: repairTemporary) }

        let repairHash: String
        let quarantine: QuarantineCopy
        do {
            repairHash = try writeAndVerifyRepairTemporary(
                source: revalidated.source,
                byteCount: revalidated.cursor.lastByteOffset,
                destination: repairTemporary,
                interruptionRequested: interruptionRequested
            )

            if !revalidated.targetExists {
                return try installMissingTarget(
                    revalidated,
                    repairTemporary: repairTemporary,
                    repairHash: repairHash,
                    now: now,
                    manifest: &manifest,
                    manifestStore: manifestStore,
                    state: &state,
                    interruptionRequested: interruptionRequested
                )
            }

            try instrumentation.checkpoint(.beforeQuarantineCopy)
            quarantine = try quarantineCurrentTarget(
                revalidated.target,
                sessionID: revalidated.cursor.sessionId,
                now: now,
                interruptionRequested: interruptionRequested
            )
            try instrumentation.checkpoint(.beforeReplace)
            try verifyFile(
                revalidated.target,
                expectedByteCount: quarantine.byteCount,
                expectedHash: quarantine.hash,
                phase: .formalPreReplacementVerification,
                interruptionRequested: interruptionRequested
            )
            try requireNotInterrupted(interruptionRequested)
        } catch IntegrityAuditControl.interrupted {
            return .interrupted
        }
        guard let quarantineBackupPath = paths.relativeBackupPath(for: quarantine.url) else {
            throw IntegrityAuditError.unsafeCursor(quarantine.url.path)
        }
        var pendingRepair = PendingRepairMetadata(
            phase: .prepared,
            sessionID: revalidated.cursor.sessionId,
            sourcePath: revalidated.cursor.sourcePath,
            backupPath: revalidated.cursor.backupPath,
            byteCount: revalidated.cursor.lastByteOffset,
            contentHash: repairHash,
            originalByteCount: quarantine.byteCount,
            originalContentHash: quarantine.hash,
            quarantineBackupPath: quarantineBackupPath,
            repairedAt: now,
            repairedCount: state.repairedCount + 1
        )
        try savePendingRepairMetadata(pendingRepair)
        try instrumentation.checkpoint(.afterPreparedJournalCommitBeforeFormalReplace)
        if interruptionRequested() {
            try removePendingRepairMetadata()
            return .interrupted
        }

        _ = try fileManager.replaceItemAt(revalidated.target, withItemAt: repairTemporary)
        synchronizeParentDirectory(revalidated.target.deletingLastPathComponent())
        try instrumentation.checkpoint(.afterFormalReplaceBeforeInstalledJournalCommit)

        do {
            try instrumentation.checkpoint(.beforePostReplaceVerification)
            try verifyFile(
                revalidated.target,
                expectedByteCount: revalidated.cursor.lastByteOffset,
                expectedHash: repairHash,
                phase: .installedVerification,
                interruptionRequested: interruptionRequested
            )
        } catch {
            do {
                try restore(quarantine: quarantine, to: revalidated.target)
                try removePendingRepairMetadata()
            } catch {
                throw IntegrityAuditError.restoreFailed(revalidated.target.path)
            }
            if case IntegrityAuditControl.interrupted = error {
                return .interrupted
            }
            throw error
        }

        pendingRepair = pendingRepair.withPhase(.installed)
        try savePendingRepairMetadata(pendingRepair)
        try cleanupQuarantine(now: now, protecting: quarantine.url)
        try instrumentation.checkpoint(.beforeMetadataCommit)
        try commitRepairMetadata(
            pendingRepair,
            manifest: &manifest,
            manifestStore: manifestStore,
            state: &state
        )
        try removePendingRepairMetadata()
        return .repaired(hash: repairHash)
    }

    private func installMissingTarget(
        _ file: ValidatedAuditFile,
        repairTemporary: URL,
        repairHash: String,
        now: Date,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> RepairResult {
        do {
            try requireNotInterrupted(interruptionRequested)
            try RestoreFilesystemValidator.validateDestination(file.target, under: paths.backupRoot)
            try RestoreFilesystemValidator.validateSource(
                file.target.deletingLastPathComponent(),
                under: paths.backupRoot
            )
            do {
                _ = try file.target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                throw BackupTargetValidationError.unsafeTarget(file.target.path)
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                // The missing leaf is the only recoverable target state.
            }
            try instrumentation.checkpoint(.beforeReplace)
            try fileManager.moveItem(at: repairTemporary, to: file.target)
            synchronizeParentDirectory(file.target.deletingLastPathComponent())
            try instrumentation.checkpoint(.afterFormalReplaceBeforeInstalledJournalCommit)
            do {
                try instrumentation.checkpoint(.beforePostReplaceVerification)
                try verifyFile(
                    file.target,
                    expectedByteCount: file.cursor.lastByteOffset,
                    expectedHash: repairHash,
                    phase: .installedVerification,
                    interruptionRequested: interruptionRequested
                )
            } catch {
                try? fileManager.removeItem(at: file.target)
                synchronizeParentDirectory(file.target.deletingLastPathComponent())
                throw error
            }
            try instrumentation.checkpoint(.beforeMetadataCommit)
            try commitRepairMetadata(
                sessionID: file.cursor.sessionId,
                sourcePath: file.cursor.sourcePath,
                backupPath: file.cursor.backupPath,
                byteCount: file.cursor.lastByteOffset,
                contentHash: repairHash,
                repairedAt: now,
                repairedCount: state.repairedCount + 1,
                manifest: &manifest,
                manifestStore: manifestStore,
                state: &state
            )
            return .repaired(hash: repairHash)
        } catch IntegrityAuditControl.interrupted {
            return .interrupted
        }
    }

    private func resolvePendingRepairMetadata(
        _ pendingRepair: PendingRepairMetadata,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState
    ) throws {
        let record = try requiredRecord(pendingRepair.sessionID, in: manifest)
        guard record.sourcePath == pendingRepair.sourcePath,
              record.backupPath == pendingRepair.backupPath else {
            throw IntegrityAuditError.unsafeCursor(pendingRepair.sourcePath)
        }
        let target = try trustedPendingURL(
            relativePath: pendingRepair.backupPath,
            allowedRoots: [paths.sessionsRoot, paths.archivedSessionsRoot]
        )
        let targetState = try pendingTargetState(pendingRepair, target: target)

        switch targetState {
        case .installed:
            let installedRepair = pendingRepair.withPhase(.installed)
            if pendingRepair.phase != .installed {
                try savePendingRepairMetadata(installedRepair)
            }
            try commitRepairMetadata(
                installedRepair,
                manifest: &manifest,
                manifestStore: manifestStore,
                state: &state
            )
        case .original:
            break
        case .unknown:
            let metadataWasAdvanced = try repairMetadataWasAdvanced(
                pendingRepair,
                manifest: manifest
            )
            if pendingRepair.phase == .installed, metadataWasAdvanced {
                try commitRepairMetadata(
                    pendingRepair,
                    manifest: &manifest,
                    manifestStore: manifestStore,
                    state: &state
                )
            } else if !metadataWasAdvanced {
                let quarantineURL = try trustedPendingURL(
                    relativePath: pendingRepair.quarantineBackupPath,
                    allowedRoots: [paths.repairQuarantineRoot]
                )
                try verifyFile(
                    quarantineURL,
                    expectedByteCount: pendingRepair.originalByteCount,
                    expectedHash: pendingRepair.originalContentHash
                )
                try restore(
                    quarantine: QuarantineCopy(
                        url: quarantineURL,
                        byteCount: pendingRepair.originalByteCount,
                        hash: pendingRepair.originalContentHash
                    ),
                    to: target
                )
            }
        }
        try removePendingRepairMetadata()
    }

    private func pendingTargetState(
        _ pendingRepair: PendingRepairMetadata,
        target: URL
    ) throws -> PendingRepairTargetState {
        if try fileMatches(
            target,
            expectedByteCount: pendingRepair.byteCount,
            expectedHash: pendingRepair.contentHash
        ) {
            return .installed
        }
        if try fileMatches(
            target,
            expectedByteCount: pendingRepair.originalByteCount,
            expectedHash: pendingRepair.originalContentHash
        ) {
            return .original
        }
        return .unknown
    }

    private func fileMatches(
        _ url: URL,
        expectedByteCount: Int64,
        expectedHash: String
    ) throws -> Bool {
        try RestoreFilesystemValidator.validateDestination(url, under: paths.backupRoot)
        guard fileManager.fileExists(atPath: url.path) else { return false }
        do {
            try verifyFile(
                url,
                expectedByteCount: expectedByteCount,
                expectedHash: expectedHash
            )
            return true
        } catch IntegrityAuditError.verificationFailed {
            return false
        }
    }

    private func repairMetadataWasAdvanced(
        _ pendingRepair: PendingRepairMetadata,
        manifest: BackupManifest
    ) throws -> Bool {
        guard let record = manifest.sessions[pendingRepair.sessionID] else { return false }
        if record.lastBackedUpAt.map({ $0 > pendingRepair.repairedAt }) == true {
            return true
        }
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        guard let cursor = try cursorStore.cursor(sourcePath: pendingRepair.sourcePath) else {
            return false
        }
        return cursor.updatedAt > pendingRepair.repairedAt.timeIntervalSince1970
    }

    private func trustedPendingURL(
        relativePath: String,
        allowedRoots: [URL]
    ) throws -> URL {
        let candidate = paths.backupRoot.appendingPathComponent(
            relativePath,
            isDirectory: false
        ).standardizedFileURL
        guard paths.relativeBackupPath(for: candidate) == relativePath,
              let containingRoot = allowedRoots.first(where: { root in
                  let rootComponents = root.standardizedFileURL.pathComponents
                  let candidateComponents = candidate.pathComponents
                  return candidateComponents.starts(with: rootComponents)
                      && candidateComponents.count > rootComponents.count
              }) else {
            throw IntegrityAuditError.unsafeCursor(relativePath)
        }
        try RestoreFilesystemValidator.validateDestination(candidate, under: containingRoot)
        return candidate
    }

    private func commitRepairMetadata(
        _ pendingRepair: PendingRepairMetadata,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState
    ) throws {
        try commitRepairMetadata(
            sessionID: pendingRepair.sessionID,
            sourcePath: pendingRepair.sourcePath,
            backupPath: pendingRepair.backupPath,
            byteCount: pendingRepair.byteCount,
            contentHash: pendingRepair.contentHash,
            repairedAt: pendingRepair.repairedAt,
            repairedCount: pendingRepair.repairedCount,
            manifest: &manifest,
            manifestStore: manifestStore,
            state: &state
        )
    }

    private func commitRepairMetadata(
        sessionID: String,
        sourcePath: String,
        backupPath: String,
        byteCount: Int64,
        contentHash: String,
        repairedAt: Date,
        repairedCount: Int,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState
    ) throws {
        var repairedRecord = try requiredRecord(sessionID, in: manifest)
        guard repairedRecord.sourcePath == sourcePath,
              repairedRecord.backupPath == backupPath else {
            throw IntegrityAuditError.unsafeCursor(sourcePath)
        }
        let recordWasNotAdvanced = repairedRecord.bytesBackedUp == byteCount
            && repairedRecord.lastBackedUpAt.map { $0 <= repairedAt } != false
        if recordWasNotAdvanced {
            repairedRecord.contentHash = contentHash
            repairedRecord.lastBackedUpAt = repairedAt
        }
        manifest.sessions[sessionID] = repairedRecord
        manifest.updatedAt = max(manifest.updatedAt, repairedAt)
        try manifestStore.save(manifest)
        try instrumentation.checkpoint(.afterManifestCommit)

        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        guard var repairedCursor = try cursorStore.cursor(sourcePath: sourcePath),
              repairedCursor.sessionId == sessionID,
              repairedCursor.backupPath == backupPath else {
            throw IntegrityAuditError.unsafeCursor(sourcePath)
        }
        if repairedCursor.lastByteOffset == byteCount,
           repairedCursor.updatedAt <= repairedAt.timeIntervalSince1970 {
            repairedCursor.updatedAt = repairedAt.timeIntervalSince1970
            repairedCursor.lastError = nil
        }
        try cursorStore.upsert(repairedCursor)
        try instrumentation.checkpoint(.afterCursorCommit)

        state.repairedCount = max(state.repairedCount, repairedCount)
        state.lastResult = "repaired"
        try saveAuditState(state)
        try instrumentation.checkpoint(.afterAuditStateCommit)
        try updatePersistedStatus(
            lastAuditAt: nil,
            lastAuditResult: nil,
            lastRepairAt: repairedAt,
            repairCount: state.repairedCount
        )
        try instrumentation.checkpoint(.afterRuntimeStatusCommit)
    }

    private func requiredRecord(
        _ sessionID: String,
        in manifest: BackupManifest
    ) throws -> BackupSessionRecord {
        guard let record = manifest.sessions[sessionID] else {
            throw IntegrityAuditError.missingManifestRecord(sessionID)
        }
        return record
    }

    private func writeValidatedRepairTemporary(
        source: URL,
        byteCount: Int64,
        destination: URL,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> String {
        let sourceHandle = try FileHandle(forReadingFrom: source)
        defer { try? sourceHandle.close() }
        var digest = SHA256()
        var remaining = byteCount
        var pendingLine = Data()
        let writer = DurableAtomicWriter(
            fileManager: fileManager,
            synchronize: { handle in
                try instrumentation.checkpoint(.beforeTemporaryFlush)
                try synchronize(handle)
            }
        )
        try writer.replace(at: destination, createParentDirectories: false) { destinationHandle in
            var bufferedWriter = BufferedBackupWriter { chunk in
                try destinationHandle.write(contentsOf: chunk)
                instrumentation.didWriteChunk(.repairTemporary, destination, chunk.count)
            }
            var offset: Int64 = 0
            while remaining > 0 {
                try autoreleasepool {
                    try requireNotInterrupted(interruptionRequested)
                    let count = Int(min(Int64(chunkSize), remaining))
                    guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                        throw IntegrityAuditError.invalidCommittedSource(source.path)
                    }
                    try validateJSONLChunk(chunk, pendingLine: &pendingLine, source: source)
                    try bufferedWriter.append(chunk)
                    digest.update(data: chunk)
                    instrumentation.didStreamChunk(.repairTemporary, source, offset, chunk.count)
                    remaining -= Int64(chunk.count)
                    offset += Int64(chunk.count)
                    try requireNotInterrupted(interruptionRequested)
                }
            }
            guard pendingLine.isEmpty else {
                throw IntegrityAuditError.invalidCommittedSource(source.path)
            }
            try bufferedWriter.flush()
        }
        return Self.hexDigest(digest.finalize())
    }

    private func writeAndVerifyRepairTemporary(
        source: URL,
        byteCount: Int64,
        destination: URL,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> String {
        for attempt in 0..<2 {
            let hash = try writeValidatedRepairTemporary(
                source: source,
                byteCount: byteCount,
                destination: destination,
                interruptionRequested: interruptionRequested
            )
            do {
                try verifyFile(
                    destination,
                    expectedByteCount: byteCount,
                    expectedHash: hash,
                    phase: .repairTemporaryVerification,
                    interruptionRequested: interruptionRequested
                )
                return hash
            } catch IntegrityAuditControl.interrupted {
                throw IntegrityAuditControl.interrupted
            } catch {
                try? fileManager.removeItem(at: destination)
                if attempt == 1 { throw error }
            }
        }
        throw IntegrityAuditError.verificationFailed(destination.path)
    }

    private func validateJSONLChunk(
        _ chunk: Data,
        pendingLine: inout Data,
        source: URL
    ) throws {
        var lineStart = chunk.startIndex
        for newlineIndex in chunk.indices where chunk[newlineIndex] == 0x0A {
            if lineStart < newlineIndex {
                pendingLine.append(contentsOf: chunk[lineStart..<newlineIndex])
            }
            guard pendingLine.count <= SessionTailer.defaultMaxLineBytes else {
                throw IntegrityAuditError.invalidCommittedSource(source.path)
            }
            let isValidJSONObject = autoreleasepool {
                guard let object = try? JSONSerialization.jsonObject(with: pendingLine) else {
                    return false
                }
                return object is [String: Any]
            }
            guard isValidJSONObject else {
                throw IntegrityAuditError.invalidCommittedSource(source.path)
            }
            pendingLine.removeAll(keepingCapacity: true)
            lineStart = chunk.index(after: newlineIndex)
        }
        if lineStart < chunk.endIndex {
            pendingLine.append(contentsOf: chunk[lineStart..<chunk.endIndex])
            guard pendingLine.count <= SessionTailer.defaultMaxLineBytes else {
                throw IntegrityAuditError.invalidCommittedSource(source.path)
            }
        }
    }

    private func quarantineCurrentTarget(
        _ target: URL,
        sessionID: String,
        now: Date,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> QuarantineCopy {
        try ensureTrustedDirectory(paths.repairQuarantineRoot, under: paths.backupRoot)
        let safeSessionID = Self.safePathComponent(sessionID)
        let sessionRoot = paths.repairQuarantineRoot.appendingPathComponent(safeSessionID, isDirectory: true)
        try ensureTrustedDirectory(sessionRoot, under: paths.repairQuarantineRoot)
        let quarantineURL = sessionRoot.appendingPathComponent(
            "repair-\(safeSessionID)-\(Int64(now.timeIntervalSince1970))-\(UUID().uuidString.lowercased()).jsonl",
            isDirectory: false
        )
        let sourceValues = try target.resourceValues(forKeys: [.fileSizeKey])
        let byteCount = Int64(sourceValues.fileSize ?? -1)
        guard byteCount >= 0 else { throw BackupTargetValidationError.unsafeTarget(target.path) }

        let sourceHandle = try FileHandle(forReadingFrom: target)
        defer { try? sourceHandle.close() }
        var digest = SHA256()
        var remaining = byteCount
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).replace(
            at: quarantineURL,
            createParentDirectories: false
        ) { handle in
            var offset: Int64 = 0
            while remaining > 0 {
                try autoreleasepool {
                    try requireNotInterrupted(interruptionRequested)
                    let count = Int(min(Int64(chunkSize), remaining))
                    guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                        throw IntegrityAuditError.verificationFailed(target.path)
                    }
                    try handle.write(contentsOf: chunk)
                    digest.update(data: chunk)
                    instrumentation.didStreamChunk(.quarantineCopy, target, offset, chunk.count)
                    remaining -= Int64(chunk.count)
                    offset += Int64(chunk.count)
                    try requireNotInterrupted(interruptionRequested)
                }
            }
        }
        let hash = Self.hexDigest(digest.finalize())
        let verification = Result<Void, Error> {
            try verifyFile(
                quarantineURL,
                expectedByteCount: byteCount,
                expectedHash: hash,
                phase: .quarantineVerification,
                interruptionRequested: interruptionRequested
            )
        }
        try cleanupQuarantine(now: now, protecting: quarantineURL)
        try verification.get()
        return QuarantineCopy(url: quarantineURL, byteCount: byteCount, hash: hash)
    }

    private func restore(quarantine: QuarantineCopy, to target: URL) throws {
        let sourceHandle = try FileHandle(forReadingFrom: quarantine.url)
        defer { try? sourceHandle.close() }
        var remaining = quarantine.byteCount
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).replace(
            at: target,
            createParentDirectories: false
        ) { handle in
            while remaining > 0 {
                try autoreleasepool {
                    let count = Int(min(Int64(chunkSize), remaining))
                    guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                        throw IntegrityAuditError.restoreFailed(target.path)
                    }
                    try handle.write(contentsOf: chunk)
                    remaining -= Int64(chunk.count)
                }
            }
        }
        try verifyFile(target, expectedByteCount: quarantine.byteCount, expectedHash: quarantine.hash)
    }

    private func verifyFile(
        _ url: URL,
        expectedByteCount: Int64,
        expectedHash: String,
        phase: IntegrityAuditStreamPhase? = nil,
        interruptionRequested: @Sendable () -> Bool = { false }
    ) throws {
        try RestoreFilesystemValidator.validateSource(url, under: validationRoot(for: url))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedByteCount,
              try hashFile(
                url,
                byteCount: expectedByteCount,
                phase: phase,
                interruptionRequested: interruptionRequested
              ) == expectedHash else {
            throw IntegrityAuditError.verificationFailed(url.path)
        }
    }

    private func validationRoot(for url: URL) -> URL {
        if url.pathComponents.starts(with: paths.backupRoot.standardizedFileURL.pathComponents) {
            return paths.backupRoot
        }
        return url.deletingLastPathComponent()
    }

    private func hashFile(
        _ url: URL,
        byteCount: Int64,
        phase: IntegrityAuditStreamPhase?,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var remaining = byteCount
        var offset: Int64 = 0
        while remaining > 0 {
            try autoreleasepool {
                try requireNotInterrupted(interruptionRequested)
                let count = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                    throw IntegrityAuditError.verificationFailed(url.path)
                }
                digest.update(data: chunk)
                if let phase { instrumentation.didStreamChunk(phase, url, offset, chunk.count) }
                remaining -= Int64(chunk.count)
                offset += Int64(chunk.count)
                try requireNotInterrupted(interruptionRequested)
            }
        }
        return Self.hexDigest(digest.finalize())
    }

    private func requireNotInterrupted(_ interruptionRequested: @Sendable () -> Bool) throws {
        if interruptionRequested() { throw IntegrityAuditControl.interrupted }
    }

    private func ensureTrustedDirectory(_ directory: URL, under root: URL) throws {
        try RestoreFilesystemValidator.validateDestination(directory, under: root)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            synchronizeParentDirectory(directory.deletingLastPathComponent())
        }
        try RestoreFilesystemValidator.validateSource(directory, under: root)
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw BackupTargetValidationError.unsafeTarget(directory.path)
        }
    }

    private func cleanupQuarantine(now: Date, protecting protectedURL: URL? = nil) throws {
        guard fileManager.fileExists(atPath: paths.repairQuarantineRoot.path) else { return }
        try RestoreFilesystemValidator.validateSource(paths.repairQuarantineRoot, under: paths.backupRoot)
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: paths.repairQuarantineRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        for sessionDirectory in sessionDirectories {
            let directoryValues = try sessionDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directoryValues.isDirectory == true, directoryValues.isSymbolicLink != true else { continue }
            let safeSessionID = sessionDirectory.lastPathComponent
            let prefix = "repair-\(safeSessionID)-"
            let entries = try fileManager.contentsOfDirectory(
                at: sessionDirectory,
                includingPropertiesForKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ]
            )
            let owned = try entries.compactMap { entry -> OwnedQuarantineCopy? in
                let values = try entry.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .contentModificationDateKey
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      entry.pathExtension.lowercased() == "jsonl",
                      Self.isOwnedQuarantineFilename(entry, prefix: prefix),
                      let modifiedAt = values.contentModificationDate else {
                    return nil
                }
                return OwnedQuarantineCopy(url: entry, modifiedAt: modifiedAt)
            }.sorted { lhs, rhs in
                if lhs.url == protectedURL { return true }
                if rhs.url == protectedURL { return false }
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.url.path > rhs.url.path
            }

            for (index, copy) in owned.enumerated() where
                copy.url != protectedURL
                && (index >= Self.maximumQuarantineCopiesPerSession
                    || now.timeIntervalSince(copy.modifiedAt) > Self.retentionInterval) {
                try fileManager.removeItem(at: copy.url)
            }
        }
    }

    private func loadAuditState() throws -> IntegrityAuditState {
        guard fileManager.fileExists(atPath: paths.auditStateURL.path) else {
            return IntegrityAuditState(lastCompletedAt: nil, lastResult: nil, repairedCount: 0)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            IntegrityAuditState.self,
            from: Data(contentsOf: paths.auditStateURL)
        )
    }

    private func saveAuditState(_ state: IntegrityAuditState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
            try encoder.encode(state),
            to: paths.auditStateURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
    }

    private var pendingRepairMetadataURL: URL {
        paths.auditStateURL.deletingLastPathComponent().appendingPathComponent(
            "integrity-repair-pending.json",
            isDirectory: false
        )
    }

    private func loadPendingRepairMetadata() throws -> PendingRepairMetadata? {
        guard fileManager.fileExists(atPath: pendingRepairMetadataURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pending = try decoder.decode(
            PendingRepairMetadata.self,
            from: Data(contentsOf: pendingRepairMetadataURL)
        )
        guard pending.version == PendingRepairMetadata.currentVersion,
              pending.byteCount >= 0,
              pending.originalByteCount >= 0,
              Self.isSHA256(pending.contentHash),
              Self.isSHA256(pending.originalContentHash),
              pending.repairedCount > 0 else {
            throw IntegrityAuditError.unsafeCursor(pending.sourcePath)
        }
        return pending
    }

    private func savePendingRepairMetadata(_ pendingRepair: PendingRepairMetadata) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let writer = DurableAtomicWriter(fileManager: fileManager, synchronize: { handle in
            if pendingRepair.phase == .prepared {
                try instrumentation.checkpoint(.beforePreparedRepairJournalFlush)
            }
            try synchronize(handle)
        })
        try writer.write(
            try encoder.encode(pendingRepair),
            to: pendingRepairMetadataURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
    }

    private func removePendingRepairMetadata() throws {
        guard fileManager.fileExists(atPath: pendingRepairMetadataURL.path) else { return }
        try fileManager.removeItem(at: pendingRepairMetadataURL)
        synchronizeParentDirectory(pendingRepairMetadataURL.deletingLastPathComponent())
    }

    private func updatePersistedStatus(
        lastAuditAt: Date?,
        lastAuditResult: String?,
        lastRepairAt: Date?,
        repairCount: Int
    ) throws {
        guard fileManager.fileExists(atPath: paths.localStatusURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var status = try decoder.decode(
            BackupStatus.self,
            from: Data(contentsOf: paths.localStatusURL)
        )
        if let lastAuditAt { status.lastAuditAt = lastAuditAt }
        if let lastAuditResult { status.lastAuditResult = lastAuditResult }
        if let lastRepairAt {
            status.lastRepairAt = max(status.lastRepairAt ?? lastRepairAt, lastRepairAt)
        }
        status.repairCount = max(status.repairCount ?? 0, repairCount)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
            data,
            to: paths.localStatusURL,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700,
            createParentDirectories: true
        )
        if fileManager.fileExists(atPath: paths.remoteStatusURL.path) {
            try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
                data,
                to: paths.remoteStatusURL,
                createParentDirectories: false
            )
        }
    }

    private func synchronizeParentDirectory(_ directory: URL) {
        guard let handle = try? FileHandle(forReadingFrom: directory) else { return }
        defer { try? handle.close() }
        try? handle.synchronize()
    }

    private static func safePathComponent(_ value: String) -> String {
        let filtered = value.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "-" || character == "_")
                ? character
                : "-"
        }
        let result = String(filtered).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "session" : result
    }

    private static func isOwnedQuarantineFilename(_ url: URL, prefix: String) -> Bool {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(prefix) else { return false }
        let suffix = stem.dropFirst(prefix.count)
        guard suffix.count > 37 else { return false }
        let uuidStart = suffix.index(suffix.endIndex, offsetBy: -36)
        guard suffix[suffix.index(before: uuidStart)] == "-",
              UUID(uuidString: String(suffix[uuidStart...])) != nil else {
            return false
        }
        return Int64(suffix[..<suffix.index(before: uuidStart)]) != nil
    }

    private static func hexDigest<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == 64 && bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
        }
    }
}

private struct ValidatedAuditFile {
    let cursor: BackupCursor
    let source: URL
    let target: URL
    let targetExists: Bool
    let targetByteCount: Int64
}

private enum ComparisonResult {
    case equal(hash: String)
    case mismatch
    case interrupted
}

private enum RepairResult {
    case repaired(hash: String)
    case interrupted
}

private enum IntegrityAuditControl: Error {
    case interrupted
}

private enum PendingRepairTargetState {
    case installed
    case original
    case unknown
}

private enum PendingRepairPhase: String, Codable {
    case prepared
    case installed
}

private struct PendingRepairMetadata: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let phase: PendingRepairPhase
    let sessionID: String
    let sourcePath: String
    let backupPath: String
    let byteCount: Int64
    let contentHash: String
    let originalByteCount: Int64
    let originalContentHash: String
    let quarantineBackupPath: String
    let repairedAt: Date
    let repairedCount: Int

    init(
        phase: PendingRepairPhase,
        sessionID: String,
        sourcePath: String,
        backupPath: String,
        byteCount: Int64,
        contentHash: String,
        originalByteCount: Int64,
        originalContentHash: String,
        quarantineBackupPath: String,
        repairedAt: Date,
        repairedCount: Int
    ) {
        version = Self.currentVersion
        self.phase = phase
        self.sessionID = sessionID
        self.sourcePath = sourcePath
        self.backupPath = backupPath
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.originalByteCount = originalByteCount
        self.originalContentHash = originalContentHash
        self.quarantineBackupPath = quarantineBackupPath
        self.repairedAt = repairedAt
        self.repairedCount = repairedCount
    }

    func withPhase(_ phase: PendingRepairPhase) -> PendingRepairMetadata {
        PendingRepairMetadata(
            phase: phase,
            sessionID: sessionID,
            sourcePath: sourcePath,
            backupPath: backupPath,
            byteCount: byteCount,
            contentHash: contentHash,
            originalByteCount: originalByteCount,
            originalContentHash: originalContentHash,
            quarantineBackupPath: quarantineBackupPath,
            repairedAt: repairedAt,
            repairedCount: repairedCount
        )
    }
}

private struct QuarantineCopy {
    let url: URL
    let byteCount: Int64
    let hash: String
}

private struct OwnedQuarantineCopy {
    let url: URL
    let modifiedAt: Date
}
