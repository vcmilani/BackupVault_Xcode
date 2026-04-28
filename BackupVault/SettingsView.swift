import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var api: APIService
    @State private var isTesting = false
    @State private var testMsg: String?
    @State private var testOK   = false
    @State private var showKey  = false

    var body: some View {
        TabView {
            serverTab.tabItem { Label("Servidor", systemImage: "network") }
            aboutTab.tabItem  { Label("Sobre",    systemImage: "info.circle") }
        }
        .padding(6)
        .frame(width: 520)
        .fixedSize()
    }

    // MARK: - Server Tab
    var serverTab: some View {
        Form {
            Section("Conexão") {
                LabeledContent("URL do Servidor") {
                    TextField("http://192.168.1.100:8000", text: $api.serverURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .font(.body.monospaced())
                        .onChange(of: api.serverURL) { _,_ in testMsg = nil }
                }

                LabeledContent("API Key") {
                    HStack {
                        if showKey {
                            TextField("Vazio = sem autenticação", text: $api.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        } else {
                            SecureField("Vazio = sem autenticação", text: $api.apiKey)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 240)
                        }
                        Button(showKey ? "Ocultar" : "Mostrar") {
                            showKey.toggle()
                        }
                        .font(.caption)
                    }
                }

                LabeledContent("Status Atual") {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(api.isConnected ? Color.green.opacity(0.2) : Color.red.opacity(0.2))
                                .frame(width: 18, height: 18)
                            Circle()
                                .fill(api.isConnected ? Color.green : Color.red)
                                .frame(width: 8, height: 8)
                        }
                        Text(api.isConnected ? "Conectado" : (api.connectionError ?? "Desconectado"))
                            .foregroundStyle(api.isConnected ? .green : .red)
                            .font(.subheadline)
                    }
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Salvar e Testar Conexão") {
                        api.saveSettings()
                        isTesting = true
                        testMsg = nil
                        Task {
                            await api.checkHealth()
                            if api.isConnected {
                                await api.fetchBackups()
                                testOK = true
                                testMsg = "Conectado! \(api.backups.count) backup(s) encontrado(s)."
                            } else {
                                testOK = false
                                testMsg = api.connectionError ?? "Falha na conexão."
                            }
                            isTesting = false
                        }
                    }
                    .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }

                if let msg = testMsg {
                    HStack {
                        Image(systemName: testOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(testOK ? .green : .red)
                        Text(msg)
                            .font(.subheadline)
                            .foregroundStyle(testOK ? .green : .red)
                    }
                }
            }

            Section("Dicas de Configuração") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsTip(icon: "key.fill",      color: .orange,  text: "A API Key deve ser a mesma definida na variável BACKUP_API_KEY do servidor.")
                    SettingsTip(icon: "network",        color: .blue,    text: "Use o IP local da Raspberry Pi (ex: 192.168.1.100) e porta 8000.")
                    SettingsTip(icon: "wifi.slash",     color: .red,     text: "Se o servidor não responder, verifique se o serviço systemd está rodando com 'systemctl status backup-server'.")
                }
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }

    // MARK: - About Tab
    var aboutTab: some View {
        Form {
            Section("BackupVault para macOS") {
                LabeledContent("Versão", value: "1.0.0")
                LabeledContent("Mínimo macOS", value: "14.0 (Sonoma)")
                LabeledContent("Servidor", value: "FastAPI + SQLite + SHA-256")
            }
            Section("Repositório") {
                LabeledContent("GitHub") {
                    Link("vcmilani/backup_files",
                         destination: URL(string: "https://github.com/vcmilani/backup_files")!)
                }
                LabeledContent("API Docs") {
                    Link("Swagger UI (quando conectado)",
                         destination: URL(string: "\(api.serverURL)/docs")!)
                }
                LabeledContent("Dashboard Web") {
                    Link("Abrir no browser",
                         destination: URL(string: api.serverURL)!)
                }
            }
            Section("Funcionalidades") {
                LabeledContent("Deduplicação", value: "SHA-256 por conteúdo")
                LabeledContent("Versionamento", value: "Timestamp ISO 8601")
                LabeledContent("Isolamento", value: "Por label/cliente")
                LabeledContent("Limpeza", value: "Keep N versões mais recentes")
            }
        }
        .formStyle(.grouped)
        .padding(6)
    }
}

struct SettingsTip: View {
    let icon: String
    let color: Color
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
