import Foundation
import Testing

@Suite(.serialized)
struct MacNASWiringContractTests {
    @Test
    func appUsesNASRuntimeAndLogicalRecoveryIdentityWithoutLocalFallback() throws {
        let source = try macAppSource()

        #expect(source.contains("startLocalIncrementalBackup") == false)
        #expect(source.contains("private var localBackupAgent") == false)
        #expect(source.contains("incrementalRecoverySource: NASRecoverySourceIdentity?"))
        #expect(source.contains("IncrementalRecoveryRestorer(paths:"))
        #expect(source.contains("BackupRecoveryBuilder(paths:") == false)
        #expect(source.contains("@Published private(set) var nasSetupSnapshot"))
        #expect(source.contains("@Published var nasDepartments"))
        #expect(source.contains("@Published var nasEmployees"))
        #expect(source.contains("@Published var nasRecoverySources"))
    }

    @Test
    func firstRunSetupHasNoPathFieldAndCannotBeDismissedWhileUnconfigured() throws {
        let source = try macAppSource()

        #expect(source.contains("struct NASSetupView: View"))
        #expect(source.contains("检测公司 NAS"))
        #expect(source.contains("刷新列表"))
        #expect(source.contains("更换 NAS 备份身份"))
        #expect(source.contains("interactiveDismissDisabled(model.nasSetupSnapshot.state == .unconfigured)"))
        #expect(source.contains("fileImporter") == false)
    }

    @Test
    func terminationGuardWarnsOnlyForSeedingOrPendingNASWork() throws {
        let source = try macAppSource()

        #expect(source.contains("applicationShouldTerminate"))
        #expect(source.contains("NAS 备份尚未完成，仍要退出吗？"))
        #expect(source.contains("nasSetupSnapshot.state == .seeding"))
        #expect(source.contains("nasSetupSnapshot.state == .pending"))
    }

    private func macAppSource() throws -> String {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return try String(
            contentsOf: root.appendingPathComponent("Sources/CodexSessionVault/main.swift"),
            encoding: .utf8
        )
    }
}
