import SwiftUI

struct VersionDetailView: View {
    @EnvironmentObject var api: APIService
    let label: String
    let version: VersionInfo

    @State private var files: [FileInfo]     = []
    @State private var isLoading             = false
    @State private var loadError: String?    = nil
    @State private var showDeleteConfirm     = false
    @State private var deleteResult: String? = nil
    @State private var isDeleting            = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Header ─────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(version.versionKey)
                            .font(.title2.weight(.semibold).monospaced())
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusBadge(status: version.status)
                }

                HStack(spacing: 20) {
                    LabeledContent(L("version.detail.files")) {
                        Text("\(version.fileCount)")
                            .font(.subheadline.weight(.medium))
                    }
                    LabeledContent(L("version.detail.size")) {
                        Text(formatBytes(version.totalSizeBytes))
                            .font(.subheadline.weight(.medium))
                    }
                    if let fin = version.finishedAt {
                        LabeledContent(L("version.detail.finished")) {
                            Text(fin)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
            .padding(20)
            .background(.background.secondary)

            Divider()

            // ── File List ───────────────────────────────────────────
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .padding(40)
            } else if let err = loadError {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    Text(err).font(.subheadline).foregroundStyle(.red)
                }
                .padding(20)
            } else {
                List(files) { file in
                    HStack(spacing: 10) {
                        Image(systemName: iconForPath(file.originalPath))
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: file.originalPath).lastPathComponent)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Text(file.originalPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text(formatBytes(file.size))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }

            Divider()

            // ── Footer actions ──────────────────────────────────────
            HStack {
                Button("common.close") { dismiss() }
                if let result = deleteResult {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(result).font(.subheadline).foregroundStyle(.green)
                    }
                }
                Spacer()
                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    HStack(spacing: 4) {
                        if isDeleting { ProgressView().controlSize(.small) }
                        Label(L("version.detail.delete_btn"), systemImage: "trash")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)
                .disabled(isDeleting || deleteResult != nil)
            }
            .padding(16)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { Task { await loadFiles() } }
        .alert(L("version.detail.confirm_title"), isPresented: $showDeleteConfirm) {
            Button(L("common.cancel"), role: .cancel) {}
            Button(L("version.detail.confirm_btn"), role: .destructive) {
                Task { await deleteVersion() }
            }
        } message: {
            Text(L("version.detail.confirm_msg", version.versionKey))
        }
    }

    private func loadFiles() async {
        isLoading = true
        loadError = nil
        do {
            files = try await api.fetchFiles(label: label, versionKey: version.versionKey)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteVersion() async {
        isDeleting = true
        do {
            let resp = try await api.deleteVersion(label: label, versionKey: version.versionKey)
            deleteResult = L("version.detail.deleted",
                             resp.versionsRemoved.isEmpty ? version.versionKey : resp.versionKey,
                             resp.filesRemovedFromStorage)
            await api.fetchBackups()
            // Close after brief delay so user can read the result
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        } catch {
            loadError = error.localizedDescription
        }
        isDeleting = false
    }

    private func iconForPath(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf":                     return "doc.richtext"
        case "jpg","jpeg","png","gif","heic","webp": return "photo"
        case "mp4","mov","avi","mkv":   return "play.rectangle"
        case "mp3","wav","flac","aac":  return "music.note"
        case "zip","gz","tar","bz2","7z": return "archivebox"
        case "swift","py","js","ts","rb","go","rs","c","cpp","h": return "chevron.left.forwardslash.chevron.right"
        case "md","txt","rtf":          return "doc.text"
        default:                        return "doc"
        }
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(status)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    var color: Color {
        switch status {
        case "done":    return .green
        case "running": return .blue
        case "failed":  return .red
        default:        return .secondary
        }
    }
}
