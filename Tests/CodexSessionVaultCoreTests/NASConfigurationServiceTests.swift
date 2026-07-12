import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite(.serialized)
struct NASConfigurationServiceTests {
    @Test
    func catalogReturnsOnlySafeDirectDepartmentAndEmployeeDirectories() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("开发部", employees: ["李雷"])
        try fixture.createDepartment("运营部", employees: ["陈超", "韩梅梅"])
        try Data("ignore".utf8).write(to: fixture.trustedRoot.appendingPathComponent("说明.txt"))
        let outside = fixture.tempRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: fixture.trustedRoot.appendingPathComponent("链接部门"),
            withDestinationURL: outside
        )

        let service = fixture.makeService()
        let departments = try service.departments()
        let employees = try service.employees(in: "运营部")

        #expect(departments.map(\.name) == ["开发部", "运营部"])
        #expect(employees.map(\.name) == ["陈超", "韩梅梅"])
    }

    @Test(arguments: ["", ".", "..", "../运营部", "运营部/陈超", "运营部\\陈超", "/tmp", "C:\\temp", "\\\\server\\share", "bad\0name"])
    func rejectsUnsafeCatalogComponents(value: String) throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])

        #expect(throws: NASPathValidationError.invalidComponent(value)) {
            _ = try fixture.makeService().employees(in: value)
        }
    }

    @Test
    func activationCreatesOnlyManagedDeviceTreeAndPersistsLogicalIdentity() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])
        let service = fixture.makeService()

        let target = try service.activate(department: "运营部", employee: "陈超")
        let saved = try fixture.store.load()
        let markerData = try Data(contentsOf: target.deviceRoot.appendingPathComponent("device.json"))
        let marker = try JSONDecoder.iso8601.decode(NASDeviceMarker.self, from: markerData)

        #expect(target.configuration.department == "运营部")
        #expect(target.configuration.employee == "陈超")
        #expect(target.configuration.deviceID == fixture.deviceID)
        #expect(target.configuration.deviceName == "Mac mini 陈超")
        #expect(target.backupRoot.lastPathComponent == "incremental-backups")
        #expect(saved == target.configuration)
        #expect(marker.deviceID == fixture.deviceID)
        #expect(marker.deviceDirectoryName == target.deviceRoot.lastPathComponent)
        #expect(FileManager.default.fileExists(atPath: target.backupRoot.path))
        #expect(FileManager.default.fileExists(atPath: target.employeeRoot.appendingPathComponent("devices").path))
    }

    @Test
    func activationReusesSavedDeviceIdentity() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])
        let first = try fixture.makeService().activate(department: "运营部", employee: "陈超")
        let secondService = fixture.makeService(deviceID: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

        let second = try secondService.activate(department: "运营部", employee: "陈超")

        #expect(second.configuration.deviceID == first.configuration.deviceID)
        #expect(second.deviceRoot == first.deviceRoot)
    }

    @Test
    func resolvesSavedTargetOnlyAfterMarkerRevalidation() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])
        let service = fixture.makeService()
        let activated = try service.activate(department: "运营部", employee: "陈超")

        let resolved = try service.resolveActiveTarget()

        #expect(resolved.configuration == activated.configuration)
        #expect(resolved.deviceRoot.path == activated.deviceRoot.path)
        #expect(resolved.backupRoot.path == activated.backupRoot.path)
    }

    @Test
    func rejectsSavedTargetAfterMarkerIdentityChanges() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])
        let service = fixture.makeService()
        let activated = try service.activate(department: "运营部", employee: "陈超")
        let markerURL = activated.deviceRoot.appendingPathComponent("device.json")
        var marker = try JSONDecoder.iso8601.decode(NASDeviceMarker.self, from: Data(contentsOf: markerURL))
        marker = NASDeviceMarker(
            endpoint: marker.endpoint,
            department: marker.department,
            employee: marker.employee,
            deviceID: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            deviceName: marker.deviceName,
            deviceDirectoryName: marker.deviceDirectoryName,
            createdAt: marker.createdAt
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: markerURL, options: .atomic)

        #expect(throws: NASConfigurationError.invalidDeviceMarker(activated.deviceRoot.path)) {
            _ = try service.resolveActiveTarget()
        }
    }

    @Test
    func activationDoesNotOverwriteCollidingDeviceMarker() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        let employeeRoot = try fixture.createDepartment("运营部", employees: ["陈超"])[0]
        let devicesRoot = employeeRoot.appendingPathComponent("devices", isDirectory: true)
        let collidingName = "Mac-mini-\(fixture.deviceID.uuidString.lowercased().prefix(8))"
        let collidingRoot = devicesRoot.appendingPathComponent(collidingName, isDirectory: true)
        try FileManager.default.createDirectory(at: collidingRoot, withIntermediateDirectories: true)
        let foreignMarker = NASDeviceMarker(
            version: 1,
            endpoint: .production,
            department: "运营部",
            employee: "陈超",
            deviceID: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            deviceName: "Foreign",
            deviceDirectoryName: collidingName,
            createdAt: fixture.now
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(foreignMarker).write(to: collidingRoot.appendingPathComponent("device.json"))
        #expect(FileManager.default.fileExists(atPath: collidingRoot.path))
        #expect(FileManager.default.fileExists(atPath: collidingRoot.appendingPathComponent("device.json").path))
        let markerBeforeActivation = try JSONDecoder.iso8601.decode(
            NASDeviceMarker.self,
            from: Data(contentsOf: collidingRoot.appendingPathComponent("device.json"))
        )
        #expect(markerBeforeActivation.deviceID == foreignMarker.deviceID)

        let target = try fixture.makeService(deviceName: "Mac mini").activate(department: "运营部", employee: "陈超")
        let preserved = try JSONDecoder.iso8601.decode(
            NASDeviceMarker.self,
            from: Data(contentsOf: collidingRoot.appendingPathComponent("device.json"))
        )

        #expect(target.deviceRoot.path != collidingRoot.path)
        #expect(target.deviceRoot.lastPathComponent == "\(collidingName)-2")
        #expect(preserved.deviceID == foreignMarker.deviceID)
    }

    @Test
    func activationFailureDoesNotPersistConfiguration() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        try fixture.createDepartment("运营部", employees: ["陈超"])
        let service = fixture.makeService(
            writeProbe: NASWriteProbe { _ in
                throw NASConfigurationError.writeProbeFailed("injected")
            }
        )

        #expect(throws: NASConfigurationError.writeProbeFailed("injected")) {
            _ = try service.activate(department: "运营部", employee: "陈超")
        }
        #expect(try fixture.store.load() == nil)
    }

    @Test
    func remoteJSONWriteDoesNotCreateMissingParentDirectories() throws {
        let fixture = try NASConfigurationFixture()
        defer { fixture.cleanup() }
        let missingParent = fixture.tempRoot.appendingPathComponent("missing/device", isDirectory: true)
        let destination = missingParent.appendingPathComponent("device.json")

        do {
            try NASJSONFile.write(
                Data("{}".utf8),
                to: destination,
                fileManager: .default,
                createParentDirectories: false
            )
            Issue.record("Expected remote JSON write to reject a missing parent")
        } catch {}

        #expect(FileManager.default.fileExists(atPath: missingParent.path) == false)
    }
}

private final class NASConfigurationFixture {
    let tempRoot: URL
    let mountRoot: URL
    let trustedRoot: URL
    let localStateRoot: URL
    let store: NASConfigurationStore
    let deviceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let now = Date(timeIntervalSince1970: 1_783_824_000)
    private let remountURL: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NASConfigurationServiceTests-\(UUID().uuidString)", isDirectory: true)
        mountRoot = tempRoot.appendingPathComponent("文件中转站", isDirectory: true)
        trustedRoot = mountRoot.appendingPathComponent("codex会话备份", isDirectory: true)
        localStateRoot = tempRoot.appendingPathComponent("local-state", isDirectory: true)
        store = NASConfigurationStore(
            fileURL: localStateRoot.appendingPathComponent("nas-backup-settings.json")
        )
        remountURL = try #require(URL(string: "smb://171@192.168.10.99/%E6%96%87%E4%BB%B6%E4%B8%AD%E8%BD%AC%E7%AB%99"))
        try FileManager.default.createDirectory(at: trustedRoot, withIntermediateDirectories: true)
    }

    @discardableResult
    func createDepartment(_ name: String, employees: [String]) throws -> [URL] {
        let department = trustedRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: department, withIntermediateDirectories: true)
        return try employees.map { employee in
            let employeeRoot = department.appendingPathComponent(employee, isDirectory: true)
            try FileManager.default.createDirectory(at: employeeRoot, withIntermediateDirectories: true)
            return employeeRoot
        }
    }

    func makeService(
        deviceID: UUID? = nil,
        deviceName: String = "Mac mini 陈超",
        writeProbe: NASWriteProbe = NASWriteProbe()
    ) -> NASConfigurationService {
        let locator = CompanyNASLocator(
            mountedVolumes: {
                [NASMountedVolume(rootURL: self.mountRoot, remountURL: self.remountURL)]
            }
        )
        return NASConfigurationService(
            locator: locator,
            store: store,
            localStateRoot: localStateRoot,
            deviceName: { deviceName },
            deviceID: { deviceID ?? self.deviceID },
            now: { self.now },
            writeProbe: writeProbe
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tempRoot)
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
