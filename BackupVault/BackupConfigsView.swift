import SwiftUI
import AppKit

// MARK: - Configs View
struct BackupConfigsView: View {
    @EnvironmentObject var api:   APIService
    @EnvironmentObject var store: ConfigStore

    @State private var selected:    BackupProfile?
    @State private var editing:     BackupProfile?
    @State private var showAdd      = false
    @State private var showDelete   = false
    @State private var showQueue    = false
    @State private var showDeleteBackup = false
    @State private var deleteBackupError: String?

    var body: some View {
        HStack(spacing: 0) {

            // ── Left: Profile List ───────────────────────────────────
            VStack(spacing: 0) {
                HStack {
                    Text("Configurações")
                        .font(.headline)
                    Spacer()
                    Text("\(store.profiles.count)")
                        .font(.caption)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(.secondary.opacity(0.2), in: Capsule())
                        .foregroundStyle(.secondary)
                    Button { showQueue = true } label: {
                        Image(systemName: "play.rectangle.on.rectangle").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Executar fila de backups")
                    .disabled(store.profiles.filter { $0.enabled }.isEmpty)
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Nova configuração")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                if store.profiles.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.largeTitle).foregroundStyle(.secondary)
                        Text("Nenhuma configuração")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("Adicionar") { showAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(store.profiles) { profile in
                                ProfileListRow(profile: profile)
                                    .padding(.horizontal, 12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == profile
                                        ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selected = profile }
                                    .contextMenu {
                                        Button("Editar") { editing = profile }
                                        Divider()
                                        Button("Excluir configuração", role: .destructive) {
                                            selected = profile; showDelete = true
                                        }
                                        Button("Excluir do servidor…", role: .destructive) {
                                            selected = profile; showDeleteBackup = true
                                        }
                                    }
                                Divider()
                            }
                        }
                    }
                }
            }
            .frame(width: 220)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // ── Right: Detail ────────────────────────────────────────
            Group {
                if let profile = selected {
                    ProfileDetailView(
                        profile: profile,
                        defaultServer: api.serverURL,
                        onEdit: { editing = profile }
                    )
                } else {
                    PlaceholderView(
                        title: "Selecione uma configuração",
                        icon: "slider.horizontal.3",
                        description: "Escolha ou crie uma nova configuração de backup"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showQueue) {
            BackupQueueSheet()
                .environmentObject(api)
                .environmentObject(store)
        }
        .alert("Excluir backup do servidor?", isPresented: $showDeleteBackup) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir do Servidor", role: .destructive) {
                guard let label = selected?.label else { return }
                Task {
                    do {
                        try await api.deleteBackup(label: label)
                        await api.fetchBackups()
                    } catch {
                        deleteBackupError = error.localizedDescription
                    }
                }
            }
        } message: {
            let name = selected?.label ?? ""
            Text("Todos os dados e versões de \"\(name)\" serão apagados permanentemente do servidor.")
        }
        .sheet(isPresented: $showAdd) {
            ProfileEditorSheet(profile: nil, defaultServer: api.serverURL) { p in
                store.add(p); selected = p
            }
        }
        .sheet(item: $editing) { p in
            ProfileEditorSheet(profile: p, defaultServer: api.serverURL) { updated in
                store.update(updated)
                if selected?.id == updated.id { selected = updated }
            }
        }
        .alert("Excluir configuração?", isPresented: $showDelete) {
            Button("Cancelar", role: .cancel) {}
            Button("Excluir",  role: .destructive) {
                if let p = selected { store.delete(p); selected = nil }
            }
        } message: {
            let name = selected?.name ?? ""
            Text("\"\(name)\" será removida permanentemente.")
        }
    }
}

// MARK: - Profile List Row
struct ProfileListRow: View {
    let profile: BackupProfile
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(profile.enabled ? Color.blue.opacity(0.12) : Color.secondary.opacity(0.1))
                    .frame(width: 30, height: 30)
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(profile.enabled ? .blue : .secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
                Text(profile.label.isEmpty ? "sem label" : profile.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !profile.enabled {
                Image(systemName: "pause.fill")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Profile Detail View
struct ProfileDetailView: View {
    let profile: BackupProfile
    let defaultServer: String
    let onEdit: () -> Void

    @EnvironmentObject var api: APIService
    @State private var showRunner = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Text(profile.name)
                                .font(.title2.bold())
                            if !profile.enabled {
                                Text("INATIVO")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(.secondary.opacity(0.2), in: Capsule())
                            }
                        }
                        Text("Label: \(profile.label.isEmpty ? "não configurado" : profile.label)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Editar", action: onEdit)
                        .buttonStyle(.bordered)
                    Button("Executar Backup") { showRunner = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.blue)
                        .disabled(!profile.enabled || profile.sourcePath.isEmpty || profile.label.isEmpty)
                }

                Divider()

                // Grid of info cards
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    ProfileInfoCard(title: "Pasta de Origem", icon: "folder.fill", iconColor: .blue) {
                        Text(profile.sourcePath.isEmpty ? "Não configurado" : profile.sourcePath)
                            .font(.body.monospaced()).lineLimit(3)
                            .foregroundStyle(profile.sourcePath.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    ProfileInfoCard(title: "Servidor", icon: "network", iconColor: .green) {
                        Text(profile.serverOverride.isEmpty ? defaultServer : profile.serverOverride)
                            .font(.body.monospaced()).lineLimit(2)
                            .textSelection(.enabled)
                    }
                    ProfileInfoCard(title: "Workers Paralelos", icon: "cpu", iconColor: .purple) {
                        Text("\(profile.workers) workers")
                            .font(.title3.bold())
                        Text(workersDescription(profile.workers))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ProfileInfoCard(title: "Prefixo no Servidor", icon: "folder.badge.questionmark", iconColor: .orange) {
                        Text(profile.prefix.isEmpty ? "Nenhum" : profile.prefix)
                            .font(.body.monospaced())
                            .foregroundStyle(profile.prefix.isEmpty ? .secondary : .primary)
                    }
                }

                // Excludes
                if !profile.excludes.isEmpty {
                    ProfileInfoCard(title: "Exclusões (\(profile.excludes.count))", icon: "xmark.circle.fill", iconColor: .red) {
                        FlowTagsView(tags: profile.excludes, color: .red)
                    }
                }

                // CLI command preview
                ProfileInfoCard(title: "Comando equivalente (Python)", icon: "terminal.fill", iconColor: .secondary) {
                    Text(profile.cliCommand(defaultServer: defaultServer))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showRunner) {
            BackupRunnerSheet(profile: profile, api: api)
        }
    }

    func workersDescription(_ n: Int) -> String {
        switch n {
        case 1...2: return "Ideal para Pi com SD ou arquivos grandes"
        case 3...5: return "Ideal para Pi com HD externo USB"
        case 6...8: return "Ideal para Pi com SSD"
        default:    return "Alto paralelismo — muitos arquivos pequenos"
        }
    }
}

// MARK: - Info Card (Detail)
struct ProfileInfoCard<Content: View>: View {
    let title: String
    let icon:  String
    let iconColor: Color
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(iconColor)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Flow Tags
struct FlowTagsView: View {
    let tags: [String]
    let color: Color

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.3), lineWidth: 1))
            }
        }
    }
}

// MARK: - Profile Editor Sheet
struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let profile:       BackupProfile?
    let defaultServer: String
    let onSave:        (BackupProfile) -> Void

    @State private var draft:      BackupProfile
    @State private var tab         = 0

    init(profile: BackupProfile?, defaultServer: String, onSave: @escaping (BackupProfile) -> Void) {
        self.profile       = profile
        self.defaultServer = defaultServer
        self.onSave        = onSave
        self._draft        = State(initialValue: profile ?? BackupProfile())
    }

    var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.label.trimmingCharacters(in: .whitespaces).isEmpty &&
        !draft.sourcePath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Sheet toolbar
            HStack {
                Button("Cancelar") { dismiss() }
                Spacer()
                Text(profile == nil ? "Nova Configuração" : "Editar Configuração")
                    .font(.headline)
                Spacer()
                Button("Salvar") { onSave(draft); dismiss() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave)
            }
            .padding(16)

            Divider()

            // Tab picker
            Picker("", selection: $tab) {
                Label("Geral",      systemImage: "info.circle").tag(0)
                Label("Servidor",   systemImage: "network").tag(1)
                Label("Exclusões",  systemImage: "xmark.circle").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Tab content
            Group {
                if tab == 0 {
                    Form {
                        Section("Identificação") {
                            TextField("Nome da configuração", text: $draft.name)
                            TextField("Label (ex: macbook-joao)", text: $draft.label)
                                .font(.body.monospaced())
                            Toggle("Ativa", isOn: $draft.enabled)
                        }
                        Section("Origem") {
                            HStack {
                                TextField("Pasta de origem", text: $draft.sourcePath)
                                    .font(.body.monospaced())
                                Button("Escolher…") { pickFolder() }.fixedSize()
                            }
                            TextField("Prefixo no servidor (opcional)", text: $draft.prefix)
                                .font(.body.monospaced())
                        }
                    }
                    .formStyle(.grouped)
                } else if tab == 1 {
                    Form {
                        Section("Servidor") {
                            TextField("URL do servidor (vazio = padrão global)", text: $draft.serverOverride)
                                .font(.body.monospaced())
                            if draft.serverOverride.isEmpty {
                                Text("Usando padrão: \(defaultServer)")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Usando: \(draft.serverOverride)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Section("Performance") {
                            HStack {
                                Text("Workers")
                                Spacer()
                                TextField("4", value: $draft.workers, format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 60)
                                    .font(.body.monospacedDigit())
                                    .onChange(of: draft.workers) { v in
                                        if v < 1  { draft.workers = 1 }
                                        if v > 16 { draft.workers = 16 }
                                    }
                            }
                            Text("Entre 1 e 16. \(workersHint(draft.workers))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .formStyle(.grouped)
                } else {
                    ExcludesEditor(excludes: $draft.excludes)
                }
            }
        }
        .frame(width: 540, height: 480)
    }

    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.title = "Selecione a pasta de origem"
        panel.prompt = "Selecionar"
        panel.level = .modalPanel
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let response = panel.runModal()
            if response == .OK, let url = panel.url {
                draft.sourcePath = url.path
            }
        }
    }

    func workersHint(_ n: Int) -> String {
        switch n {
        case 1...2: return "Recomendado para Pi com SD ou arquivos grandes (>100 MB)"
        case 3...5: return "Recomendado para Pi com HD externo USB"
        case 6...8: return "Recomendado para Pi com SSD"
        default:    return "Alto paralelismo — ideal para muitos arquivos pequenos"
        }
    }
}

// MARK: - Excludes Editor (uses local @State for guaranteed re-render)

struct ExcludesEditor: View {
    @Binding var excludes: [String]
    @State private var local: [String] = []
    @State private var newExclude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Pastas e arquivos excluídos").font(.headline)
                Spacer()
                Text("\(local.count) itens")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            Divider()
            HStack {
                TextField("Adicionar exclusão (ex: node_modules)", text: $newExclude)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                    .onSubmit(add)
                Button("Adicionar", action: add)
                    .disabled(newExclude.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            Divider()
            if local.isEmpty {
                Spacer()
                Text("Nenhuma exclusão")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(local.indices, id: \.self) { i in
                            row(at: i)
                            Divider()
                        }
                    }
                }
            }
        }
        .onAppear {
            local = excludes
        }
        .onChange(of: local) { newValue in
            excludes = newValue
        }
    }

    @ViewBuilder
    private func row(at i: Int) -> some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(local[i]).font(.body.monospaced())
            Spacer()
            Button {
                guard i < local.count else { return }
                local.remove(at: i)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func add() {
        let t = newExclude.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !local.contains(t) else { return }
        local.append(t)
        newExclude = ""
    }
}
