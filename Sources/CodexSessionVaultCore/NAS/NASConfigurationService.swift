import Foundation

public enum NASConfigurationError: Error, Equatable, Sendable {
    case configurationMissing
    case invalidDeviceMarker(String)
    case writeProbeFailed(String)
}

extension NASConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationMissing:
            return "尚未配置公司 NAS 会话备份。"
        case let .invalidDeviceMarker(path):
            return "NAS 设备标识不匹配：\(path)"
        case let .writeProbeFailed(message):
            return "NAS 写入验证失败：\(message)"
        }
    }
}

public struct NASWriteProbe {
    private let verification: (URL) throws -> Void

    public init(verification: ((URL) throws -> Void)? = nil) {
        self.verification = verification ?? Self.verifyDirectory
    }

    public init(_ verification: @escaping (URL) throws -> Void) {
        self.verification = verification
    }

    public func verify(_ directory: URL) throws {
        try verification(directory)
    }

    private static func verifyDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        let probeRoot = directory.appendingPathComponent(".codex-session-keeper-probe-\(UUID().uuidString)", isDirectory: true)
        let source = probeRoot.appendingPathComponent("write-test")
        let renamed = probeRoot.appendingPathComponent("rename-test")
        let expected = Data("codex-session-keeper-nas-probe".utf8)
        defer { try? fileManager.removeItem(at: probeRoot) }

        do {
            try fileManager.createDirectory(at: probeRoot, withIntermediateDirectories: false)
            guard fileManager.createFile(atPath: source.path, contents: nil) else {
                throw NASConfigurationError.writeProbeFailed("无法创建测试文件")
            }
            let handle = try FileHandle(forWritingTo: source)
            do {
                try handle.write(contentsOf: expected)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard try Data(contentsOf: source) == expected else {
                throw NASConfigurationError.writeProbeFailed("测试文件读取结果不一致")
            }
            try fileManager.moveItem(at: source, to: renamed)
            try fileManager.removeItem(at: renamed)
            try fileManager.removeItem(at: probeRoot)
        } catch let error as NASConfigurationError {
            throw error
        } catch {
            throw NASConfigurationError.writeProbeFailed(error.localizedDescription)
        }
    }
}

public final class NASConfigurationService {
    private let locator: CompanyNASLocator
    private let store: NASConfigurationStore
    private let localStateRoot: URL
    private let deviceName: () -> String
    private let deviceID: () -> UUID
    private let now: () -> Date
    private let writeProbe: NASWriteProbe
    private let pathValidator: NASPathValidator
    private let fileManager: FileManager

    public init(
        locator: CompanyNASLocator = CompanyNASLocator(),
        store: NASConfigurationStore,
        localStateRoot: URL,
        deviceName: @escaping () -> String = { Host.current().localizedName ?? "Mac" },
        deviceID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        writeProbe: NASWriteProbe = NASWriteProbe(),
        pathValidator: NASPathValidator = NASPathValidator(),
        fileManager: FileManager = .default
    ) {
        self.locator = locator
        self.store = store
        self.localStateRoot = localStateRoot
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.now = now
        self.writeProbe = writeProbe
        self.pathValidator = pathValidator
        self.fileManager = fileManager
    }

    public func detect() throws -> CompanyNASMount {
        try locator.locate()
    }

    public func departments() throws -> [NASDirectoryOption] {
        let mount = try locator.locate()
        return try pathValidator.directDirectories(under: mount.trustedRootURL)
    }

    public func employees(in department: String) throws -> [NASDirectoryOption] {
        let mount = try locator.locate()
        let departmentRoot = try pathValidator.resolveDirectDirectory(
            named: department,
            under: mount.trustedRootURL
        )
        return try pathValidator.directDirectories(under: departmentRoot)
    }

    public func activate(department: String, employee: String) throws -> NASBackupTarget {
        let mount = try locator.locate()
        let departmentRoot = try pathValidator.resolveDirectDirectory(
            named: department,
            under: mount.trustedRootURL
        )
        let employeeRoot = try pathValidator.resolveDirectDirectory(
            named: employee,
            under: departmentRoot
        )
        try writeProbe.verify(employeeRoot)

        let previous = try store.load()
        let selectedDeviceID = previous?.deviceID ?? deviceID()
        let selectedDeviceName = previous?.deviceName ?? deviceName()
        let devicesRoot = try pathValidator.ensureManagedDirectory(named: "devices", under: employeeRoot)
        let deviceRoot = try selectDeviceRoot(
            devicesRoot: devicesRoot,
            preferredDirectoryName: previous?.deviceDirectoryName,
            deviceID: selectedDeviceID,
            deviceName: selectedDeviceName,
            department: department,
            employee: employee
        )
        let configuration = NASBackupConfiguration(
            endpoint: locator.endpoint,
            department: department,
            employee: employee,
            deviceID: selectedDeviceID,
            deviceName: selectedDeviceName,
            deviceDirectoryName: deviceRoot.lastPathComponent
        )
        try writeMarker(configuration, to: deviceRoot)
        let backupRoot = try pathValidator.ensureManagedDirectory(
            named: "incremental-backups",
            under: deviceRoot
        )
        try writeProbe.verify(deviceRoot)
        try store.save(configuration)

        return NASBackupTarget(
            configuration: configuration,
            employeeRoot: employeeRoot,
            deviceRoot: deviceRoot,
            backupRoot: backupRoot,
            localStateRoot: localStateRoot.appendingPathComponent(selectedDeviceID.uuidString.lowercased(), isDirectory: true)
        )
    }

    public func resolveActiveTarget() throws -> NASBackupTarget {
        guard let configuration = try store.load() else {
            throw NASConfigurationError.configurationMissing
        }
        let mount = try locator.locate()
        guard configuration.endpoint == mount.endpoint else {
            throw NASConfigurationError.invalidDeviceMarker(configuration.deviceDirectoryName)
        }
        let departmentRoot = try pathValidator.resolveDirectDirectory(
            named: configuration.department,
            under: mount.trustedRootURL
        )
        let employeeRoot = try pathValidator.resolveDirectDirectory(
            named: configuration.employee,
            under: departmentRoot
        )
        let devicesRoot = try pathValidator.resolveDirectDirectory(named: "devices", under: employeeRoot)
        let deviceRoot = try pathValidator.resolveDirectDirectory(
            named: configuration.deviceDirectoryName,
            under: devicesRoot
        )
        try validateMarker(configuration, at: deviceRoot)
        let backupRoot = try pathValidator.resolveDirectDirectory(
            named: "incremental-backups",
            under: deviceRoot
        )
        try writeProbe.verify(deviceRoot)
        return NASBackupTarget(
            configuration: configuration,
            employeeRoot: employeeRoot,
            deviceRoot: deviceRoot,
            backupRoot: backupRoot,
            localStateRoot: localStateRoot.appendingPathComponent(configuration.deviceID.uuidString.lowercased(), isDirectory: true)
        )
    }

    private func selectDeviceRoot(
        devicesRoot: URL,
        preferredDirectoryName: String?,
        deviceID: UUID,
        deviceName: String,
        department: String,
        employee: String
    ) throws -> URL {
        let baseName = preferredDirectoryName ?? Self.deviceDirectoryName(deviceName: deviceName, deviceID: deviceID)
        var suffix = 1
        while true {
            let name = suffix == 1 ? baseName : "\(baseName)-\(suffix)"
            let candidate = devicesRoot.appendingPathComponent(name, isDirectory: true)
            if !fileManager.fileExists(atPath: candidate.path) {
                return try pathValidator.ensureManagedDirectory(named: name, under: devicesRoot)
            }

            let existingRoot = try pathValidator.resolveDirectDirectory(named: name, under: devicesRoot)
            if let marker = try? readMarker(from: existingRoot),
               marker.deviceID == deviceID,
               marker.endpoint == locator.endpoint,
               marker.department == department,
               marker.employee == employee,
               marker.deviceDirectoryName == name {
                return existingRoot
            }
            suffix += 1
        }
    }

    private func writeMarker(_ configuration: NASBackupConfiguration, to deviceRoot: URL) throws {
        let marker = NASDeviceMarker(
            endpoint: configuration.endpoint,
            department: configuration.department,
            employee: configuration.employee,
            deviceID: configuration.deviceID,
            deviceName: configuration.deviceName,
            deviceDirectoryName: configuration.deviceDirectoryName,
            createdAt: now()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try NASJSONFile.write(
            encoder.encode(marker),
            to: deviceRoot.appendingPathComponent("device.json"),
            fileManager: fileManager,
            createParentDirectories: false
        )
    }

    private func readMarker(from deviceRoot: URL) throws -> NASDeviceMarker {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            NASDeviceMarker.self,
            from: Data(contentsOf: deviceRoot.appendingPathComponent("device.json"))
        )
    }

    private func validateMarker(_ configuration: NASBackupConfiguration, at deviceRoot: URL) throws {
        let marker = try readMarker(from: deviceRoot)
        guard marker.endpoint == configuration.endpoint,
              marker.department == configuration.department,
              marker.employee == configuration.employee,
              marker.deviceID == configuration.deviceID,
              marker.deviceDirectoryName == configuration.deviceDirectoryName
        else {
            throw NASConfigurationError.invalidDeviceMarker(deviceRoot.path)
        }
    }

    private static func deviceDirectoryName(deviceName: String, deviceID: UUID) -> String {
        var result = ""
        var previousSeparator = false
        for scalar in deviceName.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
                result.unicodeScalars.append(scalar)
                previousSeparator = false
            } else if !previousSeparator {
                result.append("-")
                previousSeparator = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        let safeName = trimmed.isEmpty ? "device" : trimmed
        return "\(safeName)-\(deviceID.uuidString.lowercased().prefix(8))"
    }
}
