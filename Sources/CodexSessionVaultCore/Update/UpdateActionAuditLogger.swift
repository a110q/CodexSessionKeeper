import Foundation

public enum UpdateActionAuditError: Error, Equatable, Sendable {
    case invalidEntry
}

public enum UpdateActionAuditEvent: String, Codable, Equatable, Sendable {
    case downloadConfirmationRequested = "download_confirmation_requested"
    case downloadConfirmed = "download_confirmed"
    case downloadCancelled = "download_cancelled"
    case downloadRequested = "download_requested"
    case downloadStarted = "download_started"
    case downloadReady = "download_ready"
    case installConfirmationRequested = "install_confirmation_requested"
    case installConfirmed = "install_confirmed"
    case installCancelled = "install_cancelled"
    case installRequested = "install_requested"
    case installStarted = "install_started"
    case installCompleted = "install_completed"
    case updateFailed = "update_failed"
}

public struct UpdateActionAuditEntry: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let timestamp: Date
    public let platform: String
    public let event: UpdateActionAuditEvent
    public let version: String

    public init(
        schemaVersion: Int = 1,
        timestamp: Date,
        platform: String,
        event: UpdateActionAuditEvent,
        version: String
    ) {
        self.schemaVersion = schemaVersion
        self.timestamp = timestamp
        self.platform = platform
        self.event = event
        self.version = version
    }
}

public final class UpdateActionAuditLogger: @unchecked Sendable {
    private let url: URL
    private let platform: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()

    public init(
        url: URL,
        platform: String,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.url = url
        self.platform = platform
        self.now = now
    }

    public func record(_ event: UpdateActionAuditEvent, version: String) throws {
        guard !platform.isEmpty, platform.utf8.count <= 64,
              !version.isEmpty, version.utf8.count <= 64,
              !platform.contains(where: \.isNewline),
              !version.contains(where: \.isNewline) else {
            throw UpdateActionAuditError.invalidEntry
        }

        let entry = UpdateActionAuditEntry(
            timestamp: now(),
            platform: platform,
            event: event,
            version: version
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)

        lock.lock()
        defer { lock.unlock() }

        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}
