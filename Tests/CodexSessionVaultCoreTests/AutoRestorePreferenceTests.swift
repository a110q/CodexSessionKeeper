import Foundation
import Testing
@testable import CodexSessionVaultCore

@Suite("AutoRestorePreference")
struct AutoRestorePreferenceTests {
    @Test
    func firstMigrationForcesDefaultOffExactlyOnce() throws {
        let suite = "auto-restore-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AutoRestorePreference.valueKey)

        #expect(AutoRestorePreference.load(from: defaults) == false)
        #expect(defaults.bool(forKey: AutoRestorePreference.migrationKey))
    }

    @Test
    func explicitChoicePersistsAfterMigration() throws {
        let suite = "auto-restore-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        _ = AutoRestorePreference.load(from: defaults)
        AutoRestorePreference.save(true, to: defaults)

        #expect(AutoRestorePreference.load(from: defaults))
    }
}
