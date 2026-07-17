import Foundation

public struct IncrementalRecoveryItem: Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let sourceURL: URL
    public let backupPath: String
    public let recoveredFilename: String
    public let updatedAt: Date
    public let expectedVerification: IncrementalRecoveryVerificationExpectation
}

public struct IncrementalRecoveryVerificationExpectation: Equatable, Sendable {
    public let byteCount: Int64
    public let lineCount: Int
    public let contentHash: String
    public let chunkSize: Int
    public let chunkHashes: [String]?
}

public struct IncrementalRecoveryPlan: Equatable, Sendable {
    public let items: [IncrementalRecoveryItem]
    public let skippedExistingSessionIDs: [String]

    public init(items: [IncrementalRecoveryItem], skippedExistingSessionIDs: [String]) {
        self.items = items
        self.skippedExistingSessionIDs = skippedExistingSessionIDs
    }
}

public struct IncrementalRecoveryThreadRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let title: String
    public let rolloutPath: String
    public let updatedAt: Date

    public init(sessionID: String, title: String, rolloutPath: String, updatedAt: Date) {
        self.sessionID = sessionID
        self.title = title
        self.rolloutPath = rolloutPath
        self.updatedAt = updatedAt
    }
}

public struct IncrementalRecoveryResult: Equatable, Sendable {
    public let restoredSessionIDs: [String]
    public let skippedExistingSessionIDs: [String]
    public let threadRecords: [IncrementalRecoveryThreadRecord]

    public init(
        restoredSessionIDs: [String],
        skippedExistingSessionIDs: [String],
        threadRecords: [IncrementalRecoveryThreadRecord]
    ) {
        self.restoredSessionIDs = restoredSessionIDs
        self.skippedExistingSessionIDs = skippedExistingSessionIDs
        self.threadRecords = threadRecords
    }
}

public enum IncrementalRecoveryError: Error, LocalizedError, Equatable, Sendable {
    case noSelectedSessions
    case sessionNotFound(String)
    case sourceChanged(String)
    case unverifiedBackup(String)

    public var errorDescription: String? {
        switch self {
        case .noSelectedSessions:
            return "没有可恢复的 NAS 会话。"
        case let .sessionNotFound(sessionID):
            return "NAS 备份清单中找不到会话：\(sessionID)"
        case let .sourceChanged(sessionID):
            return "NAS 会话备份在预检后发生变化：\(sessionID)"
        case let .unverifiedBackup(sessionID):
            return "NAS 会话备份未通过完整校验，已拒绝恢复：\(sessionID)"
        }
    }
}

public final class IncrementalRecoveryRestorer {
    private let paths: BackupPaths
    private let fileManager: FileManager
    private let writer: DurableAtomicWriter

    public init(
        paths: BackupPaths,
        fileManager: FileManager = .default,
        writer: DurableAtomicWriter = DurableAtomicWriter()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.writer = writer
    }

    public func preflight(
        sessionIDs: [String],
        currentSessionIDs: Set<String>
    ) throws -> IncrementalRecoveryPlan {
        let requested = Array(Set(sessionIDs)).sorted()
        guard !requested.isEmpty else { throw IncrementalRecoveryError.noSelectedSessions }
        let manifest = try loadManifest()
        let verification = try BackupVerificationStore(
            fileURL: paths.verificationURL,
            createParentDirectories: false,
            fileManager: fileManager
        ).load()
        let catalog = IncrementalBackupCatalog(paths: paths, fileManager: fileManager)
        var items: [IncrementalRecoveryItem] = []
        var skipped: [String] = []
        var usedFilenames = Set<String>()
        for sessionID in requested {
            guard let record = manifest.sessions[sessionID] else {
                throw IncrementalRecoveryError.sessionNotFound(sessionID)
            }
            if currentSessionIDs.contains(sessionID) {
                skipped.append(sessionID)
                continue
            }
            let sourceURL = try catalog.validatedBackupFileURL(for: record)
            let expectedVerification = try validateBackup(
                sourceURL,
                sessionID: sessionID,
                record: record,
                verification: verification
            )
            let title = displayTitle(for: record)
            items.append(IncrementalRecoveryItem(
                sessionID: sessionID,
                title: title,
                sourceURL: sourceURL,
                backupPath: record.backupPath,
                recoveredFilename: uniqueFilename(for: sessionID, used: &usedFilenames),
                updatedAt: record.lastBackedUpAt ?? record.firstSeenAt,
                expectedVerification: expectedVerification
            ))
        }
        return IncrementalRecoveryPlan(items: items, skippedExistingSessionIDs: skipped)
    }

    public func restore(
        _ plan: IncrementalRecoveryPlan,
        to codexRoot: URL
    ) throws -> IncrementalRecoveryResult {
        let manifest = try loadManifest()
        let catalog = IncrementalBackupCatalog(paths: paths, fileManager: fileManager)
        let recoveredRoot = codexRoot.appendingPathComponent("sessions/recovered", isDirectory: true)
        try RestoreFilesystemValidator.validateDestination(recoveredRoot, under: codexRoot)

        var prepared: [(item: IncrementalRecoveryItem, source: URL, destination: URL)] = []
        var skipped = Set(plan.skippedExistingSessionIDs)
        for item in plan.items {
            guard let record = manifest.sessions[item.sessionID], record.backupPath == item.backupPath else {
                throw IncrementalRecoveryError.sourceChanged(item.sessionID)
            }
            let source = try catalog.validatedBackupFileURL(for: record)
            guard source.standardizedFileURL == item.sourceURL.standardizedFileURL else {
                throw IncrementalRecoveryError.sourceChanged(item.sessionID)
            }
            try RestoreFilesystemValidator.validateSource(source, under: paths.backupRoot)
            let destination = recoveredRoot.appendingPathComponent(item.recoveredFilename)
            try RestoreFilesystemValidator.validateDestination(destination, under: codexRoot)
            if fileManager.fileExists(atPath: destination.path) {
                skipped.insert(item.sessionID)
            } else {
                prepared.append((item, source, destination))
            }
        }

        guard !prepared.isEmpty else {
            return IncrementalRecoveryResult(
                restoredSessionIDs: [],
                skippedExistingSessionIDs: skipped.sorted(),
                threadRecords: []
            )
        }

        let trustedRecoveredRoot = try SecureRecoveryDirectoryCreator.createRecoveredDirectory(
            under: codexRoot,
            fileManager: fileManager
        )
        guard trustedRecoveredRoot.standardizedFileURL == recoveredRoot.standardizedFileURL else {
            throw RestoreFilesystemValidationError.unsafePath(recoveredRoot.path)
        }
        let stagingRoot = recoveredRoot.appendingPathComponent(
            ".recovery-staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try RestoreFilesystemValidator.validateDestination(stagingRoot, under: codexRoot)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: stagingRoot) }

        var staged: [(entry: (item: IncrementalRecoveryItem, source: URL, destination: URL), url: URL)] = []
        for entry in prepared {
            let stagingURL = stagingRoot.appendingPathComponent(entry.item.recoveredFilename)
            try stageAndVerify(entry: entry, at: stagingURL)
            staged.append((entry, stagingURL))
        }

        var restored: [String] = []
        var threadRecords: [IncrementalRecoveryThreadRecord] = []
        var published: [URL] = []
        do {
            for stagedEntry in staged {
                let entry = stagedEntry.entry
                if fileManager.fileExists(atPath: entry.destination.path) {
                    skipped.insert(entry.item.sessionID)
                    continue
                }
                do {
                    try fileManager.moveItem(at: stagedEntry.url, to: entry.destination)
                } catch {
                    if fileManager.fileExists(atPath: entry.destination.path) {
                        skipped.insert(entry.item.sessionID)
                        continue
                    }
                    throw error
                }
                published.append(entry.destination)
                restored.append(entry.item.sessionID)
                threadRecords.append(IncrementalRecoveryThreadRecord(
                    sessionID: entry.item.sessionID,
                    title: entry.item.title,
                    rolloutPath: entry.destination.path,
                    updatedAt: entry.item.updatedAt
                ))
            }

            if !threadRecords.isEmpty {
                try mergeSessionIndex(threadRecords, codexRoot: codexRoot)
            }
        } catch {
            for destination in published {
                try? fileManager.removeItem(at: destination)
            }
            throw error
        }
        return IncrementalRecoveryResult(
            restoredSessionIDs: restored.sorted(),
            skippedExistingSessionIDs: skipped.sorted(),
            threadRecords: threadRecords.sorted { $0.sessionID < $1.sessionID }
        )
    }

    private func validateBackup(
        _ sourceURL: URL,
        sessionID: String,
        record: BackupSessionRecord,
        verification: BackupVerificationDocument
    ) throws -> IncrementalRecoveryVerificationExpectation {
        guard record.bytesBackedUp >= 0, record.lineCount >= 0 else {
            throw IncrementalRecoveryError.unverifiedBackup(sessionID)
        }
        let verifier = BackupFileVerifier(chunkSize: verification.chunkSize)
        if let entry = verification.sessions[sessionID] {
            guard entry.backupPath == record.backupPath,
                  entry.byteCount == record.bytesBackedUp,
                  entry.lineCount == record.lineCount else {
                throw IncrementalRecoveryError.unverifiedBackup(sessionID)
            }
            let result = try verifier.verifyFull(
                sourceURL,
                expectedByteCount: record.bytesBackedUp,
                expectedLineCount: record.lineCount,
                expectedChunkHashes: entry.chunkHashes
            )
            return IncrementalRecoveryVerificationExpectation(
                byteCount: result.byteCount,
                lineCount: result.lineCount,
                contentHash: result.contentHash,
                chunkSize: verification.chunkSize,
                chunkHashes: entry.chunkHashes
            )
        }

        guard let contentHash = record.contentHash, Self.isSHA256(contentHash) else {
            throw IncrementalRecoveryError.unverifiedBackup(sessionID)
        }
        let result = try verifier.verifyFull(
            sourceURL,
            expectedByteCount: record.bytesBackedUp,
            expectedLineCount: record.lineCount,
            expectedContentHash: contentHash
        )
        return IncrementalRecoveryVerificationExpectation(
            byteCount: result.byteCount,
            lineCount: result.lineCount,
            contentHash: result.contentHash,
            chunkSize: verification.chunkSize,
            chunkHashes: nil
        )
    }

    private func stageAndVerify(
        entry: (item: IncrementalRecoveryItem, source: URL, destination: URL),
        at stagingURL: URL
    ) throws {
        try RestoreFilesystemValidator.validateSource(entry.source, under: paths.backupRoot)
        let sourceHandle = try FileHandle(forReadingFrom: entry.source)
        defer { try? sourceHandle.close() }
        let expected = entry.item.expectedVerification
        try writer.replace(
            at: stagingURL,
            verifyTemporary: { temporaryURL in
                _ = try BackupFileVerifier(chunkSize: expected.chunkSize).verifyFull(
                    temporaryURL,
                    expectedByteCount: expected.byteCount,
                    expectedLineCount: expected.lineCount,
                    expectedContentHash: expected.contentHash,
                    expectedChunkHashes: expected.chunkHashes
                )
            },
            writer: { destinationHandle in
                while let chunk = try sourceHandle.read(upToCount: expected.chunkSize), !chunk.isEmpty {
                    try destinationHandle.write(contentsOf: chunk)
                }
            }
        )
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
        }
    }

    private func loadManifest() throws -> BackupManifest {
        try BackupManifestStore(
            manifestURL: paths.manifestURL,
            createParentDirectories: false
        ).loadOrCreate(codexRoot: paths.codexRoot.path, backupRoot: paths.backupRoot.path)
    }

    private func mergeSessionIndex(
        _ records: [IncrementalRecoveryThreadRecord],
        codexRoot: URL
    ) throws {
        let indexURL = codexRoot.appendingPathComponent("session_index.jsonl")
        try RestoreFilesystemValidator.validateDestination(indexURL, under: codexRoot)
        var lines: [Data] = []
        var existingIDs = Set<String>()
        if fileManager.fileExists(atPath: indexURL.path) {
            for lineData in try readIndexLines(indexURL) where !lineData.isEmpty {
                lines.append(lineData)
                if let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                   let id = object["id"] as? String {
                    existingIDs.insert(id)
                }
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        for record in records.sorted(by: { $0.sessionID < $1.sessionID }) where !existingIDs.contains(record.sessionID) {
            lines.append(try encoder.encode(SessionIndexRecord(record)))
        }
        var output = Data()
        for line in lines {
            output.append(line)
            output.append(0x0A)
        }
        try writer.write(output, to: indexURL)
    }

    private func readIndexLines(_ indexURL: URL) throws -> [Data] {
        let handle = try FileHandle(forReadingFrom: indexURL)
        defer { try? handle.close() }
        var lines: [Data] = []
        var pending = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            var start = chunk.startIndex
            for newline in chunk.indices where chunk[newline] == 0x0A {
                if start < newline {
                    pending.append(contentsOf: chunk[start..<newline])
                }
                lines.append(pending)
                pending.removeAll(keepingCapacity: true)
                start = chunk.index(after: newline)
            }
            if start < chunk.endIndex {
                pending.append(contentsOf: chunk[start..<chunk.endIndex])
            }
            guard pending.count <= SessionTailer.defaultMaxLineBytes else {
                throw BackupFileVerificationError.lineTooLong(SessionTailer.defaultMaxLineBytes)
            }
        }
        if !pending.isEmpty { lines.append(pending) }
        return lines
    }

    private func displayTitle(for record: BackupSessionRecord) -> String {
        let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? record.sessionId : title
    }

    private func uniqueFilename(for sessionID: String, used: inout Set<String>) -> String {
        let stem = safeFilenameStem(sessionID)
        var filename = "\(stem).jsonl"
        var suffix = 2
        while used.contains(filename) {
            filename = "\(stem)-\(suffix).jsonl"
            suffix += 1
        }
        used.insert(filename)
        return filename
    }

    private func safeFilenameStem(_ value: String) -> String {
        let safe = value.unicodeScalars.map { scalar -> Character in
            if ("a"..."z").contains(scalar)
                || ("A"..."Z").contains(scalar)
                || ("0"..."9").contains(scalar)
                || scalar == "-"
                || scalar == "_" {
                return Character(String(scalar))
            }
            return "-"
        }
        let result = String(safe).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? "session" : result
    }
}

private struct SessionIndexRecord: Encodable {
    let id: String
    let threadName: String
    let rolloutPath: String
    let updatedAt: Date

    init(_ record: IncrementalRecoveryThreadRecord) {
        id = record.sessionID
        threadName = record.title
        rolloutPath = record.rolloutPath
        updatedAt = record.updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
        case rolloutPath = "rollout_path"
        case updatedAt = "updated_at"
    }
}
