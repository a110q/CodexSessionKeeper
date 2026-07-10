import Foundation

public struct ExternalAttachmentRestoreRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let originalPath: String
    public let storedRelativePath: String
    public let sizeBytes: Int64

    public init(
        sessionID: String,
        originalPath: String,
        storedRelativePath: String,
        sizeBytes: Int64
    ) {
        self.sessionID = sessionID
        self.originalPath = originalPath
        self.storedRelativePath = storedRelativePath
        self.sizeBytes = sizeBytes
    }
}

public struct ValidatedExternalAttachmentRestore: Equatable, Sendable {
    public let sessionID: String
    public let sourceURL: URL
    public let destinationURL: URL

    public init(sessionID: String, sourceURL: URL, destinationURL: URL) {
        self.sessionID = sessionID
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }
}

public enum ExternalAttachmentRestoreValidationError: Error, LocalizedError, Equatable {
    case invalidStoredRelativePath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidStoredRelativePath(let path):
            return "快照附件包含不安全路径，已拒绝恢复：\(path)"
        }
    }
}

public enum ExternalAttachmentRestoreValidator {
    public static func validate(
        records: [ExternalAttachmentRestoreRecord],
        sourceRoot: URL,
        destinationRoot: URL,
        selectedSessionIDs: Set<String>?
    ) throws -> [ValidatedExternalAttachmentRestore] {
        let selectedRecords = records.filter { record in
            selectedSessionIDs?.contains(record.sessionID) ?? true
        }

        return try selectedRecords.map { record in
            let components = try validatedComponents(for: record)
            let sourceURL = components.reduce(sourceRoot.standardizedFileURL) {
                $0.appendingPathComponent($1, isDirectory: false)
            }.standardizedFileURL
            let destinationURL = components.dropFirst().reduce(destinationRoot.standardizedFileURL) {
                $0.appendingPathComponent($1, isDirectory: false)
            }.standardizedFileURL

            guard isDescendant(sourceURL, of: sourceRoot),
                  isDescendant(destinationURL, of: destinationRoot) else {
                throw ExternalAttachmentRestoreValidationError.invalidStoredRelativePath(
                    record.storedRelativePath
                )
            }

            return ValidatedExternalAttachmentRestore(
                sessionID: record.sessionID,
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        }
    }

    private static func validatedComponents(
        for record: ExternalAttachmentRestoreRecord
    ) throws -> [String] {
        let rawPath = record.storedRelativePath
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        guard !rawPath.contains("\0"),
              !rawPath.contains("\\"),
              components.count == 3,
              components[0] == "external_attachments",
              components[1] == record.sessionID,
              components.allSatisfy(isSafeComponent) else {
            throw ExternalAttachmentRestoreValidationError.invalidStoredRelativePath(rawPath)
        }

        return components
    }

    private static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty
            && component != "."
            && component != ".."
            && !component.contains("\0")
            && !component.contains("/")
            && !component.contains("\\")
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }
}
