import Foundation

public enum SnapshotPathValidationError: Error, LocalizedError, Equatable {
    case invalidSnapshotID(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotID(let snapshotID):
            return "快照 ID 不安全，已拒绝操作：\(snapshotID)"
        }
    }
}

public enum SnapshotPathValidator {
    public static func resolve(_ snapshotID: String, under root: URL) throws -> URL {
        guard isSafeSnapshotID(snapshotID) else {
            throw SnapshotPathValidationError.invalidSnapshotID(snapshotID)
        }

        let standardizedRoot = root.standardizedFileURL
        let resolved = standardizedRoot
            .appendingPathComponent(snapshotID, isDirectory: true)
            .standardizedFileURL
        guard resolved.deletingLastPathComponent().standardizedFileURL == standardizedRoot else {
            throw SnapshotPathValidationError.invalidSnapshotID(snapshotID)
        }
        return resolved
    }

    public static func resolve(
        _ snapshotID: String,
        under root: URL,
        matching directory: URL
    ) throws -> URL {
        let resolved = try resolve(snapshotID, under: root)
        guard resolved == directory.standardizedFileURL else {
            throw SnapshotPathValidationError.invalidSnapshotID(snapshotID)
        }
        return resolved
    }

    private static func isSafeSnapshotID(_ snapshotID: String) -> Bool {
        guard !snapshotID.isEmpty,
              snapshotID != ".",
              snapshotID != "..",
              !snapshotID.contains("\0"),
              !snapshotID.contains("/"),
              !snapshotID.contains("\\") else {
            return false
        }

        let characters = Array(snapshotID)
        let hasWindowsDrivePrefix = characters.count >= 2
            && characters[0].isASCII
            && characters[0].isLetter
            && characters[1] == ":"
        return !hasWindowsDrivePrefix
    }
}
