import Foundation

public struct CompanyNASEndpoint: Codable, Equatable, Sendable {
    public static let production = CompanyNASEndpoint(
        server: "192.168.10.99",
        share: "文件中转站",
        backupRootName: "codex会话备份"
    )

    public let server: String
    public let share: String
    public let backupRootName: String

    public init(server: String, share: String, backupRootName: String) {
        self.server = server
        self.share = share
        self.backupRootName = backupRootName
    }
}

public struct NASMountedVolume: Equatable, Sendable {
    public let rootURL: URL
    public let remountURL: URL?

    public init(rootURL: URL, remountURL: URL?) {
        self.rootURL = rootURL
        self.remountURL = remountURL
    }
}

public struct CompanyNASMount: Equatable, Sendable {
    public let endpoint: CompanyNASEndpoint
    public let mountRootURL: URL
    public let trustedRootURL: URL

    public init(endpoint: CompanyNASEndpoint, mountRootURL: URL, trustedRootURL: URL) {
        self.endpoint = endpoint
        self.mountRootURL = mountRootURL
        self.trustedRootURL = trustedRootURL
    }
}

public struct NASDirectoryOption: Codable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct NASBackupConfiguration: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: CompanyNASEndpoint
    public let department: String
    public let employee: String
    public let deviceID: UUID
    public let deviceName: String
    public let deviceDirectoryName: String

    public init(
        version: Int = 1,
        endpoint: CompanyNASEndpoint,
        department: String,
        employee: String,
        deviceID: UUID,
        deviceName: String,
        deviceDirectoryName: String
    ) {
        self.version = version
        self.endpoint = endpoint
        self.department = department
        self.employee = employee
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceDirectoryName = deviceDirectoryName
    }
}

public struct NASDeviceMarker: Codable, Equatable, Sendable {
    public let version: Int
    public let endpoint: CompanyNASEndpoint
    public let department: String
    public let employee: String
    public let deviceID: UUID
    public let deviceName: String
    public let deviceDirectoryName: String
    public let createdAt: Date

    public init(
        version: Int = 1,
        endpoint: CompanyNASEndpoint,
        department: String,
        employee: String,
        deviceID: UUID,
        deviceName: String,
        deviceDirectoryName: String,
        createdAt: Date
    ) {
        self.version = version
        self.endpoint = endpoint
        self.department = department
        self.employee = employee
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceDirectoryName = deviceDirectoryName
        self.createdAt = createdAt
    }
}

public struct NASBackupTarget: Equatable, Sendable {
    public let configuration: NASBackupConfiguration
    public let employeeRoot: URL
    public let deviceRoot: URL
    public let backupRoot: URL
    public let localStateRoot: URL

    public init(
        configuration: NASBackupConfiguration,
        employeeRoot: URL,
        deviceRoot: URL,
        backupRoot: URL,
        localStateRoot: URL
    ) {
        self.configuration = configuration
        self.employeeRoot = employeeRoot
        self.deviceRoot = deviceRoot
        self.backupRoot = backupRoot
        self.localStateRoot = localStateRoot
    }
}

public struct NASRecoverySourceIdentity: Codable, Equatable, Hashable, Sendable {
    public let department: String
    public let employee: String
    public let deviceID: UUID
    public let deviceDirectoryName: String

    public init(department: String, employee: String, deviceID: UUID, deviceDirectoryName: String) {
        self.department = department
        self.employee = employee
        self.deviceID = deviceID
        self.deviceDirectoryName = deviceDirectoryName
    }
}

public struct NASRecoverySource: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID { identity.deviceID }
    public let identity: NASRecoverySourceIdentity
    public let deviceName: String
    public let lastBackupAt: Date?
    public let isCurrentDevice: Bool

    public init(
        identity: NASRecoverySourceIdentity,
        deviceName: String,
        lastBackupAt: Date?,
        isCurrentDevice: Bool
    ) {
        self.identity = identity
        self.deviceName = deviceName
        self.lastBackupAt = lastBackupAt
        self.isCurrentDevice = isCurrentDevice
    }
}
