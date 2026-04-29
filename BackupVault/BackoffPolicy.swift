import Foundation

/// Exponential backoff with reset on success.
/// Sequence: 30s → 1m → 5m → 15m → 30m → 1h (capped)
@MainActor
final class BackoffPolicy: ObservableObject {

    @Published var nextAttemptDate: Date?
    @Published var failureCount: Int = 0

    private let intervals: [TimeInterval] = [30, 60, 5*60, 15*60, 30*60, 60*60]

    func recordSuccess() {
        failureCount = 0
        nextAttemptDate = nil
    }

    func recordFailure() {
        failureCount += 1
        let idx = min(failureCount - 1, intervals.count - 1)
        nextAttemptDate = Date().addingTimeInterval(intervals[idx])
    }

    /// Returns true if enough time has passed since the last failure.
    var shouldAttempt: Bool {
        guard let next = nextAttemptDate else { return true }
        return Date() >= next
    }

    /// Time interval until the next allowed attempt (0 if ready).
    var timeUntilNext: TimeInterval {
        guard let next = nextAttemptDate else { return 0 }
        return max(0, next.timeIntervalSinceNow)
    }

    var humanReadable: String {
        guard failureCount > 0 else { return "" }
        let secs = Int(timeUntilNext)
        if secs <= 0 { return "Pronto para tentar" }
        if secs < 60   { return "Próxima tentativa em \(secs)s" }
        let mins = secs / 60
        if mins < 60 { return "Próxima tentativa em \(mins) min" }
        let hours = mins / 60
        return "Próxima tentativa em \(hours)h"
    }
}
