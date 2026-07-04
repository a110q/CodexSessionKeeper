import Foundation

public struct BackupRecoveryPackage: Equatable, Sendable {
    public let rootURL: URL
    public let dataURL: URL
    public let snapshotJSON: URL
    public let sessionIndexURL: URL

    public init(
        rootURL: URL,
        dataURL: URL,
        snapshotJSON: URL,
        sessionIndexURL: URL
    ) {
        self.rootURL = rootURL
        self.dataURL = dataURL
        self.snapshotJSON = snapshotJSON
        self.sessionIndexURL = sessionIndexURL
    }
}

public final class BackupRecoveryBuilder {
    private let paths: BackupPaths
    private let now: () -> Date
    private let fileManager: FileManager

    public init(
        paths: BackupPaths = BackupPaths(),
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.now = now
        self.fileManager = fileManager
    }

    public func buildRecoveryPackage(sessionIDs: [String]) throws -> BackupRecoveryPackage {
        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let requestedIDs = Set(sessionIDs)
        let selectedRecords = manifest.sessions.values
            .filter { requestedIDs.contains($0.sessionId) }
            .sorted { $0.sessionId < $1.sessionId }

        guard !selectedRecords.isEmpty else {
            throw BackupRecoveryBuilderError.noSelectedSessions
        }

        let backupSources = try selectedRecords.map { record in
            try BackupSource(record: record, fileURL: validatedBackupFileURL(for: record))
        }

        let createdAt = now()
        let packageRoot = try makePackageRoot(createdAt: createdAt)
        let dataURL = packageRoot.appendingPathComponent("data", isDirectory: true)
        let recoveredSessionsURL = dataURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("recovered", isDirectory: true)
        try fileManager.createDirectory(
            at: recoveredSessionsURL,
            withIntermediateDirectories: true
        )

        var usedFilenames = Set<String>()
        var indexEntries: [SessionIndexEntry] = []
        var includedPaths: [String] = ["session_index.jsonl"]

        for source in backupSources {
            let filename = uniqueRecoveredFilename(
                for: source.record.sessionId,
                usedFilenames: &usedFilenames
            )
            let recoveredRelativePath = "sessions/recovered/\(filename)"
            let recoveredURL = recoveredSessionsURL.appendingPathComponent(filename, isDirectory: false)
            let contents = try Data(contentsOf: source.fileURL)
            try contents.write(to: recoveredURL, options: [.atomic])

            includedPaths.append(recoveredRelativePath)
            indexEntries.append(SessionIndexEntry(
                id: source.record.sessionId,
                title: source.record.title ?? "",
                rolloutPath: paths.codexRoot
                    .appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent("recovered", isDirectory: true)
                    .appendingPathComponent(filename, isDirectory: false)
                    .path,
                sourcePath: source.record.sourcePath,
                backupPath: source.record.backupPath,
                updatedAt: source.record.lastBackedUpAt ?? source.record.firstSeenAt,
                lineCount: source.record.lineCount,
                bytesBackedUp: source.record.bytesBackedUp
            ))
        }

        let sessionIndexURL = dataURL.appendingPathComponent("session_index.jsonl", isDirectory: false)
        try writeSessionIndex(indexEntries, to: sessionIndexURL)

        let snapshotJSON = packageRoot.appendingPathComponent("snapshot.json", isDirectory: false)
        let createdAtString = Self.iso8601String(from: createdAt)
        let snapshot = RecoverySnapshotMetadata(
            id: "incremental-recovery-\(Self.safePathComponent(from: createdAtString))",
            name: "Incremental Recovery \(createdAtString)",
            createdAt: createdAt,
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path,
            reason: "incremental-recovery",
            kind: "system",
            modelProvider: "unknown",
            model: "unknown",
            accountFingerprint: "none",
            sessionCount: selectedRecords.count,
            archivedSessionCount: 0,
            sizeBytes: selectedRecords.reduce(Int64(0)) { $0 + $1.bytesBackedUp },
            includedPaths: includedPaths.sorted(),
            appVersion: Self.appVersion
        )
        try writeSnapshot(snapshot, to: snapshotJSON)

        return BackupRecoveryPackage(
            rootURL: packageRoot,
            dataURL: dataURL,
            snapshotJSON: snapshotJSON,
            sessionIndexURL: sessionIndexURL
        )
    }

    private func validatedBackupFileURL(for record: BackupSessionRecord) throws -> URL {
        guard !record.backupPath.isEmpty else {
            throw BackupRecoveryBuilderError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is empty"
            )
        }
        guard !record.backupPath.hasPrefix("/") else {
            throw BackupRecoveryBuilderError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is absolute"
            )
        }

        let components = record.backupPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." }) else {
            throw BackupRecoveryBuilderError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is not a normalized relative path"
            )
        }
        guard !components.contains("..") else {
            throw BackupRecoveryBuilderError.backupPathEscapesRoot(
                sessionID: record.sessionId,
                backupPath: record.backupPath
            )
        }

        var fileURL = paths.backupRoot
        for (index, component) in components.enumerated() {
            fileURL = fileURL.appendingPathComponent(
                component,
                isDirectory: index < components.count - 1
            )
        }

        guard isURL(fileURL, containedIn: paths.backupRoot) else {
            throw BackupRecoveryBuilderError.backupPathEscapesRoot(
                sessionID: record.sessionId,
                backupPath: record.backupPath
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw BackupRecoveryBuilderError.backupFileMissing(
                sessionID: record.sessionId,
                filePath: fileURL.path
            )
        }

        return fileURL
    }

    private func isURL(_ candidate: URL, containedIn root: URL) -> Bool {
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        return resolvedCandidate.path.hasPrefix(resolvedRoot.path + "/")
    }

    private func makePackageRoot(createdAt: Date) throws -> URL {
        let packagesRoot = paths.backupRoot.appendingPathComponent("recovery-packages", isDirectory: true)
        try fileManager.createDirectory(at: packagesRoot, withIntermediateDirectories: true)

        let baseName = Self.safePathComponent(from: Self.iso8601String(from: createdAt))
        var candidate = packagesRoot.appendingPathComponent(baseName, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = packagesRoot.appendingPathComponent("\(baseName)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }

    private func writeSessionIndex(_ entries: [SessionIndexEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }
        try data.write(to: url, options: [.atomic])
    }

    private func writeSnapshot(_ snapshot: RecoverySnapshotMetadata, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: [.atomic])
    }

    private func uniqueRecoveredFilename(
        for sessionID: String,
        usedFilenames: inout Set<String>
    ) -> String {
        let stem = Self.safePathComponent(from: sessionID)
        var filename = "\(stem).jsonl"
        var suffix = 2
        while usedFilenames.contains(filename) {
            filename = "\(stem)-\(suffix).jsonl"
            suffix += 1
        }
        usedFilenames.insert(filename)
        return filename
    }

    private static func safePathComponent(from rawValue: String) -> String {
        var sanitized = ""
        var previousWasSeparator = false

        for scalar in rawValue.unicodeScalars {
            if scalar.isBackupRecoverySafePathScalar {
                sanitized.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                sanitized.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }

    private static let appVersion = "1.0.13"

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

private struct BackupSource {
    var record: BackupSessionRecord
    var fileURL: URL
}

private struct SessionIndexEntry: Encodable {
    var id: String
    var title: String
    var rolloutPath: String
    var sourcePath: String
    var backupPath: String
    var updatedAt: Date
    var lineCount: Int
    var bytesBackedUp: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case rolloutPath = "rollout_path"
        case sourcePath = "source_path"
        case backupPath = "backup_path"
        case updatedAt = "updated_at"
        case lineCount = "line_count"
        case bytesBackedUp = "bytes_backed_up"
    }
}

private struct RecoverySnapshotMetadata: Encodable {
    var id: String
    var name: String
    var createdAt: Date
    var codexRoot: String
    var backupRoot: String
    var reason: String
    var kind: String
    var modelProvider: String
    var model: String
    var accountFingerprint: String
    var sessionCount: Int
    var archivedSessionCount: Int
    var sizeBytes: Int64
    var includedPaths: [String]
    var appVersion: String
}

private enum BackupRecoveryBuilderError: LocalizedError {
    case noSelectedSessions
    case invalidBackupPath(sessionID: String, backupPath: String, reason: String)
    case backupPathEscapesRoot(sessionID: String, backupPath: String)
    case backupFileMissing(sessionID: String, filePath: String)

    var errorDescription: String? {
        switch self {
        case .noSelectedSessions:
            return "No requested sessions were found in the backup manifest."
        case let .invalidBackupPath(sessionID, backupPath, reason):
            return "Backup path for session \(sessionID) \(reason): \(backupPath)"
        case let .backupPathEscapesRoot(sessionID, backupPath):
            return "Backup path for session \(sessionID) escapes backup root: \(backupPath)"
        case let .backupFileMissing(sessionID, filePath):
            return "Backup file is missing for session \(sessionID): \(filePath)"
        }
    }
}

private extension Unicode.Scalar {
    var isBackupRecoverySafePathScalar: Bool {
        ("a"..."z").contains(self)
            || ("A"..."Z").contains(self)
            || ("0"..."9").contains(self)
            || self == "-"
            || self == "_"
    }
}
