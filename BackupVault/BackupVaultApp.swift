import SwiftUI

@main
struct BackupVaultApp: App {
    @StateObject private var api    = APIService()
    @StateObject private var store  = ConfigStore()

    var body: some Scene {

        // ── Main Window ──────────────────────────────────────────────
        WindowGroup("BackupVault", id: "main") {
            ContentView()
                .environmentObject(api)
                .environmentObject(store)
                .frame(minWidth: 960, idealWidth: 1160,
                       minHeight: 640, idealHeight: 780)
                .onAppear {
                    Task {
                        await api.checkHealth()
                        await api.fetchBackups()
                    }
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .defaultSize(width: 1160, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Atualizar Backups") {
                    Task { await api.fetchBackups() }
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("Verificar Conexão") {
                    Task { await api.checkHealth() }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        // ── Menu Bar Extra ───────────────────────────────────────────
        MenuBarExtra {
            MenuBarView()
                .environmentObject(api)
                .environmentObject(store)
        } label: {
            let img = api.isConnected
                ? "externaldrive.badge.checkmark"
                : "externaldrive.badge.exclamationmark"
            Image(systemName: img)
                .symbolRenderingMode(.hierarchical)
        }
        .menuBarExtraStyle(.window)

        // ── Settings ─────────────────────────────────────────────────
        Settings {
            SettingsView()
                .environmentObject(api)
                .environmentObject(store)
        }
    }
}
