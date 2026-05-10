import Foundation

// TODO: Remover após algumas versões — migração de com.vcm.backupvault.app para com.vcm.nestvaultclient.app
enum LegacyMigration {

    private static let migratedFlag = "nestvault.migrated_from_backupvault_v1"
    private static let oldBundleID  = "com.vcm.backupvault.app"

    private static let keys: [String] = [
        "backupProfiles_v1",
        "server_url",
        "api_key",
        "queue.schedule.config",
        "queue.schedule.lastRun",
        "schedule.pauseOnBattery",
        "schedule.minBatteryPercent",
        "loginItem.wasEnabled",
    ]

    /// True se o login item estava ativo no bundle antigo — verificar após chamar runIfNeeded().
    static private(set) var loginItemWasEnabled = false

    /// Executa uma única vez. Deve ser chamado no init() do App, antes de qualquer @StateObject.
    static func runIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: migratedFlag) else { return }

        let old = UserDefaults(suiteName: oldBundleID)
        let hasOldData = keys.contains { old?.object(forKey: $0) != nil }

        if hasOldData, let old {
            for key in keys {
                if let value = old.object(forKey: key) {
                    UserDefaults.standard.set(value, forKey: key)
                }
            }
            loginItemWasEnabled = old.bool(forKey: "loginItem.wasEnabled")

            for key in keys { old.removeObject(forKey: key) }
        }

        UserDefaults.standard.set(true, forKey: migratedFlag)
    }
}
