import Foundation

public enum IncrementalRestoreStatus: String, Codable, Sendable {
    case missing
    case existing
    case invalidBackup
    case backupFileMissing
}

public struct IncrementalRestoreCandidate: Codable, Equatable, Identifiable, Sendable {
    public var id: String { sessionId }

    public let sessionId: String
    public let title: String
    public let sourcePath: String
    public let backupPath: String
    public let backupFilePath: String
    public let firstSeenAt: Date
    public let lastBackedUpAt: Date?
    public let lineCount: Int
    public let bytesBackedUp: Int64
    public let status: IncrementalRestoreStatus
    public let error: String?

    public var isRestorable: Bool {
        status == .missing
    }
}

public struct IncrementalBackupCatalogResult: Codable, Equatable, Sendable {
    public let backupRoot: String
    public let updatedAt: Date?
    public let totalCount: Int
    public let missingCount: Int
    public let existingCount: Int
    public let errorCount: Int
    public let candidates: [IncrementalRestoreCandidate]
}

public final class IncrementalBackupCatalog {
    private let paths: BackupPaths
    private let fileManager: FileManager

    public init(paths: BackupPaths = BackupPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load(currentSessionIDs: Set<String>) throws -> IncrementalBackupCatalogResult {
        let manifest = try BackupManifestStore(manifestURL: paths.manifestURL).loadOrCreate(
            codexRoot: paths.codexRoot.path,
            backupRoot: paths.backupRoot.path
        )
        let candidates = manifest.sessions.values
            .sorted { ($0.lastBackedUpAt ?? $0.firstSeenAt) > ($1.lastBackedUpAt ?? $1.firstSeenAt) }
            .map { candidate(for: $0, currentSessionIDs: currentSessionIDs) }

        return IncrementalBackupCatalogResult(
            backupRoot: paths.backupRoot.path,
            updatedAt: manifest.updatedAt,
            totalCount: candidates.count,
            missingCount: candidates.filter { $0.status == .missing }.count,
            existingCount: candidates.filter { $0.status == .existing }.count,
            errorCount: candidates.filter { $0.status == .invalidBackup || $0.status == .backupFileMissing }.count,
            candidates: candidates
        )
    }

    private func candidate(
        for record: BackupSessionRecord,
        currentSessionIDs: Set<String>
    ) -> IncrementalRestoreCandidate {
        do {
            let backupFile = try validatedBackupFileURL(for: record)
            let status: IncrementalRestoreStatus = currentSessionIDs.contains(record.sessionId)
                ? .existing
                : .missing
            return makeCandidate(record: record, backupFile: backupFile, status: status, error: nil)
        } catch CatalogError.backupFileMissing(_, _) {
            return makeCandidate(
                record: record,
                backupFile: nil,
                status: .backupFileMissing,
                error: CatalogError.backupFileMissing(
                    sessionID: record.sessionId,
                    filePath: backupFilePath(forDisplayOnly: record)
                ).localizedDescription
            )
        } catch let error as LocalizedError {
            return makeCandidate(
                record: record,
                backupFile: nil,
                status: .invalidBackup,
                error: error.errorDescription ?? String(describing: error)
            )
        } catch {
            return makeCandidate(
                record: record,
                backupFile: nil,
                status: .invalidBackup,
                error: String(describing: error)
            )
        }
    }

    private func makeCandidate(
        record: BackupSessionRecord,
        backupFile: URL?,
        status: IncrementalRestoreStatus,
        error: String?
    ) -> IncrementalRestoreCandidate {
        let trimmedTitle = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return IncrementalRestoreCandidate(
            sessionId: record.sessionId,
            title: trimmedTitle.isEmpty ? record.sessionId : trimmedTitle,
            sourcePath: record.sourcePath,
            backupPath: record.backupPath,
            backupFilePath: backupFile?.path ?? "",
            firstSeenAt: record.firstSeenAt,
            lastBackedUpAt: record.lastBackedUpAt,
            lineCount: record.lineCount,
            bytesBackedUp: record.bytesBackedUp,
            status: status,
            error: error
        )
    }

    private func backupFilePath(forDisplayOnly record: BackupSessionRecord) -> String {
        guard !record.backupPath.isEmpty, !record.backupPath.hasPrefix("/") else {
            return record.backupPath
        }
        var fileURL = paths.backupRoot
        for component in record.backupPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            fileURL = fileURL.appendingPathComponent(component)
        }
        return fileURL.path
    }

    private func validatedBackupFileURL(for record: BackupSessionRecord) throws -> URL {
        guard !record.backupPath.isEmpty else {
            throw CatalogError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is empty"
            )
        }
        guard !record.backupPath.hasPrefix("/") else {
            throw CatalogError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is absolute"
            )
        }

        let components = record.backupPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(where: { $0.isEmpty || $0 == "." }) else {
            throw CatalogError.invalidBackupPath(
                sessionID: record.sessionId,
                backupPath: record.backupPath,
                reason: "is not a normalized relative path"
            )
        }
        guard !components.contains("..") else {
            throw CatalogError.backupPathEscapesRoot(
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
            throw CatalogError.backupPathEscapesRoot(
                sessionID: record.sessionId,
                backupPath: record.backupPath
            )
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CatalogError.backupFileMissing(
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
}

private enum CatalogError: LocalizedError {
    case invalidBackupPath(sessionID: String, backupPath: String, reason: String)
    case backupPathEscapesRoot(sessionID: String, backupPath: String)
    case backupFileMissing(sessionID: String, filePath: String)

    var errorDescription: String? {
        switch self {
        case let .invalidBackupPath(sessionID, backupPath, reason):
            return "Backup path for session \(sessionID) \(reason): \(backupPath)"
        case let .backupPathEscapesRoot(sessionID, backupPath):
            return "Backup path for session \(sessionID) escapes backup root: \(backupPath)"
        case let .backupFileMissing(sessionID, filePath):
            return "Backup file is missing for session \(sessionID): \(filePath)"
        }
    }
}
