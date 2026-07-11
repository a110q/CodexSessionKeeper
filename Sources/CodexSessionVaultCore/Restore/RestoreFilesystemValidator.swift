import Foundation

public enum RestoreFilesystemValidationError: Error, LocalizedError, Equatable {
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "快照包含不安全的符号链接或真实路径，已拒绝恢复：\(path)"
        }
    }
}

public enum RestoreFilesystemValidator {
    public static func validate(
        _ restorePaths: [ValidatedRestorePath],
        sourceRoot: URL,
        destinationRoot: URL
    ) throws {
        for restorePath in restorePaths {
            if try entry(at: restorePath.sourceURL).exists {
                try validateSource(restorePath.sourceURL, under: sourceRoot, recursive: true)
            }
            try validateDestination(restorePath.destinationURL, under: destinationRoot, recursive: true)
        }
    }

    public static func validateSource(
        _ sourceURL: URL,
        under sourceRoot: URL,
        recursive: Bool = false,
        allowMissing: Bool = false
    ) throws {
        try validateRoot(sourceRoot)
        try validateExistingComponents(of: sourceURL, under: sourceRoot)
        let sourceEntry = try entry(at: sourceURL)
        guard sourceEntry.exists else {
            if allowMissing { return }
            throw RestoreFilesystemValidationError.unsafePath(sourceURL.path)
        }
        guard !sourceEntry.isSymbolicLink,
              sourceEntry.isRegularFile || sourceEntry.isDirectory else {
            throw RestoreFilesystemValidationError.unsafePath(sourceURL.path)
        }
        try validateCanonicalContainment(sourceURL, under: sourceRoot)

        if recursive, sourceEntry.isDirectory {
            for child in try FileManager.default.contentsOfDirectory(
                at: sourceURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
            ) {
                try validateSource(child, under: sourceRoot, recursive: true)
            }
        }
    }

    public static func validateDestination(
        _ destinationURL: URL,
        under destinationRoot: URL,
        recursive: Bool = false
    ) throws {
        try validateRoot(destinationRoot)
        try validateExistingComponents(of: destinationURL, under: destinationRoot)
        let destinationEntry = try entry(at: destinationURL)
        guard !destinationEntry.isSymbolicLink else {
            throw RestoreFilesystemValidationError.unsafePath(destinationURL.path)
        }
        guard !destinationEntry.exists || destinationEntry.isRegularFile || destinationEntry.isDirectory else {
            throw RestoreFilesystemValidationError.unsafePath(destinationURL.path)
        }
        if destinationEntry.exists {
            try validateCanonicalContainment(destinationURL, under: destinationRoot)
        }

        if recursive, destinationEntry.isDirectory {
            for child in try FileManager.default.contentsOfDirectory(
                at: destinationURL,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
            ) {
                try validateDestination(child, under: destinationRoot, recursive: true)
            }
        }
    }

    private static func validateExistingComponents(of candidate: URL, under root: URL) throws {
        let components = try relativeComponents(of: candidate, under: root)
        var current = root.standardizedFileURL
        for component in components {
            current.appendPathComponent(component)
            let currentEntry = try entry(at: current)
            guard currentEntry.exists else { return }
            guard !currentEntry.isSymbolicLink else {
                throw RestoreFilesystemValidationError.unsafePath(current.path)
            }
        }
    }

    private static func validateRoot(_ root: URL) throws {
        let rootEntry = try entry(at: root)
        guard !rootEntry.exists || (!rootEntry.isSymbolicLink && rootEntry.isDirectory) else {
            throw RestoreFilesystemValidationError.unsafePath(root.path)
        }
    }

    private static func validateCanonicalContainment(_ candidate: URL, under root: URL) throws {
        let resolvedRoot = try canonicalRoot(root)
        let resolvedCandidate = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let rootComponents = resolvedRoot.pathComponents
        let candidateComponents = resolvedCandidate.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else {
            throw RestoreFilesystemValidationError.unsafePath(candidate.path)
        }
    }

    private static func canonicalRoot(_ root: URL) throws -> URL {
        let rootEntry = try entry(at: root)
        if rootEntry.exists {
            guard !rootEntry.isSymbolicLink, rootEntry.isDirectory else {
                throw RestoreFilesystemValidationError.unsafePath(root.path)
            }
            return root.standardizedFileURL.resolvingSymlinksInPath()
        }

        var missing: [String] = []
        var existing = root.standardizedFileURL
        while try !entry(at: existing).exists {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                throw RestoreFilesystemValidationError.unsafePath(root.path)
            }
            missing.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
        return missing.reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }
    }

    private static func relativeComponents(of candidate: URL, under root: URL) throws -> [String] {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count,
              candidateComponents.starts(with: rootComponents) else {
            throw RestoreFilesystemValidationError.unsafePath(candidate.path)
        }
        return Array(candidateComponents.dropFirst(rootComponents.count))
    }

    private static func entry(at url: URL) throws -> Entry {
        do {
            let values = try url.resourceValues(forKeys: [
                .isSymbolicLinkKey,
                .isRegularFileKey,
                .isDirectoryKey
            ])
            return Entry(
                exists: true,
                isSymbolicLink: values.isSymbolicLink == true,
                isRegularFile: values.isRegularFile == true,
                isDirectory: values.isDirectory == true
            )
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return Entry(exists: true, isSymbolicLink: true, isRegularFile: false, isDirectory: false)
            }
            return Entry(exists: false, isSymbolicLink: false, isRegularFile: false, isDirectory: false)
        }
    }

    private struct Entry {
        let exists: Bool
        let isSymbolicLink: Bool
        let isRegularFile: Bool
        let isDirectory: Bool
    }
}
