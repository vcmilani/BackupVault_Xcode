import Foundation

final class ConfigStore: ObservableObject {
    @Published var profiles: [BackupProfile] = []

    private let key = "backupProfiles_v1"

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([BackupProfile].self, from: data)
        else { return }
        profiles = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func add(_ profile: BackupProfile) {
        profiles.append(profile)
        persist()
    }

    func update(_ profile: BackupProfile) {
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[idx] = profile
        persist()
    }

    func delete(_ profile: BackupProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        profiles.move(fromOffsets: source, toOffset: destination)
        persist()
    }
}
