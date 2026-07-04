import Foundation

public struct BackupPaths: Sendable {
    public let homeDirectory: URL
    public let codexRoot: URL
    public let vaultRoot: URL
    public let backupRoot: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexRoot: URL? = nil,
        vaultRoot: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.codexRoot = codexRoot ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        self.vaultRoot = vaultRoot ?? homeDirectory.appendingPathComponent(".codex-session-vault", isDirectory: true)
        self.backupRoot = self.vaultRoot.appendingPathComponent("incremental-backups", isDirectory: true)
    }

    public var manifestURL: URL {
        backupRoot.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public var cursorDatabaseURL: URL {
        backupRoot.appendingPathComponent("cursors.sqlite", isDirectory: false)
    }

    public var statusURL: URL {
        backupRoot.appendingPathComponent("status.json", isDirectory: false)
    }

    public var sessionsRootURL: URL {
        backupRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    public var logsRootURL: URL {
        backupRoot.appendingPathComponent("logs", isDirectory: true)
    }

    public var logURL: URL {
        logsRootURL.appendingPathComponent("backup-agent.log", isDirectory: false)
    }

    public var restoreStagingRootURL: URL {
        vaultRoot.appendingPathComponent("incremental-restore-staging", isDirectory: true)
    }

    public func backupFileURL(sessionID: String, firstSeenAt: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: firstSeenAt)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let day = String(format: "%02d", components.day ?? 1)
        return sessionsRootURL
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("\(sessionID).jsonl", isDirectory: false)
    }

    public func relativeBackupPath(for fileURL: URL) -> String {
        let root = backupRoot.standardizedFileURL.path
        let path = fileURL.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return fileURL.lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }
}
