import CryptoKit
import Foundation

enum IntegrityAuditCheckpoint: Equatable, Sendable {
    case beforeTemporaryFlush
    case beforeQuarantineCopy
    case beforeReplace
    case beforePostReplaceVerification
    case beforeMetadataCommit
}

struct IntegrityAuditInstrumentation: @unchecked Sendable {
    let didReadChunk: @Sendable (URL, Int64, Int) -> Void
    let checkpoint: @Sendable (IntegrityAuditCheckpoint) throws -> Void

    init(
        didReadChunk: @escaping @Sendable (URL, Int64, Int) -> Void = { _, _, _ in },
        checkpoint: @escaping @Sendable (IntegrityAuditCheckpoint) throws -> Void = { _ in }
    ) {
        self.didReadChunk = didReadChunk
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
        if let lastCompletedAt = state.lastCompletedAt,
           now.timeIntervalSince(lastCompletedAt) < Self.auditInterval {
            return .notDue
        }

        try BackupTargetValidator(backupRoot: paths.backupRoot, fileManager: fileManager).validateTarget()
        let manifestStore = BackupManifestStore(
            manifestURL: paths.manifestURL,
            createParentDirectories: false
        )
        var manifest = try manifestStore.loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            now: now
        )
        var bufferedHashes: [String: String] = [:]
        var checked = 0
        var repaired = 0

        for cursor in cursors.values.sorted(by: Self.cursorOrder) {
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
                let hash = try repair(
                    validated,
                    now: now,
                    manifest: &manifest,
                    manifestStore: manifestStore,
                    state: &state
                )
                bufferedHashes.removeValue(forKey: cursor.sessionId)
                if manifest.sessions[cursor.sessionId]?.contentHash != hash {
                    throw IntegrityAuditError.verificationFailed(validated.target.path)
                }
                repaired += 1
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

    func recordInitialSeedCompleted(at date: Date) throws {
        var state = try loadAuditState()
        guard state.lastCompletedAt == nil else { return }
        state.lastCompletedAt = date
        state.lastResult = "seeded"
        try saveAuditState(state)
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
        let expectedTarget = try paths.backupFileURL(for: source).standardizedFileURL
        guard paths.relativeBackupPath(for: expectedTarget) == cursor.backupPath else {
            throw IntegrityAuditError.unsafeCursor(cursor.backupPath)
        }
        try RestoreFilesystemValidator.validateSource(source, under: sourceRoot(for: source))
        try RestoreFilesystemValidator.validateSource(expectedTarget, under: paths.backupRoot)

        let sourceValues = try source.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        let targetValues = try expectedTarget.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ])
        guard sourceValues.isRegularFile == true,
              sourceValues.isSymbolicLink != true,
              Int64(sourceValues.fileSize ?? -1) >= cursor.lastByteOffset else {
            throw BackupPathsError.unsafeSource(source.path)
        }
        guard targetValues.isRegularFile == true, targetValues.isSymbolicLink != true else {
            throw BackupTargetValidationError.unsafeTarget(expectedTarget.path)
        }

        return ValidatedAuditFile(
            cursor: cursor,
            source: source,
            target: expectedTarget,
            targetByteCount: Int64(targetValues.fileSize ?? -1)
        )
    }

    private func sourceRoot(for source: URL) -> URL {
        let archived = paths.codexRoot.appendingPathComponent("archived_sessions", isDirectory: true)
        if source.pathComponents.starts(with: archived.standardizedFileURL.pathComponents) {
            return archived
        }
        return paths.codexRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    private func compareCommittedPrefix(
        _ file: ValidatedAuditFile,
        interruptionRequested: @Sendable () -> Bool
    ) throws -> ComparisonResult {
        guard file.targetByteCount == file.cursor.lastByteOffset else { return .mismatch }
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
            let sourceData = try sourceHandle.read(upToCount: count) ?? Data()
            let targetData = try targetHandle.read(upToCount: count) ?? Data()
            instrumentation.didReadChunk(file.source, offset, sourceData.count)
            guard sourceData.count == count, targetData.count == count else { return .mismatch }
            guard sourceData == targetData else { return .mismatch }
            digest.update(data: sourceData)
            offset += Int64(sourceData.count)
        }
        guard !interruptionRequested() else { return .interrupted }
        return .equal(hash: Self.hexDigest(digest.finalize()))
    }

    private func repair(
        _ file: ValidatedAuditFile,
        now: Date,
        manifest: inout BackupManifest,
        manifestStore: BackupManifestStore,
        state: inout IntegrityAuditState
    ) throws -> String {
        let revalidated = try validate(
            cursor: file.cursor,
            record: try requiredRecord(file.cursor.sessionId, in: manifest)
        )
        let repairTemporary = revalidated.target.deletingLastPathComponent().appendingPathComponent(
            ".\(revalidated.target.lastPathComponent).repair-\(UUID().uuidString)",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: repairTemporary) }

        let repairHash = try writeValidatedRepairTemporary(
            source: revalidated.source,
            byteCount: revalidated.cursor.lastByteOffset,
            destination: repairTemporary
        )
        try verifyFile(
            repairTemporary,
            expectedByteCount: revalidated.cursor.lastByteOffset,
            expectedHash: repairHash
        )

        try instrumentation.checkpoint(.beforeQuarantineCopy)
        let quarantine = try quarantineCurrentTarget(
            revalidated.target,
            sessionID: revalidated.cursor.sessionId,
            now: now
        )
        try instrumentation.checkpoint(.beforeReplace)
        try verifyFile(
            revalidated.target,
            expectedByteCount: quarantine.byteCount,
            expectedHash: quarantine.hash
        )
        _ = try fileManager.replaceItemAt(revalidated.target, withItemAt: repairTemporary)
        synchronizeParentDirectory(revalidated.target.deletingLastPathComponent())

        do {
            try instrumentation.checkpoint(.beforePostReplaceVerification)
            try verifyFile(
                revalidated.target,
                expectedByteCount: revalidated.cursor.lastByteOffset,
                expectedHash: repairHash
            )
        } catch {
            do {
                try restore(quarantine: quarantine, to: revalidated.target)
            } catch {
                throw IntegrityAuditError.restoreFailed(revalidated.target.path)
            }
            throw error
        }

        try instrumentation.checkpoint(.beforeMetadataCommit)
        var repairedRecord = try requiredRecord(revalidated.cursor.sessionId, in: manifest)
        repairedRecord.contentHash = repairHash
        repairedRecord.lastBackedUpAt = now
        manifest.sessions[revalidated.cursor.sessionId] = repairedRecord
        manifest.updatedAt = now
        try manifestStore.save(manifest)

        var repairedCursor = revalidated.cursor
        repairedCursor.updatedAt = now.timeIntervalSince1970
        repairedCursor.lastError = nil
        let cursorStore = BackupCursorStore(databaseURL: paths.cursorDatabaseURL)
        try cursorStore.open()
        try cursorStore.upsert(repairedCursor)

        state.repairedCount += 1
        state.lastResult = "repaired"
        try saveAuditState(state)
        try updatePersistedStatus(
            lastAuditAt: nil,
            lastAuditResult: nil,
            lastRepairAt: now,
            repairCount: state.repairedCount
        )
        return repairHash
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
        destination: URL
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
            while remaining > 0 {
                let count = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                    throw IntegrityAuditError.invalidCommittedSource(source.path)
                }
                try validateJSONLChunk(chunk, pendingLine: &pendingLine, source: source)
                try destinationHandle.write(contentsOf: chunk)
                digest.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
            guard pendingLine.isEmpty else {
                throw IntegrityAuditError.invalidCommittedSource(source.path)
            }
        }
        return Self.hexDigest(digest.finalize())
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
            guard pendingLine.count <= SessionTailer.defaultMaxLineBytes,
                  let object = try? JSONSerialization.jsonObject(with: pendingLine),
                  object is [String: Any] else {
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
        now: Date
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
            while remaining > 0 {
                let count = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                    throw IntegrityAuditError.verificationFailed(target.path)
                }
                try handle.write(contentsOf: chunk)
                digest.update(data: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        let hash = Self.hexDigest(digest.finalize())
        try verifyFile(quarantineURL, expectedByteCount: byteCount, expectedHash: hash)
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
                let count = Int(min(Int64(chunkSize), remaining))
                guard let chunk = try sourceHandle.read(upToCount: count), chunk.count == count else {
                    throw IntegrityAuditError.restoreFailed(target.path)
                }
                try handle.write(contentsOf: chunk)
                remaining -= Int64(chunk.count)
            }
        }
        try verifyFile(target, expectedByteCount: quarantine.byteCount, expectedHash: quarantine.hash)
    }

    private func verifyFile(
        _ url: URL,
        expectedByteCount: Int64,
        expectedHash: String
    ) throws {
        try RestoreFilesystemValidator.validateSource(url, under: validationRoot(for: url))
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? -1) == expectedByteCount,
              try hashFile(url, byteCount: expectedByteCount) == expectedHash else {
            throw IntegrityAuditError.verificationFailed(url.path)
        }
    }

    private func validationRoot(for url: URL) -> URL {
        if url.pathComponents.starts(with: paths.backupRoot.standardizedFileURL.pathComponents) {
            return paths.backupRoot
        }
        return url.deletingLastPathComponent()
    }

    private func hashFile(_ url: URL, byteCount: Int64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            let count = Int(min(Int64(chunkSize), remaining))
            guard let chunk = try handle.read(upToCount: count), chunk.count == count else {
                throw IntegrityAuditError.verificationFailed(url.path)
            }
            digest.update(data: chunk)
            remaining -= Int64(chunk.count)
        }
        return Self.hexDigest(digest.finalize())
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

    private func cleanupQuarantine(now: Date) throws {
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
            }.sorted { $0.modifiedAt > $1.modifiedAt }

            for (index, copy) in owned.enumerated() where
                index >= Self.maximumQuarantineCopiesPerSession
                || now.timeIntervalSince(copy.modifiedAt) > Self.retentionInterval {
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
            createParentDirectories: true
        )
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
        if let lastRepairAt { status.lastRepairAt = lastRepairAt }
        status.repairCount = repairCount

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(status)
        try DurableAtomicWriter(fileManager: fileManager, synchronize: synchronize).write(
            data,
            to: paths.localStatusURL,
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
}

private struct ValidatedAuditFile {
    let cursor: BackupCursor
    let source: URL
    let target: URL
    let targetByteCount: Int64
}

private enum ComparisonResult {
    case equal(hash: String)
    case mismatch
    case interrupted
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
