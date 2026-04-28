import SwiftUI

struct BackupsView: View {
    @EnvironmentObject var api: APIService

    @State private var selectedBackup:  BackupSummary?
    @State private var versions:        [BackupVersion] = []
    @State private var selectedVersion: BackupVersion?
    @State private var files:           [VersionFile]   = []
    @State private var loadingVersions  = false
    @State private var loadingFiles     = false
    @State private var backupSearch     = ""
    @State private var showDeleteVersion = false
    @State private var pendingDelete:   BackupVersion?

    var filteredBackups: [BackupSummary] {
        guard !backupSearch.isEmpty else { return api.backups }
        return api.backups.filter { $0.label.localizedCaseInsensitiveContains(backupSearch) }
    }

    var body: some View {
        HStack(spacing: 0) {
            backupsPane
                .frame(width: 210)
            Divider()
            versionsPane
                .frame(width: 250)
            Divider()
            filesPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Excluir versão?", isPresented: $showDeleteVersion, presenting: pendingDelete) { ver in
            Button("Cancelar", role: .cancel) {}
            Button("Excluir", role: .destructive) {
                Task {
                    try? await api.deleteVersion(label: selectedBackup!.label, versionKey: ver.versionKey)
                    if let backup = selectedBackup { await loadVersions(for: backup) }
                }
            }
        } message: { ver in
            Text("A versão \(ver.versionKey) será permanentemente removida.")
        }
    }

    // MARK: - Backups Pane

    var backupsPane: some View {
        VStack(spacing: 0) {
            HStack {
                Text("backups.title").font(.headline)
                Spacer()
                if api.isLoadingBackups { ProgressView().controlSize(.small) }
                Button { Task { await api.fetchBackups() } } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("Filtrar", text: $backupSearch)
                    .textFieldStyle(.plain).font(.caption)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            if api.backups.isEmpty && !api.isLoadingBackups {
                PlaceholderView(title: "Nenhum backup", icon: "externaldrive")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredBackups) { backup in
                            HStack(spacing: 0) {
                                BackupListRow(backup: backup)
                                    .padding(.horizontal, 12)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(selectedBackup == backup
                                ? Color.accentColor.opacity(0.18) : Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedBackup = backup
                                selectedVersion = nil
                                files = []
                                Task { await loadVersions(for: backup) }
                            }
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Versions Pane

    var versionsPane: some View {
        VStack(spacing: 0) {
            if let backup = selectedBackup {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(backup.label).font(.headline).lineLimit(1)
                        Text("\(versions.count) versões · \(backup.formattedSize)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if loadingVersions { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider()
                if versions.isEmpty && !loadingVersions {
                    PlaceholderView(title: "backups.no_versions", icon: "clock.arrow.circlepath")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(versions) { version in
                                HStack(spacing: 0) {
                                    VersionListRow(version: version)
                                        .padding(.horizontal, 12)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selectedVersion == version
                                    ? Color.accentColor.opacity(0.18) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedVersion = version
                                    files = []
                                    Task { await loadFiles(backup: backup, version: version) }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        pendingDelete = version
                                        showDeleteVersion = true
                                    } label: {
                                        Label("backups.delete_version", systemImage: "trash")
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            } else {
                PlaceholderView(title: L("backups.select"), icon: "externaldrive")
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Files Pane

    var filesPane: some View {
        Group {
            if let version = selectedVersion {
                FilesDetailView(version: version, files: files, isLoading: loadingFiles)
            } else if selectedBackup != nil {
                PlaceholderView(title: L("backups.select_version"), icon: "clock.arrow.circlepath")
            } else {
                PlaceholderView(title: L("backups.select"), icon: "externaldrive")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func loadVersions(for backup: BackupSummary) async {
        loadingVersions = true
        do   { versions = try await api.fetchVersions(label: backup.label) }
        catch { versions = [] }
        loadingVersions = false
    }

    func loadFiles(backup: BackupSummary, version: BackupVersion) async {
        loadingFiles = true
        do   { files = try await api.fetchFiles(label: backup.label, versionKey: version.versionKey) }
        catch { files = [] }
        loadingFiles = false
    }
}

struct BackupListRow: View {
    let backup: BackupSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.fill").font(.caption).foregroundStyle(.blue)
                Text(backup.label).font(.subheadline.weight(.medium)).lineLimit(1)
            }
            HStack(spacing: 4) {
                Text("\(backup.versionCount) versões"); Text("·"); Text(backup.formattedSize)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct VersionListRow: View {
    let version: BackupVersion
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: version.isDone ? "checkmark.circle.fill" : "clock.fill")
                    .font(.caption).foregroundStyle(version.isDone ? .green : .orange)
                if let date = version.date {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption.weight(.medium)).lineLimit(1)
                } else {
                    Text(version.versionKey).font(.caption.monospaced()).lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                Text("\(version.fileCount) arquivos")
                if version.deletedCount > 0 {
                    Text("· \(version.deletedCount) del.").foregroundStyle(.red.opacity(0.7))
                }
                Text("· \(version.formattedSize)")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

struct FilesDetailView: View {
    let version:   BackupVersion
    let files:     [VersionFile]
    let isLoading: Bool

    @State private var fileSearch  = ""
    @State private var showDeleted = true
    @State private var sortOrder   = [KeyPathComparator(\VersionFile.originalPath)]

    var filtered: [VersionFile] {
        var r = files
        if !showDeleted { r = r.filter { !$0.isDeleted } }
        if !fileSearch.isEmpty { r = r.filter { $0.originalPath.localizedCaseInsensitiveContains(fileSearch) } }
        return r
    }

    var activeCount:  Int { files.filter { !$0.isDeleted }.count }
    var deletedCount: Int { files.filter {  $0.isDeleted }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    if let date = version.date {
                        Text(date, format: .dateTime.year().month().day().hour().minute().second())
                            .font(.headline)
                    } else {
                        Text(version.versionKey).font(.headline.monospaced())
                    }
                    HStack(spacing: 8) {
                        Label("\(activeCount) ativos",     systemImage: "doc.fill").foregroundStyle(.green)
                        Label("\(deletedCount) deletados", systemImage: "doc")      .foregroundStyle(.secondary)
                        Text("·"); Text(version.formattedSize)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("backups.show_deleted", isOn: $showDeleted).toggleStyle(.checkbox).font(.caption)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if isLoading {
                Spacer(); ProgressView("backups.loading").padding(); Spacer()
            } else if filtered.isEmpty {
                PlaceholderView(title: "backups.no_files", icon: "doc.on.doc")
            } else {
                Table(filtered, sortOrder: $sortOrder) {
                    TableColumn("backups.col.file", value: \.originalPath) { file in
                        HStack(spacing: 6) {
                            Image(systemName: file.isDeleted ? "doc.fill" : "doc")
                                .font(.caption)
                                .foregroundStyle(file.isDeleted ? Color.secondary : Color.blue)
                            Text(file.originalPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(file.isDeleted ? Color.secondary : Color.primary)
                                .strikethrough(file.isDeleted).lineLimit(1)
                        }
                    }
                    TableColumn("backups.col.size", value: \.size) { file in
                        Text(file.formattedSize).font(.caption).foregroundStyle(.secondary)
                    }.width(80)
                    TableColumn("backups.col.status") { file in
                        Text(file.status).font(.caption.weight(.medium))
                            .foregroundStyle(file.isDeleted ? .red : .green)
                    }.width(70)
                    TableColumn("backups.col.sha") { file in
                        Text(String(file.sha256.prefix(12)) + "…")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }.width(100)
                }
                .searchable(text: $fileSearch, prompt: "backups.filter_files")
            }
        }
    }
}
