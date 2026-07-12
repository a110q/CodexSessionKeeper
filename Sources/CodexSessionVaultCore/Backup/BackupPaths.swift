import Foundation

public struct BackupPaths: Sendable {
    public let homeDirectory: URL
    public let codexRoot: URL
    public let backupRoot: URL
    public let stateRoot: URL

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        codexRoot: URL? = nil,
        backupRoot: URL? = nil,
        stateRoot: URL? = nil
    ) {
        let resolvedBackupRoot = backupRoot
            ?? homeDirectory
                .appendingPathComponent(".codex-session-vault", isDirectory: true)
                .appendingPathComponent("incremental-backups", isDirectory: true)
        self.homeDirectory = homeDirectory
        self.codexRoot = codexRoot ?? homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        self.backupRoot = resolvedBackupRoot
        self.stateRoot = stateRoot ?? resolvedBackupRoot
    }

    public var sessionsRoot: URL {
        backupRoot.appendingPathComponent("sessions", isDirectory: true)
    }

    public var archivedSessionsRoot: URL {
        backupRoot.appendingPathComponent("archived_sessions", isDirectory: true)
    }

    public var manifestURL: URL {
        backupRoot.appendingPathComponent("manifest.json", isDirectory: false)
    }

    public var cursorDatabaseURL: URL {
        stateRoot.appendingPathComponent("cursors.sqlite", isDirectory: false)
    }

    public var remoteStatusURL: URL {
        backupRoot.appendingPathComponent("status.json", isDirectory: false)
    }

    public var localStatusURL: URL {
        stateRoot.appendingPathComponent("status.json", isDirectory: false)
    }

    public var statusURL: URL {
        remoteStatusURL
    }

    public var logURL: URL {
        stateRoot
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("backup-agent.log", isDirectory: false)
    }

    public func backupFileURL(for sourceURL: URL) throws -> URL {
        let source = sourceURL.standardizedFileURL
        guard source.pathExtension.lowercased() == "jsonl" else {
            throw BackupPathsError.sourceIsNotJSONL(source.path)
        }

        let sourceRoots = [
            ("sessions", codexRoot.appendingPathComponent("sessions", isDirectory: true)),
            ("archived_sessions", codexRoot.appendingPathComponent("archived_sessions", isDirectory: true))
        ]
        for (destinationRootName, sourceRoot) in sourceRoots {
            let rootComponents = sourceRoot.standardizedFileURL.pathComponents
            let sourceComponents = source.pathComponents
            guard sourceComponents.starts(with: rootComponents), sourceComponents.count > rootComponents.count else {
                continue
            }
            do {
                try RestoreFilesystemValidator.validateSource(source, under: sourceRoot)
            } catch {
                throw BackupPathsError.unsafeSource(source.path)
            }

            let relativeComponents = sourceComponents.dropFirst(rootComponents.count)
            var destination = backupRoot.appendingPathComponent(destinationRootName, isDirectory: true)
            for (index, component) in relativeComponents.enumerated() {
                destination = destination.appendingPathComponent(
                    component,
                    isDirectory: index < relativeComponents.count - 1
                )
            }
            guard relativeBackupPath(for: destination) != nil else {
                throw BackupPathsError.unsafeSource(source.path)
            }
            return destination
        }

        throw BackupPathsError.sourceOutsideCodexSessionRoots(source.path)
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

    public func relativeBackupPath(for fileURL: URL) -> String? {
        let rootComponents = backupRoot.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents

        guard fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else {
            return nil
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

public enum BackupPathsError: Error, Equatable, Sendable {
    case sourceOutsideCodexSessionRoots(String)
    case sourceIsNotJSONL(String)
    case unsafeSource(String)
}

extension BackupPathsError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .sourceOutsideCodexSessionRoots(path):
            return "会话文件不在 Codex sessions 或 archived_sessions 目录内：\(path)"
        case let .sourceIsNotJSONL(path):
            return "会话备份只接受 JSONL 文件：\(path)"
        case let .unsafeSource(path):
            return "会话文件包含不可信的链接或路径：\(path)"
        }
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
