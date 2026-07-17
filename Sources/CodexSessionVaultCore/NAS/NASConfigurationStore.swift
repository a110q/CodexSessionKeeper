import Foundation

public final class NASConfigurationStore {
    public let fileURL: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> NASBackupConfiguration? {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return try decoder.decode(NASBackupConfiguration.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ configuration: NASBackupConfiguration) throws {
        try NASJSONFile.write(
            encoder.encode(configuration),
            to: fileURL,
            fileManager: fileManager,
            permissions: 0o600,
            parentDirectoryPermissions: 0o700
        )
    }
}

enum NASJSONFile {
    static func write(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager,
        permissions: NSNumber? = nil,
        parentDirectoryPermissions: NSNumber? = nil,
        createParentDirectories: Bool = true
    ) throws {
        try DurableAtomicWriter(fileManager: fileManager).write(
            data,
            to: destination,
            permissions: permissions,
            parentDirectoryPermissions: parentDirectoryPermissions,
            createParentDirectories: createParentDirectories
        )
    }
}
