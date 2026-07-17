import Foundation

public enum SecureRecoveryDirectoryCreator {
    public static func createRecoveredDirectory(
        under codexRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard codexRoot.isFileURL, codexRoot.path.hasPrefix("/") else {
            throw RestoreFilesystemValidationError.unsafePath(codexRoot.path)
        }

        try ensureRealDirectory(codexRoot, fileManager: fileManager)
        let sessions = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        try RestoreFilesystemValidator.validateDestination(sessions, under: codexRoot)
        try ensureRealDirectory(sessions, fileManager: fileManager)
        try RestoreFilesystemValidator.validateDestination(sessions, under: codexRoot)

        let recovered = sessions.appendingPathComponent("recovered", isDirectory: true)
        try RestoreFilesystemValidator.validateDestination(recovered, under: codexRoot)
        try ensureRealDirectory(recovered, fileManager: fileManager)
        try RestoreFilesystemValidator.validateDestination(recovered, under: codexRoot)
        return recovered
    }

    private static func ensureRealDirectory(_ directory: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: directory.path) {
            try validateRealDirectory(directory)
            return
        }

        let parent = directory.deletingLastPathComponent()
        try validateRealDirectory(parent)
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        } catch {
            guard fileManager.fileExists(atPath: directory.path) else { throw error }
        }
        try validateRealDirectory(directory)
        let resolvedParent = parent.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedDirectory.deletingLastPathComponent() == resolvedParent else {
            throw RestoreFilesystemValidationError.unsafePath(directory.path)
        }
    }

    private static func validateRealDirectory(_ directory: URL) throws {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RestoreFilesystemValidationError.unsafePath(directory.path)
        }
    }
}
