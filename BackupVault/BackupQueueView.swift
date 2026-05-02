import SwiftUI

struct BackupQueueSheet: View {
    @EnvironmentObject var api: APIService
    @EnvironmentObject var store: ConfigStore
    @Environment(\.dismiss) private var dismiss

    @State private var selection: Set<UUID> = []
    @State private var queue: BackupQueue?
    @State private var phase: Phase = .selecting

    enum Phase { case selecting, running, finished }

    var availableProfiles: [BackupProfile] {
        store.profiles.filter { $0.enabled && !$0.label.isEmpty && !$0.sourcePath.isEmpty }
    }

    var selectedProfiles: [BackupProfile] {
        availableProfiles.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {

            // Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "list.bullet.rectangle.portrait.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("queue.title").font(.headline)
                    Text(headerSubtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                statusBadge
            }
            .padding(18)
            Divider()

            // Body — selection or running
            if phase == .selecting {
                selectionView
            } else if let queue {
                runningView(queue: queue)
            }

            Divider()

            // Actions
            HStack {
                Button("common.close") { dismiss() }
                Spacer()

                if phase == .selecting {
                    Button("queue.select_all") {
                        selection = Set(availableProfiles.map { $0.id })
                    }
                    .buttonStyle(.bordered)
                    .disabled(availableProfiles.isEmpty)

                    Button(String(format: NSLocalizedString("queue.start", comment: ""), selection.count)) {
                        startQueue()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
                }

                if phase == .running, let queue {
                    Button("queue.stop") {
                        queue.cancel()
                    }
                    .buttonStyle(.bordered).tint(.orange)
                }

                if phase == .finished {
                    Button("queue.run_again") {
                        startQueue()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 540)
        .onAppear {
            // Pre-select all available
            if selection.isEmpty {
                selection = Set(availableProfiles.map { $0.id })
            }
        }
    }

    // MARK: - Selection View
    var selectionView: some View {
        Group {
            if availableProfiles.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text("queue.none_available")
                        .font(.headline)
                    Text("queue.none_hint")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(availableProfiles) { profile in
                            profileRow(profile)
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: BackupProfile) -> some View {
        let isSelected = selection.contains(profile.id)
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.subheadline.weight(.medium))
                Text("\(profile.label) · \(profile.sourcePath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selection.remove(profile.id) }
            else { selection.insert(profile.id) }
        }
    }

    // MARK: - Running / Finished View
    @ViewBuilder
    private func runningView(queue: BackupQueue) -> some View {
        VStack(spacing: 0) {
            if queue.status == .running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: queue.progress)
                        .progressViewStyle(.linear)
                    HStack {
                        if let runner = queue.currentRunner, !runner.currentFile.isEmpty {
                            Text(runner.currentFile)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Text("\(Int(queue.progress * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 10)
                Divider()
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(queue.items) { item in
                        QueueItemRow(item: item, runner: queue.currentRunner,
                                     isCurrent: queue.items.firstIndex(where: { $0.id == item.id }) == queue.currentIndex)
                        Divider()
                    }
                }
            }

            if queue.status == .done || queue.status == .cancelled {
                Divider()
                HStack(spacing: 0) {
                    ResultStat(value: "\(queue.doneCount)",   label: "queue.stat.done")
                    Divider()
                    ResultStat(value: "\(queue.failedCount)", label: "queue.stat.failed")
                    Divider()
                    ResultStat(value: "\(queue.items.count - queue.doneCount - queue.failedCount)", label: "queue.stat.other")
                }
                .frame(height: 54)
            }
        }
        .onChange(of: queue.status) { newStatus in
            if newStatus == .done || newStatus == .cancelled {
                phase = .finished
            }
        }
    }

    // MARK: - Computed
    var headerSubtitle: String {
        switch phase {
        case .selecting:
            return L("queue.subtitle.selecting", selection.count, availableProfiles.count)
        case .running:
            return L("queue.subtitle.running", queue?.items.count ?? 0)
        case .finished:
            return L("queue.subtitle.done")
        }
    }

    var statusBadge: some View {
        Group {
            switch phase {
            case .selecting:
                Text("queue.waiting").foregroundStyle(.secondary)
            case .running:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("queue.running").foregroundStyle(.blue)
                }
            case .finished:
                if queue?.status == .cancelled {
                    Label("queue.cancelled", systemImage: "stop.circle.fill").foregroundStyle(.orange)
                } else {
                    Label("queue.done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
        }
        .font(.subheadline.weight(.medium))
    }

    // MARK: - Actions
    private func startQueue() {
        let profiles = selectedProfiles
        guard !profiles.isEmpty else { return }
        let q = BackupQueue(api: api, profiles: profiles)
        queue = q
        phase = .running
        Task { await q.run() }
    }
}

// MARK: - Queue Item Row

struct QueueItemRow: View {
    let item:      BackupQueue.QueueItem
    let runner:    BackupRunner?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 18))
                .foregroundStyle(iconColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.profile.name).font(.subheadline.weight(.medium))
                Text(item.profile.label)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent, let runner {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: runner.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    if !runner.currentFile.isEmpty {
                        Text(runner.currentFile)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(width: 120, alignment: .trailing)
                    }
                }
            } else {
                Text(LocalizedStringKey(statusLabel))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(iconColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.06) : Color.clear)
    }

    var iconColor: Color {
        switch item.status {
        case .waiting:   return .secondary
        case .running:   return .blue
        case .done:      return .green
        case .failed:    return .red
        case .cancelled: return .orange
        case .skipped:   return .secondary
        }
    }

    var statusLabel: String {
        switch item.status {
        case .waiting:   return "queue.waiting"
        case .running:   return "queue.running"
        case .done:      return "queue.done"
        case .failed:    return "queue.failed"
        case .cancelled: return "queue.cancelled"
        case .skipped:   return "queue.skipped"
        }
    }
}

