import Foundation
import SwiftUI

/// Watches all profiles and runs their backups when their schedule is due.
/// Respects: power source, network reachability, and active backups (no overlap).
@MainActor
final class ScheduleManager: ObservableObject {

    @Published var isRunningScheduled: Bool = false
    @Published var currentProfileId: UUID?
    @Published var lastTickDate: Date = .distantPast

    /// User preference: pause schedule when on battery
    @AppStorage("schedule.pauseOnBattery") var pauseOnBattery: Bool = true

    /// Minimum battery percent required to run on battery (when not paused)
    @AppStorage("schedule.minBatteryPercent") var minBatteryPercent: Int = 50

    private weak var api: APIService?
    private weak var store: ConfigStore?
    private weak var power: PowerMonitor?
    private var timer: Timer?
    private var activeRunner: BackupRunner?

    init() {}

    func bind(api: APIService, store: ConfigStore, power: PowerMonitor) {
        self.api   = api
        self.store = store
        self.power = power
    }

    func start() {
        timer?.invalidate()
        // Check every 30 seconds — light enough to be background-friendly
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // Fire immediately on start
        Task { @MainActor in tick() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Tick

    func tick() {
        lastTickDate = Date()
        guard !isRunningScheduled else { return }
        guard let store, let api, let power else { return }

        // Skip if API not connected (backoff window respected by API)
        guard api.isConnected else {
            // Schedule still tries to wake the connection up periodically
            Task { await api.checkHealth() }
            return
        }

        // Skip if on battery and user disabled it (or below threshold)
        if power.powerSource == .battery {
            if pauseOnBattery { return }
            if power.batteryPercent < minBatteryPercent { return }
        }

        // Skip if not on local network
        guard power.isOnLocalNetwork else { return }

        // Find a due profile
        let due = store.profiles.first { profile in
            profile.enabled
            && !profile.label.isEmpty
            && !profile.sourcePath.isEmpty
            && profile.schedule.enabled
            && profile.schedule.isDue(now: Date(), lastRun: profile.lastRun)
        }

        guard let profile = due else { return }

        Task { await runScheduled(profile: profile) }
    }

    // MARK: - Run

    private func runScheduled(profile: BackupProfile) async {
        guard let api, let store else { return }

        isRunningScheduled = true
        currentProfileId = profile.id

        let runner = BackupRunner(api: api)
        activeRunner = runner
        await runner.run(profile: profile)

        // Persist last run
        var updated = profile
        updated.lastRun = Date()
        switch runner.status {
        case .done:      updated.lastRunStatus = "done"
        case .failed:    updated.lastRunStatus = "failed"
        case .cancelled: updated.lastRunStatus = "cancelled"
        default:         updated.lastRunStatus = "unknown"
        }
        store.update(updated)

        activeRunner = nil
        currentProfileId = nil
        isRunningScheduled = false
    }

    // MARK: - Helpers

    /// Returns the next scheduled run across all enabled profiles, for the menu bar UI.
    func nextScheduledRun() -> (profile: BackupProfile, date: Date)? {
        guard let store else { return nil }
        let candidates: [(BackupProfile, Date)] = store.profiles.compactMap { p in
            guard p.enabled, p.schedule.enabled,
                  let next = p.schedule.nextRun(after: Date(), lastRun: p.lastRun)
            else { return nil }
            return (p, next)
        }
        return candidates.min(by: { $0.1 < $1.1 })
    }
}
