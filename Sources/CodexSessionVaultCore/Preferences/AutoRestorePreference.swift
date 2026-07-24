import Foundation

public enum AutoRestorePreference {
    public static let valueKey = "autoRestoreOnLaunch"
    public static let migrationKey = "autoRestoreDefaultOffMigrationV1"

    public static func load(from defaults: UserDefaults = .standard) -> Bool {
        guard defaults.bool(forKey: migrationKey) else {
            defaults.set(false, forKey: valueKey)
            defaults.set(true, forKey: migrationKey)
            return false
        }
        return defaults.bool(forKey: valueKey)
    }

    public static func save(_ enabled: Bool, to defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: migrationKey)
        defaults.set(enabled, forKey: valueKey)
    }
}
