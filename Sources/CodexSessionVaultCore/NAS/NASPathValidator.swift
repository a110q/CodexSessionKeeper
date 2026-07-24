import Foundation

public enum NASPathValidationError: Error, Equatable, Sendable {
    case invalidComponent(String)
    case missingDirectory(String)
    case unsafeDirectory(String)
}

extension NASPathValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidComponent(value):
            return "NAS 目录名称不合法：\(value)"
        case let .missingDirectory(path):
            return "NAS 目录不存在：\(path)"
        case let .unsafeDirectory(path):
            return "NAS 目录不是可信的直接子目录：\(path)"
        }
    }
}

public final class NASPathValidator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validateComponent(_ value: String) throws {
        guard !value.isEmpty,
              !value.contains("\0"),
              value != ".",
              value != "..",
              !value.contains("/"),
              !value.contains("\\"),
              !value.hasPrefix("/"),
              value.range(of: #"^[A-Za-z]:"#, options: .regularExpression) == nil
        else {
            throw NASPathValidationError.invalidComponent(value)
        }
    }

    public func resolveDirectDirectory(named name: String, under parent: URL) throws -> URL {
        try validateComponent(name)
        let safeParent = try validateExistingDirectory(parent)
        let candidate = safeParent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        guard candidate.deletingLastPathComponent() == safeParent else {
            throw NASPathValidationError.unsafeDirectory(candidate.path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NASPathValidationError.missingDirectory(candidate.path)
        }

        let values = try candidate.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let resolvedParent = safeParent.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard values.isSymbolicLink != true,
              values.isDirectory == true,
              resolvedCandidate.deletingLastPathComponent() == resolvedParent
        else {
            throw NASPathValidationError.unsafeDirectory(candidate.path)
        }
        return candidate
    }

    public func directDirectories(under parent: URL) throws -> [NASDirectoryOption] {
        let safeParent = try validateExistingDirectory(parent)
        let entries = try fileManager.contentsOfDirectory(
            at: safeParent,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return entries.compactMap { entry in
            guard let directory = try? resolveDirectDirectory(named: entry.lastPathComponent, under: safeParent) else {
                return nil
            }
            return NASDirectoryOption(name: directory.lastPathComponent)
        }.sorted { $0.name < $1.name }
    }

    public func ensureManagedDirectory(named name: String, under parent: URL) throws -> URL {
        try validateComponent(name)
        let safeParent = try validateExistingDirectory(parent)
        let candidate = safeParent.appendingPathComponent(name, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            return try resolveDirectDirectory(named: name, under: safeParent)
        }
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
        return try resolveDirectDirectory(named: name, under: safeParent)
    }

    private func validateExistingDirectory(_ url: URL) throws -> URL {
        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw NASPathValidationError.missingDirectory(standardized.path)
        }
        let values = try standardized.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw NASPathValidationError.unsafeDirectory(standardized.path)
        }
        return standardized
    }
}
