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
            fileManager: fileManager
        )
    }
}

enum NASJSONFile {
    static func write(
        _ data: Data,
        to destination: URL,
        fileManager: FileManager,
        createParentDirectories: Bool = true
    ) throws {
        let parent = destination.deletingLastPathComponent()
        if createParentDirectories {
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }

        do {
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }
}
