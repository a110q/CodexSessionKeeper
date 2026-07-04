import Foundation

public final class BackupManifestStore {
    private let manifestURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(manifestURL: URL) {
        self.manifestURL = manifestURL
        self.fileManager = .default

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func loadOrCreate(
        codexRoot: String,
        backupRoot: String,
        now: Date = Date()
    ) throws -> BackupManifest {
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return BackupManifest(
                version: 1,
                codexRoot: codexRoot,
                backupRoot: backupRoot,
                createdAt: now,
                updatedAt: now,
                sessions: [:]
            )
        }

        let data = try Data(contentsOf: manifestURL)
        return try decoder.decode(BackupManifest.self, from: data)
    }

    public func save(_ manifest: BackupManifest) throws {
        let parentDirectory = manifestURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: parentDirectory,
            withIntermediateDirectories: true
        )

        let data = try encoder.encode(manifest)
        try data.write(to: manifestURL, options: [.atomic])
    }
}
