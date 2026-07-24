import Foundation

public final class BackupManifestStore {
    private let manifestURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let writer: DurableAtomicWriter
    private let createParentDirectories: Bool

    public init(
        manifestURL: URL,
        createParentDirectories: Bool = true,
        writer: DurableAtomicWriter = DurableAtomicWriter()
    ) {
        self.manifestURL = manifestURL
        self.fileManager = .default
        self.createParentDirectories = createParentDirectories
        self.writer = writer

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
                version: 2,
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
        let data = try encoder.encode(manifest)
        try writer.write(
            data,
            to: manifestURL,
            createParentDirectories: createParentDirectories
        )
    }
}
