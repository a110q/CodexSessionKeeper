import Foundation

public struct BackupSessionVerification: Codable, Equatable, Sendable {
    public var backupPath: String
    public var byteCount: Int64
    public var lineCount: Int
    public var chunkHashes: [String]
    public var verifiedAt: Date

    public init(
        backupPath: String,
        byteCount: Int64,
        lineCount: Int,
        chunkHashes: [String],
        verifiedAt: Date
    ) {
        self.backupPath = backupPath
        self.byteCount = byteCount
        self.lineCount = lineCount
        self.chunkHashes = chunkHashes
        self.verifiedAt = verifiedAt
    }
}

public struct BackupVerificationDocument: Codable, Equatable, Sendable {
    public static let version = 1
    public static let algorithm = "sha256-chunks-v1"
    public static let defaultChunkSize = 4 * 1_024 * 1_024

    public var version: Int
    public var algorithm: String
    public var chunkSize: Int
    public var sessions: [String: BackupSessionVerification]

    public init(
        version: Int = Self.version,
        algorithm: String = Self.algorithm,
        chunkSize: Int = Self.defaultChunkSize,
        sessions: [String: BackupSessionVerification] = [:]
    ) {
        self.version = version
        self.algorithm = algorithm
        self.chunkSize = chunkSize
        self.sessions = sessions
    }
}

public enum BackupVerificationStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidDocument

    public var errorDescription: String? {
        "NAS 备份验证记录无效。"
    }
}

public final class BackupVerificationStore {
    private let fileURL: URL
    private let fileManager: FileManager
    private let writer: DurableAtomicWriter
    private let createParentDirectories: Bool
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        fileURL: URL,
        createParentDirectories: Bool = true,
        fileManager: FileManager = .default,
        writer: DurableAtomicWriter = DurableAtomicWriter()
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.writer = writer
        self.createParentDirectories = createParentDirectories
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load() throws -> BackupVerificationDocument {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return BackupVerificationDocument()
        }
        let document = try decoder.decode(
            BackupVerificationDocument.self,
            from: Data(contentsOf: fileURL)
        )
        guard document.version == BackupVerificationDocument.version,
              document.algorithm == BackupVerificationDocument.algorithm,
              document.chunkSize == BackupVerificationDocument.defaultChunkSize else {
            throw BackupVerificationStoreError.invalidDocument
        }
        return document
    }

    public func save(_ document: BackupVerificationDocument) throws {
        guard document.version == BackupVerificationDocument.version,
              document.algorithm == BackupVerificationDocument.algorithm,
              document.chunkSize == BackupVerificationDocument.defaultChunkSize else {
            throw BackupVerificationStoreError.invalidDocument
        }
        try writer.write(
            encoder.encode(document),
            to: fileURL,
            createParentDirectories: createParentDirectories
        )
    }
}
