import Darwin
import Foundation

public enum LocalVaultPermissionHardeningError: Error, LocalizedError, Equatable {
    case rootIsSymbolicLink(String)
    case rootIsNotDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .rootIsSymbolicLink(path):
            "本地仓库不能是符号链接：\(path)"
        case let .rootIsNotDirectory(path):
            "本地仓库路径不是目录：\(path)"
        }
    }
}

public struct LocalVaultPermissionHardener {
    private static let directoryPermissions: NSNumber = 0o700
    private static let filePermissions: NSNumber = 0o600
    private static let markerName = ".local-permissions-v1"

    private let fileManager: FileManager
    private let setPermissions: (URL, NSNumber) throws -> Void

    public init() {
        self.init(fileManager: .default, setPermissions: nil)
    }

    init(
        fileManager: FileManager = .default,
        setPermissions: ((URL, NSNumber) throws -> Void)?
    ) {
        self.fileManager = fileManager
        self.setPermissions = setPermissions ?? { url, permissions in
            try fileManager.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
    }

    public func prepareVault(at root: URL) throws {
        let root = root.standardizedFileURL
        let originalEntry = try entry(at: root)
        if originalEntry == nil {
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: Self.directoryPermissions]
            )
        }

        let createdOrExistingEntry = try requiredEntry(at: root)
        switch createdOrExistingEntry.kind {
        case .symbolicLink:
            throw LocalVaultPermissionHardeningError.rootIsSymbolicLink(root.path)
        case .directory:
            break
        case .regularFile, .other:
            throw LocalVaultPermissionHardeningError.rootIsNotDirectory(root.path)
        }

        let rootWasPrivate = originalEntry?.kind == .directory
            && originalEntry?.permissions == Self.directoryPermissions.intValue
        let markerURL = root.appendingPathComponent(Self.markerName, isDirectory: false)
        let migrationIsCurrent = try rootWasPrivate && markerIsValid(at: markerURL)
        if !migrationIsCurrent {
            try removeMarkerIfPresent(at: markerURL)
        }

        try setPermissions(root, Self.directoryPermissions)
        if migrationIsCurrent { return }
        try hardenTree(at: root)
        let marker = try JSONEncoder().encode(PermissionMarker(version: 1))
        try DurableAtomicWriter(fileManager: fileManager).write(
            marker,
            to: markerURL,
            permissions: Self.filePermissions,
            parentDirectoryPermissions: Self.directoryPermissions,
            createParentDirectories: false
        )
    }

    public func hardenTree(at root: URL) throws {
        let root = root.standardizedFileURL
        let rootEntry = try requiredEntry(at: root)
        switch rootEntry.kind {
        case .symbolicLink:
            throw LocalVaultPermissionHardeningError.rootIsSymbolicLink(root.path)
        case .directory:
            try setPermissions(root, Self.directoryPermissions)
        case .regularFile, .other:
            throw LocalVaultPermissionHardeningError.rootIsNotDirectory(root.path)
        }
        try hardenDirectoryContents(root)
    }

    private func hardenDirectoryContents(_ directory: URL) throws {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: []
        )
        for child in children {
            let childEntry = try requiredEntry(at: child)
            switch childEntry.kind {
            case .directory:
                try setPermissions(child, Self.directoryPermissions)
                try hardenDirectoryContents(child)
            case .regularFile:
                try setPermissions(child, Self.filePermissions)
            case .symbolicLink, .other:
                continue
            }
        }
    }

    private func markerIsValid(at markerURL: URL) throws -> Bool {
        guard let markerEntry = try entry(at: markerURL),
              markerEntry.kind == .regularFile,
              markerEntry.permissions == Self.filePermissions.intValue,
              let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(PermissionMarker.self, from: data)
        else {
            return false
        }
        return marker.version == 1
    }

    private func removeMarkerIfPresent(at markerURL: URL) throws {
        guard try entry(at: markerURL) != nil else { return }
        try fileManager.removeItem(at: markerURL)
    }

    private func requiredEntry(at url: URL) throws -> FileSystemEntry {
        guard let result = try entry(at: url) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return result
    }

    private func entry(at url: URL) throws -> FileSystemEntry? {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        let mode = mode_t(info.st_mode)
        let kind: FileSystemEntry.Kind
        switch mode & mode_t(S_IFMT) {
        case mode_t(S_IFDIR): kind = .directory
        case mode_t(S_IFREG): kind = .regularFile
        case mode_t(S_IFLNK): kind = .symbolicLink
        default: kind = .other
        }
        return FileSystemEntry(kind: kind, permissions: Int(mode & 0o777))
    }
}

private struct PermissionMarker: Codable {
    let version: Int
}

private struct FileSystemEntry {
    enum Kind: Equatable {
        case directory
        case regularFile
        case symbolicLink
        case other
    }

    let kind: Kind
    let permissions: Int
}
