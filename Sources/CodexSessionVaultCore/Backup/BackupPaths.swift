import Foundation

public struct BackupPaths: Sendable {
    public let homeDirectory: URL
    public let codexRoot: URL
    public let backupRoot: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexRoot: URL? = nil,
        backupRoot: URL? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.codexRoot = codexRoot ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        self.backupRoot = backupRoot
            ?? homeDirectory
                .appendingPathComponent(".codex-session-vault", isDirectory: true)
                .appendingPathComponent("incremental-backups", isDirectory: true)
    }

    public var sessionsRoot: URL {
        backupRoot.appendingPathComponent("sessions", isDirectory: true)
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

    public var logURL: URL {
        backupRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("backup-agent.log", isDirectory: false)
    }

    public func backupFileURL(sessionID: String, firstSeenAt: Date) -> URL {
        let dateComponents = Self.utcCalendar.dateComponents([.year, .month, .day], from: firstSeenAt)
        let year = String(format: "%04d", dateComponents.year ?? 1970)
        let month = String(format: "%02d", dateComponents.month ?? 1)
        let day = String(format: "%02d", dateComponents.day ?? 1)
        let filename = "\(Self.safeSessionFilenameStem(from: sessionID)).jsonl"

        return sessionsRoot
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    public func relativeBackupPath(for fileURL: URL) -> String {
        let rootComponents = backupRoot.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.starts(with: rootComponents) else {
            return fileURL.lastPathComponent
        }

        return fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private static func safeSessionFilenameStem(from sessionID: String) -> String {
        var sanitized = ""
        var previousWasSeparator = false

        for scalar in sessionID.unicodeScalars {
            if scalar.isSafeFilenameScalar {
                sanitized.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                sanitized.append("-")
                previousWasSeparator = true
            }
        }

        let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "session" : trimmed
    }
}

private extension Unicode.Scalar {
    var isSafeFilenameScalar: Bool {
        ("a"..."z").contains(self)
            || ("A"..."Z").contains(self)
            || ("0"..."9").contains(self)
            || self == "-"
            || self == "_"
    }
}
