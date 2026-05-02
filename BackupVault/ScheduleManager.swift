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
    @Published var activeRunner: BackupRunner?

    // Manual single-run tracking
    @Published var activeManualRunner: BackupRunner?
    @Published var activeManualProfileId: UUID?

    // Queue tracking
    @Published var activeQueue: BackupQueue?

    // Queue schedule — persisted as JSON in UserDefaults
    @Published var queueSchedule: BackupSchedule {
        didSet {
            guard let data = try? JSONEncoder().encode(queueSchedule) else { return }
            UserDefaults.standard.set(data, forKey: "queue.schedule.config")
        }
    }

    // Last time the scheduled queue fired
    @Published var queueScheduleLastRun: Date? {
        didSet { UserDefaults.standard.set(queueScheduleLastRun, forKey: "queue.schedule.lastRun") }
    }

    /// Next scheduled queue run date (nil if schedule is off)
    var nextQueueRun: Date? {
        guard queueSchedule.enabled else { return nil }
        return queueSchedule.nextRun(after: Date(), lastRun: queueScheduleLastRun)
    }

    private var timer: Timer?

    init() {
        if let data = UserDefaults.standard.data(forKey: "queue.schedule.config"),
           let saved = try? JSONDecoder().decode(BackupSchedule.self, from: data) {
            _queueSchedule = Published(wrappedValue: saved)
        } else {
            _queueSchedule = Published(wrappedValue: BackupSchedule())
        }
        _queueScheduleLastRun = Published(wrappedValue:
            UserDefaults.standard.object(forKey: "queue.schedule.lastRun") as? Date
        )
    }

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
        guard activeManualRunner == nil, activeQueue == nil else { return }
        guard let store, let api, let power else { return }

        // Skip if API not connected
        guard api.isConnected else {
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

        // Queue schedule fires before individual profiles
        if queueSchedule.isDue(now: Date(), lastRun: queueScheduleLastRun) {
            let profiles = store.profiles.filter {
                $0.enabled && !$0.label.isEmpty && !$0.sourcePath.isEmpty
            }
            if !profiles.isEmpty {
                Task { await runScheduledQueue(profiles: profiles) }
                return
            }
        }

        // Find a due individual profile
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

    // MARK: - Scheduled Queue Run

    private func runScheduledQueue(profiles: [BackupProfile]) async {
        guard let api else { return }
        let q = BackupQueue(api: api, profiles: profiles)
        registerQueue(q)
        queueScheduleLastRun = Date()
        await q.run()
        clearQueue(q)
    }

    // MARK: - Individual Profile Run

    private func runScheduled(profile: BackupProfile) async {
        guard let api, let store else { return }

        isRunningScheduled = true
        currentProfileId = profile.id

        let runner = BackupRunner(api: api)
        self.activeRunner = runner
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

    // MARK: - Manual Run Registration

    func registerManualRunner(_ runner: BackupRunner, profileId: UUID) {
        activeManualRunner  = runner
        activeManualProfileId = profileId
    }

    func clearManualRunner(_ runner: BackupRunner) {
        guard activeManualRunner === runner else { return }
        activeManualRunner  = nil
        activeManualProfileId = nil
    }

    // MARK: - Queue Registration

    func registerQueue(_ queue: BackupQueue) {
        activeQueue = queue
    }

    func clearQueue(_ queue: BackupQueue) {
        guard activeQueue === queue else { return }
        activeQueue = nil
    }

    // MARK: - Helpers

    /// Returns the next scheduled individual-profile run, for the menu bar UI.
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
