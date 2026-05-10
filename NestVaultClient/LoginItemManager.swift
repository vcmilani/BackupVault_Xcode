import Foundation
import ServiceManagement

@MainActor
final class LoginItemManager: ObservableObject {

    @Published var isEnabled: Bool = false
    @Published var requiresApproval: Bool = false
    @Published var lastError: String?

    init() { refresh() }

    func refresh() {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = true
            requiresApproval = true
        case .notFound, .notRegistered:
            isEnabled = false
            requiresApproval = false
        @unknown default:
            isEnabled = false
        }
    }

    func toggle(_ enable: Bool) {
        lastError = nil
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        // TODO: Remover após algumas versões — usado apenas para migração de bundle ID
        UserDefaults.standard.set(isEnabled, forKey: "loginItem.wasEnabled")
    }

    /// Opens System Settings → General → Login Items so user can approve.
    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
