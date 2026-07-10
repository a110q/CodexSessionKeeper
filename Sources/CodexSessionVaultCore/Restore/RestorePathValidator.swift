import Foundation

public struct ValidatedRestorePath: Equatable, Sendable {
    public let relativePath: String
    public let sourceURL: URL
    public let destinationURL: URL

    public init(relativePath: String, sourceURL: URL, destinationURL: URL) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
    }
}

public enum RestorePathValidationError: Error, LocalizedError, Equatable {
    case invalidIncludedPath(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIncludedPath(let path):
            return "快照包含不安全路径，已拒绝恢复：\(path)"
        }
    }
}

public enum RestorePathValidator {
    public static func validate(
        _ includedPaths: [String],
        sourceRoot: URL,
        destinationRoot: URL
    ) throws -> [ValidatedRestorePath] {
        try includedPaths.map { rawPath in
            let relativePath = try normalizedRelativePath(rawPath)
            let components = relativePath.split(separator: "/").map(String.init)
            let sourceURL = components.reduce(sourceRoot.standardizedFileURL) {
                $0.appendingPathComponent($1, isDirectory: false)
            }.standardizedFileURL
            let destinationURL = components.reduce(destinationRoot.standardizedFileURL) {
                $0.appendingPathComponent($1, isDirectory: false)
            }.standardizedFileURL

            guard isDescendant(sourceURL, of: sourceRoot),
                  isDescendant(destinationURL, of: destinationRoot) else {
                throw RestorePathValidationError.invalidIncludedPath(rawPath)
            }

            return ValidatedRestorePath(
                relativePath: relativePath,
                sourceURL: sourceURL,
                destinationURL: destinationURL
            )
        }
    }

    private static func normalizedRelativePath(_ rawPath: String) throws -> String {
        guard !rawPath.isEmpty, !rawPath.contains("\0") else {
            throw RestorePathValidationError.invalidIncludedPath(rawPath)
        }

        let normalized = rawPath.replacingOccurrences(of: "\\", with: "/")
        let hasWindowsDrivePrefix = normalized.count >= 2
            && normalized[normalized.startIndex].isASCII
            && normalized[normalized.startIndex].isLetter
            && normalized[normalized.index(after: normalized.startIndex)] == ":"
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)

        guard !normalized.hasPrefix("/"),
              !hasWindowsDrivePrefix,
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RestorePathValidationError.invalidIncludedPath(rawPath)
        }

        return components.joined(separator: "/")
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count > rootComponents.count
            && candidateComponents.starts(with: rootComponents)
    }
}
