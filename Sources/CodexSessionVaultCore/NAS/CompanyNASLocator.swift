import Foundation

public enum CompanyNASLocatorError: Error, Equatable, Sendable {
    case notConnected
    case trustedRootMissing(String)
    case invalidTrustedRoot(String)
}

extension CompanyNASLocatorError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notConnected:
            return "公司 NAS 未连接。"
        case let .trustedRootMissing(path):
            return "公司 NAS 备份根目录不存在：\(path)"
        case let .invalidTrustedRoot(path):
            return "公司 NAS 备份根目录不是可信的真实目录：\(path)"
        }
    }
}

public final class CompanyNASLocator {
    public let endpoint: CompanyNASEndpoint

    private let mountedVolumes: () -> [NASMountedVolume]
    private let fileManager: FileManager

    public init(
        endpoint: CompanyNASEndpoint = .production,
        mountedVolumes: (() -> [NASMountedVolume])? = nil,
        fileManager: FileManager = .default
    ) {
        self.endpoint = endpoint
        self.mountedVolumes = mountedVolumes ?? CompanyNASLocator.systemMountedVolumes
        self.fileManager = fileManager
    }

    public func locate() throws -> CompanyNASMount {
        guard let volume = mountedVolumes().first(where: isTrustedVolume) else {
            throw CompanyNASLocatorError.notConnected
        }

        let mountRoot = volume.rootURL.standardizedFileURL
        let trustedRoot = mountRoot
            .appendingPathComponent(endpoint.backupRootName, isDirectory: true)
            .standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: trustedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CompanyNASLocatorError.trustedRootMissing(trustedRoot.path)
        }

        let mountValues = try mountRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let rootValues = try trustedRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        let resolvedMount = mountRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = trustedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard mountValues.isSymbolicLink != true,
              mountValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              rootValues.isDirectory == true,
              resolvedRoot.deletingLastPathComponent() == resolvedMount
        else {
            throw CompanyNASLocatorError.invalidTrustedRoot(trustedRoot.path)
        }

        return CompanyNASMount(
            endpoint: endpoint,
            mountRootURL: mountRoot,
            trustedRootURL: trustedRoot
        )
    }

    private func isTrustedVolume(_ volume: NASMountedVolume) -> Bool {
        guard let remountURL = volume.remountURL,
              remountURL.scheme?.lowercased() == "smb",
              remountURL.host?.caseInsensitiveCompare(endpoint.server) == .orderedSame
        else {
            return false
        }

        let share = remountURL.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding ?? remountURL.path
        return share == endpoint.share
    }

    private static func systemMountedVolumes() -> [NASMountedVolume] {
        let keys: Set<URLResourceKey> = [.volumeURLForRemountingKey]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: []
        ) ?? []

        return volumes.map { rootURL in
            let values = try? rootURL.resourceValues(forKeys: keys)
            return NASMountedVolume(
                rootURL: rootURL,
                remountURL: values?.volumeURLForRemounting
            )
        }
    }
}
