import Foundation

enum PreferenceMigration {
    static let bundleID = "io.bquick.explorer"
    static let legacyBundleID = "dev.local.explorer"
    static let marker = "explorer.migration.productionIdentity.v1"

    /// Copy only Explorer preferences, once, without replacing newer settings.
    static func run(defaults: UserDefaults = .standard, bundleID: String? = Bundle.main.bundleIdentifier) {
        guard bundleID == Self.bundleID else { return }
        let current = defaults.persistentDomain(forName: Self.bundleID) ?? [:]
        guard current[marker] as? Bool != true else { return }
        let legacy = defaults.persistentDomain(forName: legacyBundleID) ?? [:]
        defaults.setPersistentDomain(migratedDomain(current: current, legacy: legacy), forName: Self.bundleID)
    }
    static func migratedDomain(current: [String: Any], legacy: [String: Any]) -> [String: Any] {
        guard current[marker] as? Bool != true else { return current }
        var result = current
        for (key, value) in legacy where key.hasPrefix("explorer.") && current[key] == nil && key != marker {
            result[key] = value
        }
        result[marker] = true
        return result
    }
}
