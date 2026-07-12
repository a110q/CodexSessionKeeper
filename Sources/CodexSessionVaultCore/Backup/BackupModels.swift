import Foundation

public enum BackupRunMode: String, Codable, Sendable {
    case watching
    case polling
}

public enum BackupHealthStatus: String, Codable, Sendable {
    case running
    case waiting
    case error
    case paused
}

public struct BackupSessionRecord: Codable, Equatable, Sendable {
    public var sessionId: String
    public var sourcePath: String
    public var backupPath: String
    public var title: String?
    public var firstSeenAt: Date
    public var lastBackedUpAt: Date?
    public var lineCount: Int
    public var bytesBackedUp: Int64
    public var status: String
    public var contentHash: String?

    public init(
        sessionId: String,
        sourcePath: String,
        backupPath: String,
        title: String?,
        firstSeenAt: Date,
        lastBackedUpAt: Date?,
        lineCount: Int,
        bytesBackedUp: Int64,
        status: String,
        contentHash: String? = nil
    ) {
        self.sessionId = sessionId
        self.sourcePath = sourcePath
        self.backupPath = backupPath
        self.title = title
        self.firstSeenAt = firstSeenAt
        self.lastBackedUpAt = lastBackedUpAt
        self.lineCount = lineCount
        self.bytesBackedUp = bytesBackedUp
        self.status = status
        self.contentHash = contentHash
    }
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public var version: Int
    public var codexRoot: String
    public var backupRoot: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sessions: [String: BackupSessionRecord]

    public init(
        version: Int = 2,
        codexRoot: String,
        backupRoot: String,
        createdAt: Date,
        updatedAt: Date,
        sessions: [String: BackupSessionRecord] = [:]
    ) {
        self.version = version
        self.codexRoot = codexRoot
        self.backupRoot = backupRoot
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sessions = sessions
    }
}

public struct BackupStatus: Codable, Equatable, Sendable {
    public var agentVersion: String
    public var enabled: Bool
    public var status: BackupHealthStatus
    public var mode: BackupRunMode
    public var codexRoot: String
    public var backupRoot: String
    public var firstRunAt: Date
    public var lastStartedAt: Date
    public var lastHeartbeatAt: Date
    public var lastBackupAt: Date?
    public var sessionCount: Int
    public var lineCount: Int
    public var bytesBackedUp: Int64
    public var autoStartEnabled: Bool
    public var lastError: String?

    public init(
        agentVersion: String,
        enabled: Bool,
        status: BackupHealthStatus,
        mode: BackupRunMode,
        codexRoot: String,
        backupRoot: String,
        firstRunAt: Date,
        lastStartedAt: Date,
        lastHeartbeatAt: Date,
        lastBackupAt: Date?,
        sessionCount: Int,
        lineCount: Int,
        bytesBackedUp: Int64,
        autoStartEnabled: Bool,
        lastError: String?
    ) {
        self.agentVersion = agentVersion
        self.enabled = enabled
        self.status = status
        self.mode = mode
        self.codexRoot = codexRoot
        self.backupRoot = backupRoot
        self.firstRunAt = firstRunAt
        self.lastStartedAt = lastStartedAt
        self.lastHeartbeatAt = lastHeartbeatAt
        self.lastBackupAt = lastBackupAt
        self.sessionCount = sessionCount
        self.lineCount = lineCount
        self.bytesBackedUp = bytesBackedUp
        self.autoStartEnabled = autoStartEnabled
        self.lastError = lastError
    }
}
